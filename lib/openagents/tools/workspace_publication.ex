defmodule OpenAgents.Tools.WorkspacePublication do
  @moduledoc "Publishes an authenticated chat workspace to its assigned Forge branch."

  import Ecto.Query

  alias OpenAgents.{Accounts, Forge, Repositories}
  alias OpenAgents.Forge.Pushes
  alias OpenAgents.Repositories.{Repository, RepositoryPublication}
  alias OpenAgents.Tools.{ExecutionContext, WorkspaceFiles}

  @branch_prefix "openagents/chat/"
  @identity_name "OpenAgents chat agent"
  @identity_email "chat-agent@openagents.com"

  def publish(%ExecutionContext{} = context, message, expected_digest)
      when is_binary(message) do
    message = String.trim(message)

    with true <- message != "" || {:error, :invalid_publish_message},
         {:ok, binding} <- publication_binding(context),
         {:ok, publication} <-
           find_or_create_publication(context, binding, message, expected_digest) do
      :global.trans({{__MODULE__, publication.idempotency_key}, self()}, fn ->
        publish_once(publication.id, binding, message, expected_digest)
      end)
    end
  end

  def publish(_context, _message, _expected_digest), do: {:error, :invalid_publish_message}

  def branch(%ExecutionContext{} = context) do
    opaque =
      [context.owner_user_id, context.conversation_id, workspace_ref(context)]
      |> Enum.map_join(":", &to_string/1)
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    @branch_prefix <> opaque
  end

  def workspace_digest(%ExecutionContext{} = context) do
    with {:ok, binding} <- publication_binding(context),
         {:ok, source_oid} <- git(binding.root, ["rev-parse", "HEAD"]),
         {:ok, tree_oid} <- staged_tree(binding.root) do
      {:ok, workspace_digest(source_oid, tree_oid)}
    end
  end

  def approval_receipt(scope_ref, receipt_ref)
      when is_binary(scope_ref) and is_binary(receipt_ref) do
    %{
      "schema" => "sarah.module_approval.v1",
      "approval_class" => "explicit_operator_approval",
      "module_id" => "openagents.tool.publish_changes.v1",
      "version" => 1,
      "scope_ref" => scope_ref,
      "explicit" => true,
      "actor_type" => "person",
      "receipt_ref" => receipt_ref
    }
  end

  defp publication_binding(
         %ExecutionContext{workspace: workspace, owner_user_id: user_id} = context
       )
       when is_map(workspace) and is_binary(user_id) do
    repository_id = fetch(workspace, "repository_id", :repository_id)

    with {:ok, target} <- WorkspaceFiles.resolve(context, ".git", :write),
         %Repository{} = repository <- OpenAgents.Repo.get(Repository, repository_id),
         user when not is_nil(user) <- Accounts.get_user(user_id),
         true <- Repositories.writable?(repository, user),
         true <- repository.lifecycle_state == "ready",
         repository <- OpenAgents.Repo.preload(repository, :namespace),
         push_url when is_binary(push_url) and push_url != "" <- push_url(repository),
         assigned_branch = branch(context),
         false <- assigned_branch == repository.default_branch do
      {:ok,
       %{
         root: target.root,
         repository: repository,
         branch: assigned_branch,
         push_url: push_url
       }}
    else
      nil -> {:error, :repository_not_found}
      false -> {:error, :repository_write_refused}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :forge_push_unconfigured}
    end
  end

  defp publication_binding(_context), do: {:error, :repository_workspace_unavailable}

  defp push_url(repository) do
    case Application.get_env(:openagents, :workspace_publish_url_resolver) do
      resolver when is_function(resolver, 1) -> resolver.(repository)
      _ -> OpenAgents.Tools.Repository.push_url()
    end
  end

  defp staged_tree(root) do
    index = Path.join(System.tmp_dir!(), "openagents-publish-#{Ecto.UUID.generate()}.index")

    try do
      with {:ok, _} <- git(root, ["read-tree", "HEAD"], index),
           {:ok, _} <- git(root, ["add", "-A"], index),
           {:ok, tree} <- git(root, ["write-tree"], index) do
        {:ok, tree}
      end
    after
      File.rm(index)
    end
  end

  defp commit_tree(root, tree_oid, source_oid, message) do
    with {:ok, date} <- git(root, ["show", "-s", "--format=%aI", source_oid]),
         {:ok, commit_oid} <-
           git(root, ["commit-tree", tree_oid, "-p", source_oid, "-m", message], nil,
             GIT_AUTHOR_NAME: @identity_name,
             GIT_AUTHOR_EMAIL: @identity_email,
             GIT_COMMITTER_NAME: @identity_name,
             GIT_COMMITTER_EMAIL: @identity_email,
             GIT_AUTHOR_DATE: date,
             GIT_COMMITTER_DATE: date
           ) do
      {:ok, commit_oid}
    end
  end

  defp publish_ref(binding, commit_oid, expected_previous_oid) do
    with {:ok, remote_oid} <- remote_oid(binding.push_url, binding.branch) do
      publish_ref_from_remote(binding, commit_oid, expected_previous_oid, remote_oid)
    end
  end

  defp publish_ref_from_remote(_binding, commit_oid, _expected, commit_oid),
    do: {:ok, "reconciled"}

  defp publish_ref_from_remote(_binding, _commit_oid, expected, remote_oid)
       when expected != remote_oid,
       do: {:error, :publish_lease_failed}

  defp publish_ref_from_remote(binding, commit_oid, expected_previous_oid, _remote_oid) do
    lease =
      "--force-with-lease=refs/heads/#{binding.branch}:#{expected_previous_oid || String.duplicate("0", 40)}"

    case git(binding.root, [
           "-c",
           "credential.helper=",
           "push",
           lease,
           binding.push_url,
           "#{commit_oid}:refs/heads/#{binding.branch}"
         ]) do
      {:ok, _output} ->
        {:ok, "published"}

      {:error, _reason} ->
        case remote_oid(binding.push_url, binding.branch) do
          {:ok, ^commit_oid} -> {:ok, "reconciled"}
          {:ok, _other} -> {:error, :publish_lease_failed}
          {:error, _reason} -> {:error, :publish_result_uncertain}
        end
    end
  end

  defp remote_oid(url, branch) do
    case System.cmd("git", ["ls-remote", url, "refs/heads/#{branch}"],
           stderr_to_stdout: true,
           env: [{"GIT_TERMINAL_PROMPT", "0"}]
         ) do
      {"", 0} -> {:ok, nil}
      {output, 0} -> {:ok, output |> String.split() |> List.first()}
      {_output, _status} -> {:error, :forge_remote_unavailable}
    end
  end

  defp receipt(binding, commit_oid) do
    resolver =
      Application.get_env(:openagents, :workspace_publish_receipt_resolver, &forge_receipt/3)

    case resolver.(binding.repository, binding.branch, commit_oid) do
      {:ok, receipt} when is_map(receipt) -> {:ok, receipt}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :forge_wal_receipt_missing}
    end
  end

  defp forge_receipt(repository, branch, commit_oid) do
    _inserted = Pushes.reconcile_receipts(repository.storage_key)
    ref = "refs/heads/#{branch}"

    repository.storage_key
    |> Forge.recent_pushes(50)
    |> Enum.find(fn receipt -> get_in(receipt.refs, [ref, "new"]) == commit_oid end)
    |> case do
      nil ->
        {:error, :forge_wal_receipt_missing}

      receipt ->
        {:ok,
         %{
           "schema" => "openagents.forge_push_receipt.v1",
           "id" => receipt.id,
           "wal_seq" => receipt.wal_seq,
           "ref" => ref
         }}
    end
  end

  defp check_digest(nil, _actual), do: :ok
  defp check_digest(actual, actual), do: :ok
  defp check_digest(_expected, _actual), do: {:error, :stale_workspace_digest}

  defp changed(tree, tree), do: {:error, :nothing_to_publish}
  defp changed(_source_tree, _tree), do: :ok

  defp find_or_create_publication(context, binding, message, expected_digest) do
    argument_digest = digest(Jason.encode!(%{message: message, expected_digest: expected_digest}))
    idempotency_key = idempotency_key(context, argument_digest)

    attrs = %{
      repository_id: binding.repository.id,
      owner_user_id: context.owner_user_id,
      conversation_id: context.conversation_id,
      tool_call_id: context.current_tool_call_id,
      workspace_ref: workspace_ref(context),
      idempotency_key: idempotency_key,
      argument_digest: argument_digest,
      message: message,
      expected_workspace_digest: expected_digest,
      branch: binding.branch,
      expected_previous_oid: latest_published_oid(binding.repository.id, binding.branch)
    }

    case OpenAgents.Repo.get_by(RepositoryPublication, idempotency_key: idempotency_key) do
      %RepositoryPublication{argument_digest: ^argument_digest} = publication ->
        {:ok, publication}

      %RepositoryPublication{} ->
        {:error, :publication_idempotency_conflict}

      nil ->
        %RepositoryPublication{}
        |> RepositoryPublication.changeset(attrs)
        |> OpenAgents.Repo.insert()
        |> case do
          {:ok, publication} -> {:ok, publication}
          {:error, _changeset} -> refetch_publication(idempotency_key, argument_digest)
        end
    end
  end

  defp refetch_publication(idempotency_key, argument_digest) do
    case OpenAgents.Repo.get_by(RepositoryPublication, idempotency_key: idempotency_key) do
      %RepositoryPublication{argument_digest: ^argument_digest} = publication ->
        {:ok, publication}

      %RepositoryPublication{} ->
        {:error, :publication_idempotency_conflict}

      nil ->
        {:error, :publication_receipt_unavailable}
    end
  end

  defp publish_once(publication_id, binding, message, expected_digest) do
    publication = OpenAgents.Repo.get!(RepositoryPublication, publication_id)

    if publication.state == "accepted" and is_map(publication.result) do
      {:ok, publication.result}
    else
      result =
        with {:ok, source_oid} <- git(binding.root, ["rev-parse", "HEAD"]),
             {:ok, tree_oid} <- staged_tree(binding.root),
             {:ok, source_tree} <- git(binding.root, ["rev-parse", "HEAD^{tree}"]),
             observed_digest = workspace_digest(source_oid, tree_oid),
             :ok <-
               update_publication(publication, %{
                 state: "committing",
                 source_oid: source_oid,
                 observed_workspace_digest: observed_digest
               }),
             :ok <- check_digest(expected_digest, observed_digest),
             :ok <- changed(source_tree, tree_oid),
             {:ok, commit_oid} <- commit_tree(binding.root, tree_oid, source_oid, message),
             :ok <-
               update_publication(publication, %{state: "pushing", published_oid: commit_oid}),
             {:ok, disposition} <-
               publish_ref(binding, commit_oid, publication.expected_previous_oid),
             {:ok, receipt} <- receipt(binding, commit_oid) do
          publication_result = %{
            "schema" => "openagents.workspace_publication.v1",
            "publication_id" => publication.id,
            "repository" => "#{binding.repository.namespace.slug}/#{binding.repository.name}",
            "branch" => binding.branch,
            "base_branch" => binding.repository.default_branch,
            "source_oid" => source_oid,
            "published_oid" => commit_oid,
            "workspace_digest" => observed_digest,
            "disposition" => disposition,
            "compare_url" => compare_url(binding.repository, binding.branch),
            "summary" => diff_summary(binding.root, source_oid, commit_oid),
            "receipt" => receipt
          }

          :ok =
            update_publication(publication, %{
              state: "accepted",
              published_oid: commit_oid,
              wal_seq: receipt["wal_seq"],
              result: publication_result,
              error_code: nil
            })

          {:ok, publication_result}
        end

      record_publication_result(publication, result)
    end
  end

  defp record_publication_result(_publication, {:ok, _result} = success), do: success

  defp record_publication_result(publication, {:error, reason} = error) do
    state = if(reason == :publish_result_uncertain, do: "uncertain", else: failure_state(reason))
    :ok = update_publication(publication, %{state: state, error_code: error_code(reason)})
    error
  end

  defp failure_state(:nothing_to_publish), do: "nothing_to_publish"
  defp failure_state(_reason), do: "failed"

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "publication_failed"

  defp update_publication(publication, attrs) do
    publication
    |> RepositoryPublication.changeset(attrs)
    |> OpenAgents.Repo.update()
    |> case do
      {:ok, _publication} -> :ok
      {:error, _changeset} -> {:error, :publication_receipt_unavailable}
    end
  end

  defp latest_published_oid(repository_id, branch) do
    from(publication in RepositoryPublication,
      where:
        publication.repository_id == ^repository_id and publication.branch == ^branch and
          publication.state == "accepted",
      order_by: [desc: publication.inserted_at],
      limit: 1,
      select: publication.published_oid
    )
    |> OpenAgents.Repo.one()
  end

  defp idempotency_key(%ExecutionContext{current_tool_call_id: call_id} = context, _digest)
       when is_binary(call_id) and call_id != "" do
    digest(Enum.join([context.owner_user_id, context.conversation_id, call_id], ":"))
  end

  defp idempotency_key(context, argument_digest) do
    digest(
      Enum.join(
        [context.owner_user_id, context.conversation_id, workspace_ref(context), argument_digest],
        ":"
      )
    )
  end

  defp digest(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp workspace_digest(source_oid, tree_oid),
    do: :crypto.hash(:sha256, source_oid <> ":" <> tree_oid) |> Base.encode16(case: :lower)

  defp diff_summary(root, source_oid, commit_oid) do
    case git(root, ["diff-tree", "--no-commit-id", "--numstat", "-r", source_oid, commit_oid]) do
      {:ok, output} ->
        files = String.split(output, "\n", trim: true)

        %{insertions: insertions, deletions: deletions} =
          Enum.reduce(files, %{insertions: 0, deletions: 0}, fn line, acc ->
            case String.split(line, "\t", parts: 3) do
              [added, removed, _path] ->
                %{
                  insertions: acc.insertions + number(added),
                  deletions: acc.deletions + number(removed)
                }

              _ ->
                acc
            end
          end)

        %{
          "files_changed" => length(files),
          "insertions" => insertions,
          "deletions" => deletions
        }

      {:error, _reason} ->
        %{"files_changed" => 0, "insertions" => 0, "deletions" => 0}
    end
  end

  defp number("-"), do: 0
  defp number(value), do: String.to_integer(value)

  defp compare_url(repository, branch) do
    OpenAgentsWeb.Endpoint.url() <>
      "/#{repository.namespace.slug}/#{repository.name}/compare/#{repository.default_branch}...#{branch}"
  end

  defp git(root, args, index \\ nil, extra_env \\ []) do
    env =
      [{"GIT_TERMINAL_PROMPT", "0"}] ++
        if(index, do: [{"GIT_INDEX_FILE", index}], else: []) ++
        Enum.map(extra_env, fn {key, value} -> {Atom.to_string(key), value} end)

    case System.cmd("git", ["-C", root | args], stderr_to_stdout: true, env: env) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _status} -> {:error, {:git_failed, String.slice(output, 0, 500)}}
    end
  end

  defp workspace_ref(%ExecutionContext{workspace: workspace}) when is_map(workspace),
    do: fetch(workspace, "workspace_ref", :workspace_ref) || "workspace:unknown"

  defp workspace_ref(_context), do: "workspace:missing"

  defp fetch(map, string_key, atom_key), do: Map.get(map, string_key, Map.get(map, atom_key))
end
