defmodule OpenAgents.Forge.SyncTest do
  use ExUnit.Case, async: false

  alias OpenAgents.Forge.{Browse, Repos, Sync, WAL}
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

    on_exit(fn ->
      restore_env(:forge_data_dir, previous_data)
      restore_env(:forge_wal_dir, previous_wal)
      restore_env(:forge_wal_adapter, previous_adapter)
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

  defp git!(directory, args) do
    {output, 0} = System.cmd("git", args, cd: directory, stderr_to_stdout: true)
    output
  end

  defp git_bare!(directory, args) do
    {output, 0} = Repos.git(directory, args)
    output
  end

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)
end
