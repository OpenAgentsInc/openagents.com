defmodule OpenAgents.Chat.Tools.RepositoryFileTest do
  use OpenAgents.DataCase, async: false

  import OpenAgents.AccountsFixtures

  alias OpenAgents.Chat.Tools.RepositoryFile
  alias OpenAgents.Forge.{Repos, WAL}
  alias OpenAgents.Repositories

  setup do
    base =
      Path.join(System.tmp_dir!(), "repository-file-tool-#{System.unique_integer([:positive])}")

    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_wal = Application.get_env(:openagents, :forge_wal_dir)
    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))

    on_exit(fn ->
      restore_env(:forge_data_dir, previous_data)
      restore_env(:forge_wal_dir, previous_wal)
      File.rm_rf(base)
    end)

    user = repository_user_fixture("repository-reader")
    suffix = System.unique_integer([:positive, :monotonic])
    owner = "ToolOrg#{suffix}"
    name = "tool-repo-#{suffix}"

    {:ok, repository} =
      Repositories.create_repository(%{
        owner: owner,
        name: name,
        visibility: "public",
        default_branch: "main"
      })

    seed_repository(repository.storage_key)
    %{repository: repository, repository_path: "#{owner}/#{name}", user: user}
  end

  test "reads a named file from an accessible repository", %{
    user: user,
    repository_path: repository_path
  } do
    assert {:ok,
            %{
              "repository" => ^repository_path,
              "ref" => "main",
              "path" => "README.md",
              "content" => "# OpenAgents\n\nConnected repository fixture.\n",
              "truncated" => false
            }} =
             RepositoryFile.execute(
               "read_repository_file",
               Jason.encode!(%{
                 "repository" => repository_path,
                 "path" => "README.md",
                 "ref" => nil
               }),
               %{user: user}
             )
  end

  test "resolves an unambiguous repository name and its README", %{
    repository: repository,
    user: user
  } do
    assert {:ok, %{"path" => "README.md", "content" => "# OpenAgents\n" <> _rest}} =
             RepositoryFile.execute(
               "read_repository_file",
               Jason.encode!(%{"repository" => repository.name, "path" => nil, "ref" => nil}),
               %{user: user}
             )
  end

  test "normalizes string null values emitted by a model", %{
    repository_path: repository_path,
    user: user
  } do
    assert {:ok,
            %{
              "path" => "README.md",
              "ref" => "main",
              "content" => "# OpenAgents\n" <> _rest
            }} =
             RepositoryFile.execute(
               "read_repository_file",
               Jason.encode!(%{
                 "repository" => repository_path,
                 "path" => "null",
                 "ref" => "null"
               }),
               %{user: user}
             )
  end

  test "does not disclose a private repository without membership", %{user: user} do
    {:ok, private_repository} =
      Repositories.create_repository(%{
        owner: "PrivateOrg",
        name: "private-repo",
        visibility: "private",
        default_branch: "main"
      })

    seed_repository(private_repository.storage_key)

    assert {:error, "The repository does not exist or you cannot access it."} =
             RepositoryFile.execute(
               "read_repository_file",
               Jason.encode!(%{
                 "repository" => "PrivateOrg/private-repo",
                 "path" => "README.md",
                 "ref" => nil
               }),
               %{user: user}
             )
  end

  test "reads a private repository for a member", %{user: user} do
    {:ok, private_repository} =
      Repositories.create_repository(%{
        owner: "MemberOrg",
        name: "member-repo",
        visibility: "private",
        default_branch: "main"
      })

    :ok = seed_repository(private_repository.storage_key)
    assert {:ok, _membership} = Repositories.add_member(private_repository, user, "viewer")

    assert {:ok, %{"content" => "# OpenAgents\n" <> _rest}} =
             RepositoryFile.execute(
               "read_repository_file",
               Jason.encode!(%{
                 "repository" => "MemberOrg/member-repo",
                 "path" => "README.md",
                 "ref" => nil
               }),
               %{user: user}
             )
  end

  test "rejects repository path traversal", %{user: user, repository_path: repository_path} do
    assert {:error,
            "The requested file or ref does not exist. List the parent directory before trying another path."} =
             RepositoryFile.execute(
               "read_repository_file",
               Jason.encode!(%{
                 "repository" => repository_path,
                 "path" => "../secrets",
                 "ref" => nil
               }),
               %{user: user}
             )
  end

  test "lists repository directories with exact paths", %{
    user: user,
    repository_path: repository_path
  } do
    assert {:ok, %{"path" => "", "entries" => root_entries}} =
             RepositoryFile.execute(
               "list_repository_directory",
               Jason.encode!(%{"repository" => repository_path, "path" => nil, "ref" => nil}),
               %{user: user}
             )

    assert Enum.any?(root_entries, &match?(%{"path" => "README.md", "type" => "file"}, &1))
    assert Enum.any?(root_entries, &match?(%{"path" => "docs", "type" => "directory"}, &1))

    assert {:ok,
            %{
              "path" => "docs/runbooks",
              "entries" => [
                %{"path" => "docs/runbooks/production.md", "type" => "file"}
              ]
            }} =
             RepositoryFile.execute(
               "list_repository_directory",
               Jason.encode!(%{
                 "repository" => repository_path,
                 "path" => "docs/runbooks",
                 "ref" => "main"
               }),
               %{user: user}
             )
  end

  test "reports a missing directory without inventing alternatives", %{
    user: user,
    repository_path: repository_path
  } do
    assert {:error, "The requested directory or ref does not exist."} =
             RepositoryFile.execute(
               "list_repository_directory",
               Jason.encode!(%{
                 "repository" => repository_path,
                 "path" => "docs/missing",
                 "ref" => nil
               }),
               %{user: user}
             )
  end

  defp seed_repository(storage_key) do
    path = Repos.ensure_repo!(storage_key)

    blob =
      git!(
        path,
        ["hash-object", "-w", "--stdin"],
        "# OpenAgents\n\nConnected repository fixture.\n"
      )

    runbook_blob =
      git!(
        path,
        ["hash-object", "-w", "--stdin"],
        "# Production runbook\n\nDeploy only verified revisions.\n"
      )

    runbooks_tree = git!(path, ["mktree"], "100644 blob #{runbook_blob}\tproduction.md\n")
    docs_tree = git!(path, ["mktree"], "040000 tree #{runbooks_tree}\trunbooks\n")

    tree =
      git!(
        path,
        ["mktree"],
        "100644 blob #{blob}\tREADME.md\n040000 tree #{docs_tree}\tdocs\n"
      )

    commit =
      git!(path, ["commit-tree", tree, "-m", "Seed repository"], "",
        env: [
          {"GIT_AUTHOR_NAME", "Test Author"},
          {"GIT_AUTHOR_EMAIL", "author@example.test"},
          {"GIT_COMMITTER_NAME", "Test Author"},
          {"GIT_COMMITTER_EMAIL", "author@example.test"}
        ]
      )

    {_, 0} = Repos.git(path, ["update-ref", "refs/heads/main", commit])
    refs = %{"refs/heads/main" => commit}

    bundle_path =
      Path.join(
        System.tmp_dir!(),
        "repository-tool-bundle-#{System.unique_integer([:positive, :monotonic])}.bundle"
      )

    {_, 0} = Repos.git(path, ["bundle", "create", bundle_path, "--all"])

    index =
      case WAL.read_index(storage_key) do
        {:ok, _generation, index} -> index
        {:error, :not_found} -> WAL.new_index()
      end

    generation =
      case WAL.read_index(storage_key) do
        {:ok, generation, _index} -> generation
        {:error, :not_found} -> :none
      end

    sequence = WAL.next_seq(index)
    {:ok, object} = WAL.put_entry_file(storage_key, sequence, bundle_path)

    entry = %{
      "seq" => sequence,
      "object" => object,
      "format" => "git_bundle",
      "refs" => refs,
      "principal" => "repository-file-tool-test",
      "pushed_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    try do
      {:ok, _generation} = WAL.cas_index(storage_key, generation, WAL.append_entry(index, entry))
      :ok
    after
      File.rm(bundle_path)
    end
  end

  defp git!(git_dir, args, input, options \\ []) do
    input_path =
      Path.join(System.tmp_dir!(), "repository-tool-input-#{System.unique_integer([:positive])}")

    File.write!(input_path, input)

    try do
      {output, 0} =
        System.cmd(
          "sh",
          ["-c", ~s(exec git --git-dir "$GIT_DIR" "$@" < "$INPUT_PATH"), "sh"] ++ args,
          env:
            [
              {"GIT_DIR", git_dir},
              {"INPUT_PATH", input_path}
            ] ++ Keyword.get(options, :env, [])
        )

      String.trim(output)
    after
      File.rm(input_path)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)
end
