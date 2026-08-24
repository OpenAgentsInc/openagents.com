defmodule OpenAgents.Repositories.UpstreamMirrorTest do
  @moduledoc """
  An upstream mirror: a repository whose content comes from a public source
  this forge does not own.

  Four properties, and each is proved against the mechanism rather than
  against a message. The upstream is recorded; the license travels or its
  absence is recorded; the ordinary import path cannot produce a mirror
  however its attributes are shaped; and the copy carries whole history, so a
  clone of it walks to the root and passes `git fsck --full` (#179, EXIT-004).
  """

  use OpenAgents.DataCase, async: false

  import OpenAgents.AccountsFixtures

  alias Ecto.Adapters.SQL
  alias OpenAgents.Forge.{Repos, Sync, WAL}
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.{Importer, Repository}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "upstream-mirror-#{System.unique_integer([:positive, :monotonic])}"
      )

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

  describe "creating a mirror" do
    test "records the upstream and the license it found" do
      user = repository_user_fixture("mirror-owner")

      assert {:ok, repository, _import, :created} =
               Repositories.create_user_mirror(
                 user,
                 foreign_source(license: "MIT"),
                 %{name: "walgit", visibility: "public"},
                 "mirror-create-key"
               )

      assert repository.upstream_url == "https://github.com/tobi/walgit"
      assert repository.upstream_license == "MIT"
      assert Repositories.mirror?(repository)
    end

    test "records the absence of a license rather than leaving it blank" do
      user = repository_user_fixture("mirror-unlicensed-owner")

      assert {:ok, repository, _import, :created} =
               Repositories.create_user_mirror(
                 user,
                 foreign_source(license: nil),
                 %{name: "unlicensed", visibility: "public"},
                 "mirror-unlicensed-key"
               )

      assert repository.upstream_license == "none"
    end

    test "a license GitHub could not identify is an absence, not an identifier" do
      user = repository_user_fixture("mirror-noassertion-owner")

      assert {:ok, repository, _import, :created} =
               Repositories.create_user_mirror(
                 user,
                 foreign_source(license: "NOASSERTION"),
                 %{name: "noassertion", visibility: "public"},
                 "mirror-noassertion-key"
               )

      assert repository.upstream_license == "none"
    end

    test "a private source cannot become a mirror" do
      user = repository_user_fixture("mirror-private-owner")

      assert {:error, :source_repository_not_public} =
               Repositories.create_user_mirror(
                 user,
                 foreign_source(public: false),
                 %{name: "private-source", visibility: "public"},
                 "mirror-private-key"
               )
    end

    test "the database refuses an upstream recorded without its license" do
      user = repository_user_fixture("mirror-halfrecord-owner")

      assert {:ok, repository, :created} =
               Repositories.create_user_repository(user, %{name: "owned"}, "half-record-key")

      # The license does not travel by convention. The two columns are NULL
      # together or set together, so "a mirror whose license nobody recorded"
      # is not a state this database can hold, however it is reached.
      assert_raise Postgrex.Error, ~r/repositories_upstream_mirror_check/, fn ->
        SQL.query!(
          OpenAgents.Repo,
          "UPDATE repositories SET upstream_url = $1 WHERE id = $2",
          ["https://github.com/tobi/walgit", Ecto.UUID.dump!(repository.id)]
        )
      end
    end
  end

  describe "the owner-identity gate" do
    test "an import of a source owned by someone else is still refused" do
      user = repository_user_fixture("import-foreign-owner")

      assert {:error, :source_namespace_mismatch} =
               Repositories.create_user_import(
                 user,
                 foreign_source(),
                 %{name: "walgit", visibility: "public"},
                 "import-foreign-key"
               )
    end

    test "the import path cannot produce a mirror, whatever attributes it is given" do
      user = repository_user_fixture("import-attrs-owner")

      # The source owner is this account, so the owner gate admits the import
      # and cannot be what refuses the upstream fields. What refuses them is
      # that `changeset/2` never casts them: only
      # `Repository.mirror_creation_changeset/6` writes an upstream, and only
      # `create_user_mirror/4` reaches it.
      assert {:ok, repository, _import, :created} =
               Repositories.create_user_import(
                 user,
                 %{foreign_source() | source_owner_id: user.github_id},
                 %{
                   name: "not-a-mirror",
                   visibility: "public",
                   upstream_url: "https://github.com/tobi/walgit",
                   upstream_license: "MIT"
                 },
                 "import-attrs-key"
               )

      assert repository.upstream_url == nil
      assert repository.upstream_license == nil
      refute Repositories.mirror?(repository)
    end

    test "an ordinary repository cannot be given an upstream through the update changeset" do
      user = repository_user_fixture("update-attrs-owner")

      assert {:ok, repository, :created} =
               Repositories.create_user_repository(user, %{name: "owned"}, "update-attrs-key")

      changeset =
        Repository.changeset(repository, %{
          upstream_url: "https://github.com/tobi/walgit",
          upstream_license: "MIT"
        })

      refute Map.has_key?(changeset.changes, :upstream_url)
      refute Map.has_key?(changeset.changes, :upstream_license)
    end
  end

  describe "copying the history" do
    test "a mirror carries whole history, records an empty boundary, and clones clean",
         %{root: root} do
      source = source_repository!(root, "mirror-source", 3)
      user = repository_user_fixture("mirror-history-owner")

      {:ok, repository, _import, :created} =
        Repositories.create_user_mirror(
          user,
          source_record(source, "tobi/walgit"),
          %{name: "walgit", visibility: "public", default_branch: "main"},
          "mirror-history-key"
        )

      assert :ok = Importer.import(repository, source_url: source)

      # #179: a WAL entry that records no boundary is the failure. This one
      # records an empty boundary, which is a statement that there is none.
      assert {:ok, _generation, index} = WAL.read_index(repository.storage_key)
      assert [%{"shallow" => []}] = WAL.entries(index)

      assert :ok = Sync.ensure_fresh(repository.storage_key, "main")
      bare = Repos.bare_path(repository.storage_key)

      refute File.exists?(Path.join(bare, "shallow"))
      assert count_commits(bare) == 3

      # The population is closed by the walk, not by the ref list: clone over
      # a real transport, then fsck the copy. A repository holding every tip
      # can still be impossible to clone.
      work = Path.join(root, "mirror-clone")
      assert {_output, 0} = System.cmd("git", ["clone", "file://" <> bare, work])
      assert count_commits(work) == 3
      assert {output, 0} = System.cmd("git", ["fsck", "--full"], cd: work)
      refute output =~ "missing"
      refute output =~ "broken"
    end

    test "an owned import still takes the tip and states the boundary it produced",
         %{root: root} do
      source = source_repository!(root, "import-source", 3)
      user = repository_user_fixture("import-history-owner")

      {:ok, repository, _import, :created} =
        Repositories.create_user_import(
          user,
          %{
            source_record(source, "import-history-owner/source")
            | source_owner_id: user.github_id
          },
          %{name: "shallow-copy", visibility: "public", default_branch: "main"},
          "import-history-key"
        )

      assert :ok = Importer.import(repository, source_url: source)

      assert {:ok, _generation, index} = WAL.read_index(repository.storage_key)
      assert [%{"shallow" => [_boundary]}] = WAL.entries(index)

      assert :ok = Sync.ensure_fresh(repository.storage_key, "main")
      bare = Repos.bare_path(repository.storage_key)

      assert File.exists?(Path.join(bare, "shallow"))
      assert count_commits(bare) == 1
    end
  end

  defp count_commits(path) do
    {output, 0} = System.cmd("git", ["rev-list", "--count", "HEAD"], cd: path)
    output |> String.trim() |> String.to_integer()
  end

  defp source_repository!(root, name, commits) do
    path = Path.join(root, name)
    File.mkdir_p!(path)
    git!(path, ["init", "--initial-branch=main"])
    git!(path, ["config", "user.email", "test@example.com"])
    git!(path, ["config", "user.name", "Mirror test"])

    Enum.each(1..commits, fn index ->
      File.write!(Path.join(path, "README.md"), "revision #{index}\n")
      git!(path, ["add", "README.md"])
      git!(path, ["commit", "-m", "Revision #{index}"])
    end)

    path
  end

  defp source_record(source, full_name) do
    sha = source |> git!(["rev-parse", "HEAD"]) |> String.trim()
    refs = %{"refs/heads/main" => sha}

    %{
      source_repository_id: 909,
      source_owner_id: 777_777,
      source_full_name: full_name,
      source_default_branch: "main",
      source_ref_digest: ref_digest(source, refs),
      source_head_sha: sha,
      source_refs: refs,
      source_uses_lfs: false,
      source_public: true,
      source_license: "MIT"
    }
  end

  defp foreign_source(options \\ []) do
    %{
      source_repository_id: 909,
      source_owner_id: 777_777,
      source_full_name: "tobi/walgit",
      source_default_branch: "main",
      source_ref_digest: String.duplicate("a", 64),
      source_head_sha: String.duplicate("e", 40),
      source_refs: %{"refs/heads/main" => String.duplicate("e", 40)},
      source_uses_lfs: false,
      source_public: Keyword.get(options, :public, true),
      source_license: Keyword.get(options, :license, "MIT")
    }
  end

  defp git!(directory, args) do
    {output, 0} = System.cmd("git", args, cd: directory, stderr_to_stdout: true)
    output
  end

  defp ref_digest(source, refs) do
    refs
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join("\n", fn {name, sha} ->
      object_type = source |> git!(["cat-file", "-t", sha]) |> String.trim()
      Enum.join([name, object_type, sha], "\0")
    end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)
end
