defmodule OpenAgents.PullRequests do
  @moduledoc "Repository-scoped pull requests backed by issues."
  import Ecto.Query, warn: false

  alias OpenAgents.Accounts.User
  alias OpenAgents.Forge.Browse
  alias OpenAgents.Issues
  alias OpenAgents.PullRequests.PullRequest
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Repository

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
           {:ok, pr} <- insert(target, source, issue, head_ref, head_sha, base_ref, base_sha) do
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
               pr |> PullRequest.changeset(%{state: issue.state}) |> Repo.update() do
          %{updated | issue: issue}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      {:error, :forbidden}
    end
  end

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

  defp insert(target, source, issue, head_ref, head_sha, base_ref, base_sha) do
    %PullRequest{}
    |> PullRequest.changeset(%{
      repository_id: target.id,
      issue_id: issue.id,
      head_repository_id: source.id,
      head_ref: head_ref,
      head_sha: head_sha,
      base_ref: base_ref,
      base_sha: base_sha
    })
    |> Repo.insert()
  end
end
