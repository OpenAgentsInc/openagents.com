defmodule OpenAgents.Forge.WALReplayTest do
  @moduledoc """
  Durability of the push WAL: every accepted entry must re-materialize on a
  node that has lost its cache. These tests drive the real git client over
  real HTTP so the recorded entries are genuine `receive-pack` requests, then
  destroy the cache and replay.
  """

  use OpenAgents.DataCase, async: false

  import OpenAgents.AccountsFixtures

  alias OpenAgents.Forge.{CacheReadiness, GitPlane, Pushes, Repos, Sync, SyncError, WAL}
  alias OpenAgents.Repo

  defmodule TestPipeline do
    @moduledoc false
    use Plug.Builder

    plug OpenAgentsWeb.Plugs.ForgeGitAuth
    plug OpenAgents.Forge.GitHTTP
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(OpenAgents.Repo, {:shared, self()})

    base = Path.join(System.tmp_dir!(), "forge-replay-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_wal = Application.get_env(:openagents, :forge_wal_dir)
    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))
    CacheReadiness.reset()

    user = repository_user_fixture("replay-owner")

    {:ok, repository, :created} =
      OpenAgents.Repositories.create_user_repository(user, %{name: "demo"}, "replay-demo")

    repository =
      repository
      |> Ecto.Changeset.change(lifecycle_state: "ready", ready_at: DateTime.utc_now())
      |> OpenAgents.Repo.update!()

    {:ok, _api_token, plaintext} =
      OpenAgents.ApiTokens.create(user, %{
        name: "WAL replay test",
        scopes: ["forge:write"],
        lifetime_days: 1
      })

    port = free_port()
    start_supervised!({Bandit, plug: TestPipeline, port: port, ip: {127, 0, 0, 1}})

    on_exit(fn ->
      Application.put_env(:openagents, :forge_data_dir, previous_data)
      Application.put_env(:openagents, :forge_wal_dir, previous_wal)
      CacheReadiness.reset()
      File.rm_rf(base)
    end)

    %{
      base: base,
      repository: repository,
      url: "http://x:#{plaintext}@127.0.0.1:#{port}/replay-owner/demo.git"
    }
  end

  test "a shallow import followed by pushes replays onto an empty cache", %{
    base: base,
    repository: repository,
    url: url
  } do
    seed_shallow_import!(base, repository.storage_key)

    work = seed_clone!(base, url)
    commit_and_push!(work, "one.txt", "one\n", "one")
    commit_and_push!(work, "two.txt", "two\n", "two")

    shallow = shallow_clone!(base, url)
    sh!(shallow, "git", ["checkout", "-b", "feature"])
    commit_and_push!(shallow, "feature.txt", "feature\n", "feature", "feature")

    {:ok, _generation, index} = WAL.read_index(repository.storage_key)
    expected = WAL.refs(index)

    File.rm_rf!(Repos.bare_path(repository.storage_key))

    assert :ok = Sync.ensure_fresh(repository.storage_key, "main")
    assert Repos.refs(repository.storage_key) == expected
    assert missing_objects(repository.storage_key, index) == []
  end

  test "replay is idempotent and a re-push of the same objects does not diverge", %{
    base: base,
    repository: repository,
    url: url
  } do
    seed_shallow_import!(base, repository.storage_key)

    work = seed_clone!(base, url)
    commit_and_push!(work, "one.txt", "one\n", "one")

    {:ok, _generation, index} = WAL.read_index(repository.storage_key)
    expected = WAL.refs(index)
    applied = Repos.applied_seq(repository.storage_key)

    # Replaying an already-current cache changes nothing.
    assert :ok = Sync.ensure_fresh(repository.storage_key, "main")
    assert Repos.refs(repository.storage_key) == expected
    assert Repos.applied_seq(repository.storage_key) == applied

    # A full rebuild from seq 0, twice, reaches the same state.
    Enum.each(1..2, fn _pass ->
      File.rm_rf!(Repos.bare_path(repository.storage_key))
      assert :ok = Sync.ensure_fresh(repository.storage_key, "main")
      assert Repos.refs(repository.storage_key) == expected
      assert Repos.applied_seq(repository.storage_key) == applied
      assert missing_objects(repository.storage_key, index) == []
    end)

    # Receipts derive from the WAL exactly once, however often replay runs.
    _backfilled = Pushes.reconcile_receipts(repository.storage_key)
    receipts = Repo.aggregate(OpenAgents.Forge.PushReceipt, :count)
    assert Pushes.reconcile_receipts(repository.storage_key) == 0
    assert Repo.aggregate(OpenAgents.Forge.PushReceipt, :count) == receipts

    # Pushing the same objects again is a no-op that appends no entry.
    sh!(work, "git", ["push", "origin", "HEAD:main"])
    {:ok, _generation, after_index} = WAL.read_index(repository.storage_key)
    assert WAL.refs(after_index) == expected
    assert length(WAL.entries(after_index)) == length(WAL.entries(index))
  end

  test "a bundle entry that records no shallow boundary leaves the graft alone", %{
    base: base,
    repository: repository,
    url: url
  } do
    seed_shallow_import!(base, repository.storage_key)

    work = seed_clone!(base, url)
    commit_and_push!(work, "one.txt", "one\n", "one")

    storage_key = repository.storage_key
    shallow_before = shallow_boundaries(storage_key)
    assert shallow_before != []

    # A stack operation records a `git_bundle` entry with no shallow key: it
    # introduces objects but says nothing about the graft.
    {:ok, head} = GitPlane.resolve_commit(storage_key, "refs/heads/main")
    {:ok, tree} = GitPlane.tree_of(storage_key, head)
    {:ok, commit} = GitPlane.commit_tree(storage_key, tree, [head], "stack commit")

    {:ok, _result} =
      GitPlane.batch_update_refs(
        storage_key,
        [%{ref: "refs/heads/stacked", expected_old: :absent, new: commit}],
        "test-stack"
      )

    {:ok, _generation, index} = WAL.read_index(storage_key)
    assert [_import, _push, batch] = WAL.entries(index)
    assert batch["format"] == "git_bundle"
    refute Map.has_key?(batch, "shallow")

    File.rm_rf!(Repos.bare_path(storage_key))

    assert :ok = Sync.ensure_fresh(storage_key, "main")
    assert shallow_boundaries(storage_key) == shallow_before
    assert Repos.refs(storage_key) == WAL.refs(index)
    assert missing_objects(storage_key, index) == []
  end

  test "an entry whose objects cannot be materialized fails closed", %{
    base: base,
    repository: repository,
    url: url
  } do
    seed_shallow_import!(base, repository.storage_key)

    work = seed_clone!(base, url)
    commit_and_push!(work, "one.txt", "one\n", "one")

    {:ok, generation, index} = WAL.read_index(repository.storage_key)

    # An entry that claims a ref its payload cannot produce. `git receive-pack`
    # exits 0 while rejecting it, so only an outcome check catches this.
    seq = WAL.next_seq(index)
    {:ok, object} = WAL.put_entry(repository.storage_key, seq, "0000")

    unreachable =
      index |> WAL.refs() |> Map.put("refs/heads/ghost", String.duplicate("b", 40))

    entry = %{
      "seq" => seq,
      "object" => object,
      "format" => "receive_pack",
      "refs" => unreachable,
      "principal" => "test",
      "pushed_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    {:ok, _generation} =
      WAL.cas_index(repository.storage_key, generation, WAL.append_entry(index, entry))

    File.rm_rf!(Repos.bare_path(repository.storage_key))

    assert {:error, %SyncError{}} = Sync.ensure_fresh(repository.storage_key, "main")
    refute CacheReadiness.ready?()
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp shallow_boundaries(storage_key) do
    case File.read(Path.join(Repos.bare_path(storage_key), "shallow")) do
      {:ok, contents} -> String.split(contents, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp missing_objects(storage_key, index) do
    path = Repos.bare_path(storage_key)

    index
    |> WAL.entries()
    |> Enum.flat_map(fn entry -> Map.to_list(entry["refs"] || %{}) end)
    |> Enum.uniq()
    |> Enum.reject(fn {_name, sha} ->
      match?({_output, 0}, Repos.git(path, ["cat-file", "-e", sha]))
    end)
  end

  # Mirrors `OpenAgents.Repositories.Importer`: a `--depth=1` fetch bundled
  # with `--all`, recorded as the seq 0 `git_bundle` entry with the shallow
  # boundaries the fetch produced.
  defp seed_shallow_import!(base, storage_key) do
    source = Path.join(base, "source")
    File.mkdir_p!(source)
    sh!(source, "git", ["init", "--initial-branch=main", "."])
    sh!(source, "git", ["config", "user.email", "test@example.com"])
    sh!(source, "git", ["config", "user.name", "Forge Test"])

    Enum.each(1..3, fn n ->
      File.write!(Path.join(source, "history-#{n}.txt"), "history #{n}\n")
      sh!(source, "git", ["add", "."])
      sh!(source, "git", ["commit", "-m", "history #{n}"])
    end)

    snapshot = Path.join(base, "snapshot.git")
    sh!(base, "git", ["init", "--bare", "--initial-branch=main", snapshot])

    sh!(base, "git", [
      "--git-dir",
      snapshot,
      "fetch",
      "--depth=1",
      source,
      "refs/heads/main:refs/heads/main"
    ])

    bundle = Path.join(base, "snapshot.bundle")
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

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp sh!(dir, "git", args), do: sh_raw!(dir, "git", ["-c", "credential.helper="] ++ args)
  defp sh!(dir, command, args), do: sh_raw!(dir, command, args)

  defp sh_raw!(dir, command, args) do
    {output, status} = System.cmd(command, args, cd: dir, stderr_to_stdout: true)
    if status != 0, do: flunk("#{command} #{Enum.join(args, " ")} failed:\n#{output}")
    output
  end

  defp seed_clone!(base, url) do
    work = Path.join(base, "clone-#{System.unique_integer([:positive])}")
    sh!(base, "git", ["clone", url, work])
    sh!(work, "git", ["config", "user.email", "test@example.com"])
    sh!(work, "git", ["config", "user.name", "Forge Test"])
    work
  end

  defp shallow_clone!(base, url) do
    work = Path.join(base, "shallow-clone-#{System.unique_integer([:positive])}")
    sh!(base, "git", ["clone", "--depth=1", url, work])
    sh!(work, "git", ["config", "user.email", "test@example.com"])
    sh!(work, "git", ["config", "user.name", "Forge Test"])
    work
  end

  defp commit_and_push!(work, filename, contents, message, branch \\ "main") do
    File.write!(Path.join(work, filename), contents)
    sh!(work, "git", ["add", "."])
    sh!(work, "git", ["commit", "-m", message])
    sh!(work, "git", ["push", "origin", "HEAD:#{branch}"])
  end
end
