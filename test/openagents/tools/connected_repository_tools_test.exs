defmodule OpenAgents.Tools.ConnectedRepositoryToolsTest do
  use OpenAgents.DataCase, async: false

  import OpenAgents.AccountsFixtures

  alias OpenAgents.Forge.{Repos, WAL}
  alias OpenAgents.Repositories

  alias OpenAgents.Tools.{
    ConnectedRepositoryList,
    ConnectedRepositoryRead,
    ExecutionContext,
    Registry,
    Runner
  }

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "connected-repository-tools-#{System.unique_integer([:positive])}"
      )

    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_wal = Application.get_env(:openagents, :forge_wal_dir)
    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))

    on_exit(fn ->
      restore_env(:forge_data_dir, previous_data)
      restore_env(:forge_wal_dir, previous_wal)
      File.rm_rf(base)
    end)

    user = repository_user_fixture("connected-repository-reader")
    suffix = System.unique_integer([:positive, :monotonic])
    owner = "RegistryOrg#{suffix}"
    name = "registry-repo-#{suffix}"

    {:ok, repository} =
      Repositories.create_repository(%{
        owner: owner,
        name: name,
        visibility: "public",
        default_branch: "main"
      })

    seed_repository(repository.storage_key)
    {:ok, snapshot} = Registry.build([ConnectedRepositoryRead, ConnectedRepositoryList])

    %{
      context: context(user.id),
      repository: repository,
      repository_path: "#{owner}/#{name}",
      snapshot: snapshot,
      user: user
    }
  end

  test "reads a connected repository file through the registry runner", %{
    context: context,
    repository: repository,
    repository_path: repository_path,
    snapshot: snapshot
  } do
    assert {:ok, outcome} =
             run(snapshot, context, "read_repository_file", %{
               "repository" => repository_path,
               "path" => "README.md",
               "ref" => ""
             })

    assert outcome["status"] == "succeeded"
    assert outcome["result"]["repository"] == repository_path
    assert outcome["result"]["path"] == "README.md"
    assert outcome["result"]["content"] == "# OpenAgents\n\nConnected repository fixture.\n"
    assert outcome["target_receipt_refs"] == ["forge-repository:#{repository.id}"]
  end

  test "uses an empty file path to read the default README", %{
    context: context,
    repository: repository,
    snapshot: snapshot
  } do
    assert {:ok, outcome} =
             run(snapshot, context, "read_repository_file", %{
               "repository" => repository.name,
               "path" => "",
               "ref" => ""
             })

    assert outcome["status"] == "succeeded"
    assert outcome["result"]["path"] == "README.md"
  end

  test "normalizes string null defaults emitted by a provider", %{
    context: context,
    repository_path: repository_path,
    snapshot: snapshot
  } do
    assert {:ok, outcome} =
             run(snapshot, context, "read_repository_file", %{
               "repository" => repository_path,
               "path" => "null",
               "ref" => "null"
             })

    assert outcome["status"] == "succeeded"
    assert outcome["result"]["path"] == "README.md"
    assert outcome["result"]["ref"] == "main"
  end

  test "lists exact repository-relative directory paths", %{
    context: context,
    repository_path: repository_path,
    snapshot: snapshot
  } do
    assert {:ok, root} =
             run(snapshot, context, "list_repository_directory", %{
               "repository" => repository_path,
               "path" => "",
               "ref" => "main"
             })

    assert root["status"] == "succeeded"
    assert Enum.any?(root["result"]["entries"], &match?(%{"path" => "README.md"}, &1))
    assert Enum.any?(root["result"]["entries"], &match?(%{"path" => "docs"}, &1))

    assert {:ok, nested} =
             run(snapshot, context, "list_repository_directory", %{
               "repository" => repository_path,
               "path" => "docs/runbooks",
               "ref" => "main"
             })

    assert nested["result"]["entries"] == [
             %{
               "name" => "production.md",
               "path" => "docs/runbooks/production.md",
               "type" => "file",
               "size_bytes" => 54
             }
           ]
  end

  test "rejects traversal before it reaches Forge.Browse", %{
    context: context,
    repository_path: repository_path,
    snapshot: snapshot
  } do
    assert {:ok, outcome} =
             run(snapshot, context, "read_repository_file", %{
               "repository" => repository_path,
               "path" => "../secrets",
               "ref" => "main"
             })

    assert outcome["status"] == "failed"
    assert outcome["error"]["code"] == "invalid_repository_path"
  end

  test "rejects sensitive credential paths before they reach Forge.Browse", %{
    context: context,
    repository_path: repository_path,
    snapshot: snapshot
  } do
    for path <- [".env", "config/credentials.json", "keys/deploy.pem"] do
      assert {:ok, outcome} =
               run(snapshot, context, "read_repository_file", %{
                 "repository" => repository_path,
                 "path" => path,
                 "ref" => "main"
               })

      assert outcome["status"] == "failed"
      assert outcome["error"]["code"] == "sensitive_repository_path"
    end
  end

  test "does not disclose a private repository without visible access", %{
    context: context,
    snapshot: snapshot
  } do
    {:ok, private_repository} =
      Repositories.create_repository(%{
        owner: "RegistryPrivateOrg",
        name: "private-repo",
        visibility: "private",
        default_branch: "main"
      })

    seed_repository(private_repository.storage_key)

    assert {:ok, outcome} =
             run(snapshot, context, "read_repository_file", %{
               "repository" => "RegistryPrivateOrg/private-repo",
               "path" => "README.md",
               "ref" => "main"
             })

    assert outcome["status"] == "failed"
    assert outcome["error"]["code"] == "repository_not_found"
    assert outcome["error"]["message"] == "The repository does not exist or you cannot access it."
  end

  test "reads a private repository that is visible through membership", %{
    context: context,
    snapshot: snapshot,
    user: user
  } do
    {:ok, private_repository} =
      Repositories.create_repository(%{
        owner: "RegistryMemberOrg",
        name: "member-repo",
        visibility: "private",
        default_branch: "main"
      })

    seed_repository(private_repository.storage_key)
    assert {:ok, _membership} = Repositories.add_member(private_repository, user, "viewer")

    assert {:ok, outcome} =
             run(snapshot, context, "read_repository_file", %{
               "repository" => "RegistryMemberOrg/member-repo",
               "path" => "README.md",
               "ref" => "main"
             })

    assert outcome["status"] == "succeeded"
    assert outcome["result"]["content"] == "# OpenAgents\n\nConnected repository fixture.\n"
  end

  test "requires repository authority and an authenticated conversation owner", %{
    context: context,
    repository_path: repository_path,
    snapshot: snapshot
  } do
    assert {:ok, refused} =
             run(snapshot, %{context | authorities: MapSet.new()}, "read_repository_file", %{
               "repository" => repository_path,
               "path" => "README.md",
               "ref" => "main"
             })

    assert refused["status"] == "refused"
    assert refused["error"]["code"] == "authority_refused"

    assert {:ok, unauthenticated} =
             run(snapshot, %{context | owner_user_id: nil}, "read_repository_file", %{
               "repository" => repository_path,
               "path" => "README.md",
               "ref" => "main"
             })

    assert unauthenticated["status"] == "failed"
    assert unauthenticated["error"]["code"] == "repository_authentication_required"
  end

  defp context(user_id) do
    %ExecutionContext{
      scope: "browser_conversation",
      scope_ref: "conversation:connected-repository-test",
      authorities: MapSet.new(["repository.read"]),
      owner_user_id: user_id
    }
  end

  defp run(snapshot, context, name, arguments) do
    Runner.run(
      snapshot,
      %{
        call_id: "call:#{System.unique_integer([:positive])}",
        name: name,
        version: 1,
        raw_arguments: Jason.encode!(arguments)
      },
      context
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
    persist_wal(storage_key, path, %{"refs/heads/main" => commit})
  end

  defp persist_wal(storage_key, path, refs) do
    bundle_path =
      Path.join(
        System.tmp_dir!(),
        "connected-repository-bundle-#{System.unique_integer([:positive, :monotonic])}.bundle"
      )

    {_, 0} = Repos.git(path, ["bundle", "create", bundle_path, "--all"])
    index_result = WAL.read_index(storage_key)
    index = if match?({:ok, _, _}, index_result), do: elem(index_result, 2), else: WAL.new_index()
    generation = if match?({:ok, _, _}, index_result), do: elem(index_result, 1), else: :none
    sequence = WAL.next_seq(index)
    {:ok, object} = WAL.put_entry_file(storage_key, sequence, bundle_path)

    entry = %{
      "seq" => sequence,
      "object" => object,
      "format" => "git_bundle",
      "refs" => refs,
      "principal" => "connected-repository-tools-test",
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
      Path.join(
        System.tmp_dir!(),
        "connected-repository-input-#{System.unique_integer([:positive])}"
      )

    File.write!(input_path, input)

    try do
      {output, 0} =
        System.cmd(
          "sh",
          ["-c", ~s(exec git --git-dir "$GIT_DIR" "$@" < "$INPUT_PATH"), "sh"] ++ args,
          env:
            [{"GIT_DIR", git_dir}, {"INPUT_PATH", input_path}] ++ Keyword.get(options, :env, [])
        )

      String.trim(output)
    after
      File.rm(input_path)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)
end
