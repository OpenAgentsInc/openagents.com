defmodule OpenAgents.Forge.RepoRefTest do
  @moduledoc """
  Issue #190: the name a person is told to use and the key the forge stores
  under are different strings, and the verifier is the surface where confusing
  them does the most damage.

  A rehearsal reads `OpenAgents.Forge.Repos.allowed_repos/0`, gets a name, and
  runs the verifier on it. Before this, the name went straight into a path, the
  path held a bare repository projecting nothing, and the report said
  `wal_unreadable` — "your write-ahead log is gone" — about a log that was
  intact under a different key. These tests hold the name-to-key step in place
  and hold the shadow directory harmless.
  """

  use OpenAgents.DataCase, async: false

  alias OpenAgents.Forge.{CacheReadiness, RepoRef, Repos, Sync, Verification, WAL}

  @name "openagents.com"
  @owner "OpenAgentsInc"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(OpenAgents.Repo, {:shared, self()})

    root =
      Path.join(
        System.tmp_dir!(),
        "forge-repo-ref-#{System.unique_integer([:positive, :monotonic])}"
      )

    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_wal = Application.get_env(:openagents, :forge_wal_dir)
    previous_adapter = Application.get_env(:openagents, :forge_wal_adapter)
    previous_repos = Application.get_env(:openagents, :forge_repos)

    Application.put_env(:openagents, :forge_data_dir, Path.join(root, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(root, "wal"))
    Application.put_env(:openagents, :forge_wal_adapter, OpenAgents.Forge.WAL.Local)
    Application.put_env(:openagents, :forge_repos, [@name])
    CacheReadiness.reset()

    on_exit(fn ->
      restore(:forge_data_dir, previous_data)
      restore(:forge_wal_dir, previous_wal)
      restore(:forge_wal_adapter, previous_adapter)
      restore(:forge_repos, previous_repos)
      CacheReadiness.reset()
      File.rm_rf!(root)
    end)

    # Production's shape, exactly: the first repository's row has moved off the
    # historical name-as-key and onto an opaque one, while the name it is
    # cloned and configured by has not moved at all.
    storage_key = Ecto.UUID.generate()

    repository =
      OpenAgents.Repo.get_by!(OpenAgents.Repositories.Repository,
        owner_key: String.downcase(@owner),
        name_key: @name
      )

    repository
    |> Ecto.Changeset.change(storage_key: storage_key)
    |> OpenAgents.Repo.update!()

    sha = seed_wal!(root, storage_key)

    %{root: root, storage_key: storage_key, sha: sha}
  end

  describe "the name a rehearsal is handed" do
    test "verifies the repository the forge actually serves", context do
      assert {:ok, report} = Verification.verify(@name)

      assert report.repo == @name
      assert report.storage_key == context.storage_key
      assert report.entries == 1
      assert report.findings == []
    end

    test "is the name the configuration admits", context do
      # `allowed_repos/0` is the list an operator reads before verifying, so
      # what it returns has to be a reference the verifier accepts.
      assert [name] = Repos.allowed_repos()
      assert {:ok, %{storage_key: storage_key}} = Verification.verify(name)
      assert storage_key == context.storage_key
    end

    test "resolves the same through the owner/name path, in any case", context do
      assert {:ok, %{storage_key: key}} = Verification.verify("#{@owner}/#{@name}")
      assert key == context.storage_key

      assert {:ok, %{storage_key: downcased}} =
               Verification.verify("openagentsinc/#{@name}")

      assert downcased == context.storage_key
    end

    test "is not shadowed by a bare repository standing under it", context do
      # The live node carries exactly this: a bare repository under the *name*,
      # holding one ref, beside the one under the key. It is a projection of no
      # log, so it must not be able to answer for the repository.
      shadow = seed_shadow!(context.root, @name)
      refute Repos.refs_at(shadow)["refs/heads/main"] == context.sha

      assert {:ok, report} = Verification.verify(@name)
      assert report.storage_key == context.storage_key
      assert report.findings == []
      assert report.entries == 1

      # And the shadow is still there afterwards: cleaning up production state
      # is an operator's decision, not a side effect of reading it.
      assert File.dir?(shadow)
    end
  end

  describe "a reference that names no repository" do
    test "is a typed finding rather than an empty repository", _context do
      assert {:error, report} = Verification.verify("no-such-repository")

      assert report.storage_key == nil
      assert report.entries == 0

      assert [%{code: "repository_not_found", detail: %{"repo" => "no-such-repository"}}] =
               report.findings

      # The old answer. `wal_unreadable` means the log of a known repository
      # could not be read, which is a very different report from "that name is
      # not a repository here".
      refute Enum.any?(report.findings, &(&1.code == "wal_unreadable"))
    end

    test "reports an unknown owner/name path the same way", _context do
      assert {:error, report} = Verification.verify("#{@owner}/no-such-repository")
      assert report.storage_key == nil
      assert [%{code: "repository_not_found"}] = report.findings
    end

    test "reports a name two repositories answer to as ambiguous", _context do
      for owner <- ["FirstOwner", "SecondOwner"] do
        {:ok, _repository} =
          OpenAgents.Repositories.create_repository(%{
            owner: owner,
            name: "shared",
            visibility: "public",
            default_branch: "main",
            storage_key: Ecto.UUID.generate()
          })
      end

      assert {:error, %{storage_key: nil, findings: findings}} = Verification.verify("shared")
      assert [%{code: "repository_name_ambiguous", detail: %{"repo" => "shared"}}] = findings

      # Naming the owner settles it.
      assert {:error, %{storage_key: storage_key, findings: settled}} =
               Verification.verify("FirstOwner/shared")

      refute is_nil(storage_key)
      assert [%{code: "wal_unreadable"}] = settled
    end
  end

  describe "a storage key" do
    test "resolves to itself without consulting the repositories table", context do
      assert RepoRef.storage_key(context.storage_key) == {:ok, context.storage_key}
      assert {:ok, %{repo: repo, storage_key: key}} = Verification.verify(context.storage_key)
      assert repo == context.storage_key
      assert key == context.storage_key
    end

    test "resolves to itself when its log predates the repositories table", context do
      # A repository whose key is its own name and which has no row at all —
      # the shape of the forge's oldest logs. The WAL is what settles it.
      _sha = seed_wal!(context.root, "legacy-key")

      assert RepoRef.storage_key("legacy-key") == {:ok, "legacy-key"}
      assert {:ok, %{findings: [], storage_key: "legacy-key"}} = Verification.verify("legacy-key")
    end
  end

  # The live node's shadow: a bare repository under the *name*, holding one ref
  # at a commit the served repository never had, and no WAL of its own.
  defp seed_shadow!(root, name) do
    stale = Path.join(root, "stale-source")
    File.mkdir_p!(stale)
    git!(stale, ["init", "--initial-branch=main"])
    git!(stale, ["config", "user.email", "test@example.com"])
    git!(stale, ["config", "user.name", "Forge test"])
    File.write!(Path.join(stale, "README.md"), "left behind\n")
    git!(stale, ["add", "README.md"])
    git!(stale, ["commit", "-m", "A commit the served repository passed long ago"])

    shadow = Repos.ensure_repo!(name)
    {_output, 0} = Repos.git(shadow, ["fetch", stale, "main:refs/heads/main"])

    shadow
  end

  defp restore(key, nil), do: Application.delete_env(:openagents, key)
  defp restore(key, value), do: Application.put_env(:openagents, key, value)

  # One real commit, bundled, recorded as one WAL entry, materialized into the
  # bare repository the way a push would leave it.
  defp seed_wal!(root, storage_key) do
    source = Path.join(root, "source-#{storage_key}")
    File.mkdir_p!(source)
    git!(source, ["init", "--initial-branch=main"])
    git!(source, ["config", "user.email", "test@example.com"])
    git!(source, ["config", "user.name", "Forge test"])
    File.write!(Path.join(source, "README.md"), "served\n")
    git!(source, ["add", "README.md"])
    git!(source, ["commit", "-m", "Served commit"])

    sha = source |> git!(["rev-parse", "HEAD"]) |> String.trim()
    bundle = Path.join(root, "#{storage_key}.bundle")
    git!(source, ["bundle", "create", bundle, "--all"])

    {:ok, object} = WAL.put_entry_file(storage_key, 0, bundle)

    entry = %{
      "seq" => 0,
      "object" => object,
      "format" => "git_bundle",
      "refs" => %{"refs/heads/main" => sha},
      "principal" => "test:repo-ref",
      "pushed_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    {:ok, _generation} =
      WAL.cas_index(storage_key, :none, WAL.append_entry(WAL.new_index(), entry))

    :ok = Sync.ensure_fresh(storage_key)

    sha
  end

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    output
  end
end
