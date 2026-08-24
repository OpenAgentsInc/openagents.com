defmodule OpenAgentsWeb.IssueCompletionClaimController do
  @moduledoc """
  Submit one completion claim for a finished attempt on an issue.

  The request carries exactly one judgment: which evidence satisfied which
  acceptance criterion. Everything else `OpenAgents.Issues.CompletionClaims`
  grades — the issue's sections, the attempt's five binding fields, the
  verifier, and the falsifier — is read from records, so a caller cannot assert
  its own authority or its own verification.

  Two principals may submit. An agent may submit only for the attempt it
  requested, which is the authority the attempt already recorded. A user may
  submit for any attempt in a repository it can write. A user's claim is
  `not_applicable`: the contract gates agent-authored claims, and a person who
  wants an issue closed closes it.

  The response is the same claim object the issue extension carries, so a
  client that reads `issue.openagents.completion_claims` and a client that
  reads this endpoint agree without translating between two shapes.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.Agents.Agent
  alias OpenAgents.Forge.Assignment
  alias OpenAgents.Issues
  alias OpenAgents.Issues.CompletionClaims
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Repository
  alias OpenAgentsWeb.ApiError
  alias OpenAgentsWeb.ControllerHelpers

  def create(conn, %{"owner" => owner, "repo" => repo, "issue_number" => number} = params) do
    actor = conn.assigns[:current_agent] || conn.assigns[:current_user]

    with {:ok, assignment} <- load_assignment(params["assignment_id"]),
         {:ok, repository} <- load_repository(assignment, owner, repo),
         {:ok, issue} <- load_issue(repository, assignment, number),
         :ok <- authorize(repository, assignment, actor) do
      case CompletionClaims.submit(assignment, author(actor), claim_attrs(params)) do
        {:ok, claim} ->
          conn
          |> put_status(:created)
          |> json(%{
            "claim" => CompletionClaims.summary(claim),
            "issue" => %{
              "number" => issue.number,
              "state" => Issues.get_issue!(repository, issue.id).state
            }
          })

        {:error, reason} ->
          ApiError.refuse(conn, "validation_failed",
            message: "The claim could not be graded: #{reason}"
          )
      end
    else
      {:error, :forbidden} ->
        ApiError.refuse(conn, "forbidden",
          message: "This principal may not claim completion for that attempt"
        )

      {:error, :not_found} ->
        ApiError.not_found(conn, message: "No such attempt on that issue")
    end
  end

  # The attempt is the anchor, because it is what carries the authority, the
  # budget, and the revision. A caller that cannot name one has no claim to
  # make.
  defp load_assignment(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Repo.get(Assignment, uuid) do
          %Assignment{} = assignment -> {:ok, assignment}
          nil -> {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp load_assignment(_id), do: {:error, :not_found}

  # The path must name the attempt's own repository. Resolving the repository
  # from the attempt rather than from the path is what keeps a caller from
  # pointing a real attempt at another repository's issue.
  defp load_repository(%Assignment{repository_id: repository_id}, owner, repo) do
    case Repo.get(Repository, repository_id) do
      %Repository{} = repository ->
        if String.downcase(owner) == repository.owner_key and
             String.downcase(repo) == repository.name_key,
           do: {:ok, repository},
           else: {:error, :not_found}

      nil ->
        {:error, :not_found}
    end
  end

  defp load_issue(repository, %Assignment{issue_id: issue_id}, number) do
    issue = Issues.get_issue_by_number!(repository, ControllerHelpers.integer_param!(number))
    if issue.id == issue_id, do: {:ok, issue}, else: {:error, :not_found}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  # An agent may claim only for the attempt it requested. That is not a
  # courtesy: the attempt's `requesting_principal` is the authority the claim
  # is graded under, so an agent claiming for someone else's attempt would be
  # claiming under an authority it never held.
  defp authorize(_repository, %Assignment{} = assignment, %Agent{id: agent_id}) do
    case assignment.requesting_principal do
      %{"type" => "agent", "id" => ^agent_id} -> :ok
      _other -> {:error, :forbidden}
    end
  end

  defp authorize(repository, %Assignment{}, %OpenAgents.Accounts.User{} = user) do
    if Repositories.writable?(repository, user), do: :ok, else: {:error, :forbidden}
  end

  defp authorize(_repository, _assignment, _actor), do: {:error, :forbidden}

  defp author(%Agent{}), do: :agent
  defp author(_actor), do: :human

  defp claim_attrs(params) do
    %{
      evidence: List.wrap(params["evidence"]),
      false_green_classes: List.wrap(params["false_green_classes"])
    }
  end
end
