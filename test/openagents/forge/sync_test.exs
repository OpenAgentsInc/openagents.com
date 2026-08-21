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
    payload = File.read!(bundle)
    refs = %{"refs/heads/trunk" => sha, "refs/tags/v1" => sha}

    index = WAL.new_index()
    {:ok, object} = WAL.put_entry("storage-key", 0, payload)

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

    File.rm_rf!(Repos.bare_path("storage-key"))
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
