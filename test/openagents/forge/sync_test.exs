defmodule OpenAgents.Forge.SyncTest do
  use ExUnit.Case, async: false

  alias OpenAgents.Forge.{Browse, CacheReadiness, Repos, Sync, SyncError, WAL}
  alias OpenAgents.Repositories.Repository

  setup do
    root =
      Path.join(System.tmp_dir!(), "forge-sync-#{System.unique_integer([:positive, :monotonic])}")

    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_wal = Application.get_env(:openagents, :forge_wal_dir)
    previous_adapter = Application.get_env(:openagents, :forge_wal_adapter)

    Application.put_env(:openagents, :forge_data_dir, Path.join(root, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(root, "wal"))
    Application.put_env(:openagents, :forge_wal_adapter, OpenAgents.Forge.WAL.Local)
    CacheReadiness.reset()

    on_exit(fn ->
      restore_env(:forge_data_dir, previous_data)
      restore_env(:forge_wal_dir, previous_wal)
      restore_env(:forge_wal_adapter, previous_adapter)
      CacheReadiness.reset()
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "a Git bundle WAL entry survives deletion of the bare cache", %{root: root} do
    source = Path.join(root, "source")
    File.mkdir_p!(source)
    git!(source, ["init", "--initial-branch=trunk"])
    git!(source, ["config", "user.email", "test@example.com"])
    git!(source, ["config", "user.name", "Forge test"])
    File.write!(Path.join(source, "README.md"), "durable import\n")
    git!(source, ["add", "README.md"])
    git!(source, ["commit", "-m", "Imported commit"])
    git!(source, ["tag", "v1"])

    sha = source |> git!(["rev-parse", "HEAD"]) |> String.trim()
    bundle = Path.join(root, "source.bundle")
    git!(source, ["bundle", "create", bundle, "--all"])
    refs = %{"refs/heads/trunk" => sha, "refs/tags/v1" => sha}

    index = WAL.new_index()
    {:ok, object} = WAL.put_entry_file("storage-key", 0, bundle)

    entry = %{
      "seq" => 0,
      "object" => object,
      "format" => "git_bundle",
      "refs" => refs,
      "principal" => "github-import:test",
      "pushed_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    {:ok, _generation} = WAL.cas_index("storage-key", :none, WAL.append_entry(index, entry))

    assert :ok = Sync.ensure_fresh("storage-key", "trunk")
    assert Repos.refs("storage-key") == refs

    assert String.trim(git_bare!(Repos.bare_path("storage-key"), ["symbolic-ref", "HEAD"])) ==
             "refs/heads/trunk"

    bare_path = Repos.bare_path("storage-key")
    File.rm_rf!(Path.join(bare_path, "objects"))
    File.mkdir_p!(Path.join(bare_path, "objects"))

    assert :ok = Sync.ensure_fresh("storage-key", "trunk")
    assert String.trim(git_bare!(bare_path, ["show", "trunk:README.md"])) == "durable import"

    File.rm_rf!(bare_path)
    repository = %Repository{storage_key: "storage-key", default_branch: "trunk"}

    assert {:ok, ^sha} = Browse.head(repository)
    assert Repos.refs("storage-key") == refs

    assert String.trim(git_bare!(Repos.bare_path("storage-key"), ["show", "trunk:README.md"])) ==
             "durable import"
  end

  test "an authoritative empty ref map deletes stale local refs", %{root: root} do
    source = Path.join(root, "stale-source")
    File.mkdir_p!(source)
    git!(source, ["init", "--initial-branch=main"])
    git!(source, ["config", "user.email", "test@example.com"])
    git!(source, ["config", "user.name", "Forge test"])
    File.write!(Path.join(source, "stale.txt"), "stale\n")
    git!(source, ["add", "stale.txt"])
    git!(source, ["commit", "-m", "Stale commit"])

    Repos.ensure_repo!("empty-authority")

    {_output, 0} =
      Repos.git(Repos.bare_path("empty-authority"), [
        "fetch",
        source,
        "refs/heads/main:refs/heads/main"
      ])

    refute Repos.refs("empty-authority") == %{}

    assert :ok = Sync.replay_missing("empty-authority", WAL.new_index())
    assert Repos.refs("empty-authority") == %{}
  end

  test "a failed sibling rebuild preserves the last complete cache and fails with 503", %{
    root: root
  } do
    {valid_index, sha} = put_bundle_entry!(root, "unavailable-cache", "trunk")
    assert :ok = Sync.ensure_fresh("unavailable-cache", "trunk")

    bare_path = Repos.bare_path("unavailable-cache")
    Repos.record_applied_seq_at!(bare_path, 1)

    missing_entry = %{
      "seq" => 1,
      "object" => "entries/00000001-000000000000",
      "format" => "git_bundle",
      "refs" => %{"refs/heads/trunk" => String.duplicate("a", 40)},
      "principal" => "test",
      "pushed_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    {:ok, generation, _index} = WAL.read_index("unavailable-cache")

    {:ok, next_generation} =
      WAL.cas_index("unavailable-cache", generation, WAL.append_entry(valid_index, missing_entry))

    assert {:error, %SyncError{operation: :rebuild_entry, plug_status: 503} = error} =
             Sync.ensure_fresh("unavailable-cache", "trunk")

    assert Plug.Exception.status(error) == 503
    refute CacheReadiness.ready?()
    assert CacheReadiness.report()["failures"] == %{"unavailable-cache" => :rebuild_entry}

    # The rebuild failed before activation, so readers never receive a partial
    # repository and the last complete cache remains available for recovery.
    assert String.trim(git_bare!(bare_path, ["show", "trunk:README.md"])) == "durable import"
    assert Repos.refs("unavailable-cache") == %{"refs/heads/trunk" => sha}
    assert Path.wildcard(bare_path <> ".rebuild-*") == []
    assert Path.wildcard(bare_path <> ".previous-*") == []

    repository = %Repository{storage_key: "unavailable-cache", default_branch: "trunk"}
    assert_raise SyncError, fn -> Browse.blob(repository, "trunk", "README.md") end

    # Once the authority becomes materializable again, the next successful
    # synchronization restores this node's readiness without a restart.
    assert {:ok, _generation} =
             WAL.cas_index("unavailable-cache", next_generation, valid_index)

    assert :ok = Sync.ensure_fresh("unavailable-cache", "trunk")
    assert CacheReadiness.ready?()
  end

  test "concurrent readers serialize one repository cache replay", %{root: root} do
    {_index, sha} = put_bundle_entry!(root, "serialized-cache", "trunk")

    results =
      1..12
      |> Task.async_stream(
        fn _reader -> Sync.ensure_fresh("serialized-cache", "trunk") end,
        max_concurrency: 12,
        timeout: 10_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, :ok}))
    assert Repos.refs("serialized-cache") == %{"refs/heads/trunk" => sha}
    assert CacheReadiness.ready?()
  end

  test "cluster warming materializes the local cache and every connected peer" do
    test_process = self()
    peer = :"peer@127.0.0.1"

    rpc = fn target, module, function, arguments, timeout ->
      send(test_process, {:cluster_warm_rpc, target, module, function, arguments, timeout})
      :ok
    end

    assert :ok =
             Sync.ensure_cluster_fresh("cluster-warm", "trunk",
               members: fn -> [node(), peer] end,
               rpc: rpc,
               timeout_ms: 5_000
             )

    assert_received {:cluster_warm_rpc, ^peer, Sync, :ensure_fresh, ["cluster-warm", "trunk"],
                     5_000}
  end

  test "cluster warming reports a peer failure" do
    peer = :"peer@127.0.0.1"

    assert {:error, :noconnection} =
             Sync.ensure_cluster_fresh("cluster-warm-failure", "main",
               members: fn -> [peer] end,
               rpc: fn _target, _module, _function, _arguments, _timeout ->
                 {:error, :noconnection}
               end,
               timeout_ms: 5_000
             )
  end

  test "rebuild re-materializes the projection from sequence zero and preserves the head", %{
    root: root
  } do
    {index, sha} = put_bundle_entry!(root, "rebuild-repo", "trunk")
    assert :ok = Sync.ensure_fresh("rebuild-repo", "trunk")

    # Append a second commit so the WAL holds more than the trivial first
    # entry; the rebuilt projection must end at the newest head.
    source = Path.join(root, "rebuild-repo-source")
    File.write!(Path.join(source, "second.md"), "second commit\n")
    git!(source, ["add", "second.md"])
    git!(source, ["commit", "-m", "Second commit"])

    sha2 = source |> git!(["rev-parse", "HEAD"]) |> String.trim()
    refs = %{"refs/heads/trunk" => sha2}
    bundle = Path.join(root, "rebuild-repo-2.bundle")
    git!(source, ["bundle", "create", bundle, "--all"])

    {:ok, object} = WAL.put_entry_file("rebuild-repo", 1, bundle)

    entry = %{
      "seq" => 1,
      "object" => object,
      "format" => "git_bundle",
      "refs" => refs,
      "principal" => "test",
      "pushed_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    {:ok, generation, _} = WAL.read_index("rebuild-repo")
    {:ok, _} = WAL.cas_index("rebuild-repo", generation, WAL.append_entry(index, entry))
    assert :ok = Sync.ensure_fresh("rebuild-repo", "trunk")

    bare_path = Repos.bare_path("rebuild-repo")
    assert String.trim(git_bare!(bare_path, ["rev-parse", "trunk"])) == sha2

    # Rebuild is the operator recovery for a *wrong* projection: discard and
    # re-materialize from sequence zero. It must land on the same head.
    assert :ok = Sync.rebuild("rebuild-repo", "trunk")

    assert String.trim(git_bare!(bare_path, ["rev-parse", "trunk"])) == sha2
    assert Repos.refs("rebuild-repo") == refs
    assert String.trim(git_bare!(bare_path, ["show", "trunk:second.md"])) == "second commit"

    # The one-argument form the runbooks name resolves the default branch the
    # same way ensure_fresh/1 does, so `Sync.rebuild("{storage_key}")` runs.
    assert :ok = Sync.rebuild("rebuild-repo")
    assert String.trim(git_bare!(bare_path, ["rev-parse", "trunk"])) == sha2
    assert String.trim(git_bare!(bare_path, ["symbolic-ref", "HEAD"])) == "refs/heads/trunk"
  end


    {output, 0} = System.cmd("git", args, cd: directory, stderr_to_stdout: true)
    output
  end

  defp git_bare!(directory, args) do
    {output, 0} = Repos.git(directory, args)
    output
  end

  defp put_bundle_entry!(root, repository, branch) do
    source = Path.join(root, "#{repository}-source")
    File.mkdir_p!(source)
    git!(source, ["init", "--initial-branch=#{branch}"])
    git!(source, ["config", "user.email", "test@example.com"])
    git!(source, ["config", "user.name", "Forge test"])
    File.write!(Path.join(source, "README.md"), "durable import\n")
    git!(source, ["add", "README.md"])
    git!(source, ["commit", "-m", "Imported commit"])

    sha = source |> git!(["rev-parse", "HEAD"]) |> String.trim()
    bundle = Path.join(root, "#{repository}.bundle")
    git!(source, ["bundle", "create", bundle, "--all"])
    refs = %{"refs/heads/#{branch}" => sha}

    {:ok, object} = WAL.put_entry_file(repository, 0, bundle)

    entry = %{
      "seq" => 0,
      "object" => object,
      "format" => "git_bundle",
      "refs" => refs,
      "principal" => "test",
      "pushed_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    index = WAL.append_entry(WAL.new_index(), entry)
    {:ok, _generation} = WAL.cas_index(repository, :none, index)
    {index, sha}
  end

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)
end
