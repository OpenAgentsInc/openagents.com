defmodule OpenAgents.Forge.BackfillTest do
  @moduledoc """
  Importing pre-seed history into the log.

  A repository seeded from a shallow fetch serves every ref tip and clones
  without error while holding none of the history behind its seed. These tests
  build exactly that repository, prove it is grafted, import the missing
  history, and then destroy the cache and rebuild from seq 0 — because an
  import that only repairs the projection has repaired a cache, not the
  authority.
  """

  use OpenAgents.DataCase, async: false

  alias OpenAgents.Forge.{Backfill, Repos, Sync, WAL}

  setup do
    base = Path.join(System.tmp_dir!(), "forge-backfill-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_wal = Application.get_env(:openagents, :forge_wal_dir)
    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))

    on_exit(fn ->
      Application.put_env(:openagents, :forge_data_dir, previous_data)
      Application.put_env(:openagents, :forge_wal_dir, previous_wal)
      File.rm_rf(base)
    end)

    storage_key = "backfill-demo-#{System.unique_integer([:positive])}"
    source = build_source!(base)
    seed_shallow_import!(base, storage_key, source)

    %{base: base, storage_key: storage_key, source: source}
  end

  test "a shallow-seeded repository is grafted and holds none of its own history",
       %{storage_key: storage_key, source: source} do
    :ok = Sync.ensure_fresh!(storage_key)
    path = Repos.bare_path(storage_key)

    assert [boundary] = Backfill.open_boundaries(storage_key)
    assert boundary == rev(source, "HEAD")

    assert count_commits(path) == 1
    assert File.exists?(Path.join(path, "shallow"))
  end

  test "importing the pre-seed bundle closes the boundary and survives a rebuild from seq 0",
       %{base: base, storage_key: storage_key, source: source} do
    :ok = Sync.ensure_fresh!(storage_key)
    path = Repos.bare_path(storage_key)
    total = count_worktree_commits(source)
    assert total > 1

    bundle = pre_seed_bundle!(base, source)

    assert {:ok, %{seq: 1, closed: [_boundary]}} =
             Backfill.import_history(storage_key, bundle, "operator:test")

    assert Backfill.open_boundaries(storage_key) == []
    refute File.exists?(Path.join(path, "shallow"))
    assert count_commits(path) == total

    # The point of the import: the authority now holds the history, so a node
    # that loses its cache rebuilds the whole repository rather than the seed.
    :ok = Sync.rebuild(storage_key)
    rebuilt = Repos.bare_path(storage_key)

    assert Backfill.open_boundaries(storage_key) == []
    assert count_commits(rebuilt) == total
    assert {_output, 0} = Repos.git(rebuilt, ["rev-list", "--objects", "--quiet", "--all"])
  end

  test "the import leaves the ref map exactly as it found it",
       %{base: base, storage_key: storage_key, source: source} do
    :ok = Sync.ensure_fresh!(storage_key)
    {:ok, _generation, before_index} = WAL.read_index(storage_key)
    before_refs = WAL.refs(before_index)

    bundle = pre_seed_bundle!(base, source)

    assert {:ok, _summary} = Backfill.import_history(storage_key, bundle, "operator:test")

    {:ok, _generation, after_index} = WAL.read_index(storage_key)
    assert WAL.refs(after_index) == before_refs
    assert Repos.refs_at(Repos.bare_path(storage_key)) == before_refs
  end

  test "a bundle that closes nothing is refused with the log untouched",
       %{base: base, storage_key: storage_key} do
    :ok = Sync.ensure_fresh!(storage_key)
    {:ok, _generation, before_index} = WAL.read_index(storage_key)

    # A bundle of an unrelated repository: real, readable, and no help.
    unrelated = build_source!(base, "unrelated")
    bundle = Path.join(base, "unrelated.bundle")
    sh!(unrelated, "git", ["bundle", "create", bundle, "--all"])

    assert {:error, {:still_grafted, [_boundary]}} =
             Backfill.import_history(storage_key, bundle, "operator:test")

    {:ok, _generation, after_index} = WAL.read_index(storage_key)
    assert WAL.entries(after_index) == WAL.entries(before_index)
  end

  test "an unreadable bundle is refused with the log untouched",
       %{storage_key: storage_key} do
    :ok = Sync.ensure_fresh!(storage_key)
    {:ok, _generation, before_index} = WAL.read_index(storage_key)

    assert {:error, :bundle_unreadable} =
             Backfill.import_history(storage_key, "/nonexistent/backfill.bundle", "operator:test")

    {:ok, _generation, after_index} = WAL.read_index(storage_key)
    assert WAL.entries(after_index) == WAL.entries(before_index)
  end

  test "an import needs a principal", %{base: base, storage_key: storage_key, source: source} do
    :ok = Sync.ensure_fresh!(storage_key)
    bundle = pre_seed_bundle!(base, source)

    assert {:error, :invalid_principal} = Backfill.import_history(storage_key, bundle, "   ")
  end

  defp build_source!(base, name \\ "source") do
    source = Path.join(base, name)
    File.mkdir_p!(source)
    sh!(source, "git", ["init", "--initial-branch=main", "."])
    sh!(source, "git", ["config", "user.email", "test@example.com"])
    sh!(source, "git", ["config", "user.name", "Forge Test"])

    Enum.each(1..4, fn n ->
      File.write!(Path.join(source, "history-#{n}.txt"), "history #{n}\n")
      sh!(source, "git", ["add", "."])
      sh!(source, "git", ["commit", "-m", "history #{n}"])
    end)

    source
  end

  # Everything behind the seed: the seed's parent and all of its ancestors.
  defp pre_seed_bundle!(base, source) do
    bundle = Path.join(base, "pre-seed-#{System.unique_integer([:positive])}.bundle")
    sh!(source, "git", ["branch", "--force", "pre-seed", "HEAD~1"])
    sh!(source, "git", ["bundle", "create", bundle, "pre-seed"])
    sh!(source, "git", ["branch", "--delete", "--force", "pre-seed"])
    bundle
  end

  # Mirrors `OpenAgents.Repositories.Importer`: a `--depth=1` fetch bundled
  # with `--all`, recorded as the seq 0 `git_bundle` entry with the shallow
  # boundaries the fetch produced.
  defp seed_shallow_import!(base, storage_key, source) do
    snapshot = Path.join(base, "snapshot-#{storage_key}.git")
    sh!(base, "git", ["init", "--bare", "--initial-branch=main", snapshot])

    sh!(base, "git", [
      "--git-dir",
      snapshot,
      "fetch",
      "--depth=1",
      source,
      "refs/heads/main:refs/heads/main"
    ])

    bundle = Path.join(base, "snapshot-#{storage_key}.bundle")
    sh!(base, "git", ["--git-dir", snapshot, "bundle", "create", bundle, "--all"])

    shallow =
      snapshot
      |> Path.join("shallow")
      |> File.read!()
      |> String.split("\n", trim: true)

    assert shallow != []

    head =
      base
      |> sh!("git", ["--git-dir", snapshot, "rev-parse", "refs/heads/main"])
      |> String.trim()

    {:ok, object} = WAL.put_entry_file(storage_key, 0, bundle)

    entry = %{
      "seq" => 0,
      "object" => object,
      "format" => "git_bundle",
      "refs" => %{"refs/heads/main" => head},
      "shallow" => shallow,
      "principal" => "github-import:test",
      "pushed_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    {:ok, _generation} =
      WAL.cas_index(storage_key, :none, WAL.append_entry(WAL.new_index(), entry))

    :ok
  end

  defp count_worktree_commits(source) do
    source |> sh!("git", ["rev-list", "--count", "--all"]) |> String.trim() |> String.to_integer()
  end

  defp count_commits(path) do
    {output, 0} = Repos.git(path, ["rev-list", "--count", "--all"])
    output |> String.trim() |> String.to_integer()
  end

  defp rev(source, ref) do
    source |> sh!("git", ["rev-parse", ref]) |> String.trim()
  end

  defp sh!(dir, command, args) do
    {output, 0} = System.cmd(command, args, cd: dir, stderr_to_stdout: true)
    output
  end
end
