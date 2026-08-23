defmodule OpenAgents.PullRequests do
  @moduledoc "Repository-scoped pull requests backed by issues."
  import Ecto.Query, warn: false

  alias OpenAgents.Accounts.User
  alias OpenAgents.Forge.Browse
  alias OpenAgents.Forge.WAL
  alias OpenAgents.Issues
  alias OpenAgents.PullRequests.PullRequest
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Repository
  alias OpenAgents.Repositories.RepositoryPublication

  def list(%Repository{id: id}) do
    Repo.all(
      from pr in PullRequest,
        where: pr.repository_id == ^id,
        preload: [:issue, :head_repository],
        order_by: [desc: pr.inserted_at]
    )
  end

  def get_by_number!(%Repository{id: id}, number) do
    Repo.one!(
      from pr in PullRequest,
        join: issue in assoc(pr, :issue),
        where: pr.repository_id == ^id and issue.number == ^number,
        preload: [:issue, :head_repository]
    )
  end

  def create(%Repository{pull_requests_enabled: false}, _attrs, _actor),
    do: {:error, :pull_requests_disabled}

  def create(%Repository{} = target, attrs, %User{} = actor) do
    Repo.transaction(fn ->
      with true <- Repositories.issue_participant?(target, actor),
           {:ok, source} <- source_repository(attrs, actor),
           {:ok, head_ref} <- required(attrs, "head"),
           {:ok, base_ref} <- optional(attrs, "base", target.default_branch),
           {:ok, head_sha} <- resolve(source, head_ref),
           {:ok, base_sha} <- resolve(target, base_ref),
           {:ok, issue} <- Issues.create_issue(target, attrs, actor),
           {:ok, pr} <-
             insert(target, source, issue, head_ref, head_sha, base_ref, base_sha, attrs) do
        Repo.preload(pr, [:issue, :head_repository])
      else
        false -> Repo.rollback(:forbidden)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def update(%PullRequest{} = pr, attrs, %User{} = actor) do
    pr = Repo.preload(pr, [:issue, :repository])
    role = Repositories.membership_role(pr.repository, actor)

    if pr.issue.author_user_id == actor.id or role in ~w(owner maintainer) do
      Repo.transaction(fn ->
        with {:ok, issue} <-
               Issues.update_issue(
                 pr.issue,
                 Map.take(attrs, ["title", "body", "state"]),
                 actor
               ),
             {:ok, updated} <-
               pr
               |> PullRequest.changeset(pull_request_update_attrs(attrs, issue.state))
               |> Repo.update() do
          %{updated | issue: issue}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      {:error, :forbidden}
    end
  end

  @doc "Opens or refreshes the draft pull request for an accepted Forge publication."
  def open_from_publication(%RepositoryPublication{} = publication, attrs, %User{} = actor) do
    publication = Repo.preload(publication, :repository)
    repository = publication.repository

    with :ok <- validate_publication(publication, actor),
         :ok <- validate_pull_request_policy(repository, actor),
         {:ok, head_sha, base_sha} <- validate_wal_authority(publication) do
      Repo.transaction(fn ->
        lock_open_head(repository.id, publication.branch, repository.default_branch)

        case open_for_head(repository.id, publication.branch, repository.default_branch) do
          nil ->
            create_from_publication(publication, attrs, actor, head_sha, base_sha)

          %PullRequest{repository_publication_id: id} = pull_request
          when id == publication.id ->
            Repo.preload(pull_request, [:issue, :head_repository, :repository_publication])

          %PullRequest{} = pull_request ->
            refresh_from_publication(pull_request, publication, attrs, actor, head_sha, base_sha)
        end
      end)
    end
  end

  defp validate_publication(%RepositoryPublication{} = publication, %User{} = actor) do
    cond do
      publication.owner_user_id != actor.id ->
        {:error, :publication_scope_mismatch}

      publication.state != "accepted" ->
        {:error, :publication_not_accepted}

      not is_binary(publication.published_oid) ->
        {:error, :publication_not_accepted}

      not is_integer(publication.wal_seq) or publication.wal_seq < 0 ->
        {:error, :publication_receipt_invalid}

      publication.branch == publication.repository.default_branch ->
        {:error, :publication_branch_refused}

      not String.starts_with?(publication.branch || "", "openagents/chat/") ->
        {:error, :publication_branch_refused}

      true ->
        :ok
    end
  end

  defp validate_pull_request_policy(%Repository{pull_requests_enabled: false}, _actor),
    do: {:error, :pull_requests_disabled}

  defp validate_pull_request_policy(repository, actor) do
    if Repositories.writable?(repository, actor), do: :ok, else: {:error, :forbidden}
  end

  defp validate_wal_authority(publication) do
    repository = publication.repository
    published_oid = publication.published_oid
    head_ref = "refs/heads/#{publication.branch}"
    base_ref = "refs/heads/#{repository.default_branch}"

    with {:ok, _generation, index} <- WAL.read_index(repository.storage_key),
         ^published_oid <- WAL.refs(index)[head_ref],
         base_sha when is_binary(base_sha) <- WAL.refs(index)[base_ref],
         %{"refs" => receipt_refs} <- Enum.at(WAL.entries(index), publication.wal_seq),
         ^published_oid <- receipt_refs[head_ref] do
      {:ok, published_oid, base_sha}
    else
      {:error, _reason} -> {:error, :forge_authority_unavailable}
      _ -> {:error, :publication_receipt_stale}
    end
  end

  defp open_for_head(repository_id, head_ref, base_ref) do
    Repo.one(
      from pr in PullRequest,
        where:
          pr.repository_id == ^repository_id and pr.head_repository_id == ^repository_id and
            pr.head_ref == ^head_ref and pr.base_ref == ^base_ref and pr.state == "open",
        lock: "FOR UPDATE"
    )
  end

  defp lock_open_head(repository_id, head_ref, base_ref) do
    key = Enum.join([repository_id, head_ref, base_ref], ":")
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key])
    :ok
  end

  defp create_from_publication(publication, attrs, actor, head_sha, base_sha) do
    repository = publication.repository

    with {:ok, issue} <- Issues.create_issue(repository, issue_attrs(attrs), actor),
         {:ok, pull_request} <-
           %PullRequest{}
           |> PullRequest.changeset(%{
             repository_id: repository.id,
             issue_id: issue.id,
             head_repository_id: repository.id,
             repository_publication_id: publication.id,
             opened_by_user_id: actor.id,
             conversation_id: publication.conversation_id,
             head_ref: publication.branch,
             head_sha: head_sha,
             base_ref: repository.default_branch,
             base_sha: base_sha,
             draft: Map.get(attrs, "draft", true)
           })
           |> Repo.insert() do
      Repo.preload(pull_request, [:issue, :head_repository, :repository_publication])
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp refresh_from_publication(pull_request, publication, attrs, actor, head_sha, base_sha) do
    pull_request = Repo.preload(pull_request, [:issue, :repository_publication])

    with :ok <- validate_existing_publication_scope(pull_request, publication, actor),
         {:ok, issue} <- Issues.update_issue(pull_request.issue, issue_attrs(attrs), actor),
         {:ok, updated} <-
           pull_request
           |> PullRequest.changeset(%{
             repository_publication_id: publication.id,
             head_sha: head_sha,
             base_sha: base_sha,
             draft: Map.get(attrs, "draft", true),
             conversation_id: publication.conversation_id
           })
           |> Repo.update() do
      %{Repo.preload(updated, [:head_repository, :repository_publication]) | issue: issue}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp validate_existing_publication_scope(pull_request, publication, actor) do
    previous_publication = pull_request.repository_publication

    cond do
      pull_request.opened_by_user_id != actor.id ->
        {:error, :publication_scope_mismatch}

      pull_request.conversation_id != publication.conversation_id ->
        {:error, :publication_scope_mismatch}

      is_nil(previous_publication) or
          previous_publication.workspace_ref != publication.workspace_ref ->
        {:error, :publication_workspace_mismatch}

      true ->
        :ok
    end
  end

  defp issue_attrs(attrs), do: Map.take(attrs, ["title", "body"])

  defp pull_request_update_attrs(attrs, state) do
    %{state: state}
    |> maybe_put(:draft, Map.fetch(attrs, "draft"))
  end

  defp maybe_put(attrs, _key, :error), do: attrs
  defp maybe_put(attrs, key, {:ok, value}), do: Map.put(attrs, key, value)

  defp source_repository(attrs, actor) do
    case Map.get(attrs, "head_repository") do
      value when is_binary(value) ->
        case String.split(value, "/", parts: 2) do
          [owner, name] -> {:ok, Repositories.get_writable_by_path!(owner, name, actor)}
          _ -> {:error, :invalid_head_repository}
        end

      _ ->
        {:error, :invalid_head_repository}
    end
  rescue
    Ecto.NoResultsError -> {:error, :invalid_head_repository}
  end

  defp resolve(repository, ref) do
    case Browse.resolve_commit(repository, ref) do
      {:ok, sha} -> {:ok, sha}
      _ -> {:error, :invalid_ref}
    end
  end

  defp required(attrs, key), do: optional(attrs, key, nil)

  defp optional(attrs, key, default) do
    case Map.get(attrs, key, default) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_ref}
    end
  end

  defp insert(target, source, issue, head_ref, head_sha, base_ref, base_sha, attrs) do
    %PullRequest{}
    |> PullRequest.changeset(%{
      repository_id: target.id,
      issue_id: issue.id,
      head_repository_id: source.id,
      head_ref: head_ref,
      head_sha: head_sha,
      base_ref: base_ref,
      base_sha: base_sha,
      draft: Map.get(attrs, "draft", true)
    })
    |> Repo.insert()
  end
end
