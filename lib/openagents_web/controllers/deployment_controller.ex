defmodule OpenAgentsWeb.DeploymentController do
  @moduledoc """
  The versioned deployment control-plane API for one repository.

  Every action derives its authority from `conn.assigns.principal`, which
  `OpenAgentsWeb.Plugs.DeploymentPrincipal` built from the credential alone. The
  body names bytes and intent; it never names who the caller is, which repository
  the credential belongs to, or which environment a workflow grant covers.

  Errors are typed and stable: one `error.code` per refusal reason, so a client
  can tell "you may not do this" from "this is not admitted yet" from "these
  bytes conflict with an earlier request".
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.Deployments
  alias OpenAgents.Deployments.Principal
  alias OpenAgents.Repositories
  alias OpenAgentsWeb.DeploymentJson

  def environments(conn, %{"owner" => owner, "repo" => repo}) do
    with {:ok, repository} <- repository(conn, owner, repo),
         {:ok, environments} <- Deployments.list_environments(repository, principal(conn)) do
      json(conn, %{"environments" => Enum.map(environments, &DeploymentJson.environment/1)})
    else
      {:error, reason} -> failure(conn, reason)
    end
  end

  def put_environment(conn, %{"owner" => owner, "repo" => repo, "name" => name} = params) do
    attrs = params |> environment_attrs() |> Map.put("name", name)

    with {:ok, repository} <- repository(conn, owner, repo),
         {:ok, environment} <- Deployments.put_environment(repository, principal(conn), attrs) do
      json(conn, DeploymentJson.environment(environment))
    else
      {:error, reason} -> failure(conn, reason)
    end
  end

  def protection(conn, %{"owner" => owner, "repo" => repo, "name" => name}) do
    with {:ok, repository} <- repository(conn, owner, repo),
         {:ok, environment} <- Deployments.fetch_environment(repository, principal(conn), name) do
      json(conn, DeploymentJson.protection(environment))
    else
      {:error, reason} -> failure(conn, reason)
    end
  end

  def create(conn, %{"owner" => owner, "repo" => repo} = params) do
    with {:ok, repository} <- repository(conn, owner, repo),
         {:ok, run} <-
           Deployments.request_deployment(repository, principal(conn), request_attrs(params)),
         {:ok, run} <- Deployments.fetch_run(repository, principal(conn), run.id) do
      conn |> put_status(:accepted) |> json(DeploymentJson.run(run))
    else
      {:error, reason} -> failure(conn, reason)
    end
  end

  def index(conn, %{"owner" => owner, "repo" => repo} = params) do
    with {:ok, repository} <- repository(conn, owner, repo),
         {:ok, runs} <- Deployments.list_runs(repository, principal(conn), list_options(params)) do
      json(conn, %{
        "deployments" => Enum.map(runs, &DeploymentJson.run/1),
        "cursor" => List.last(runs) && List.last(runs).id
      })
    else
      {:error, reason} -> failure(conn, reason)
    end
  end

  def show(conn, %{"owner" => owner, "repo" => repo, "id" => id}) do
    with {:ok, repository} <- repository(conn, owner, repo),
         {:ok, run} <- Deployments.fetch_run(repository, principal(conn), id) do
      json(conn, DeploymentJson.run(run))
    else
      {:error, reason} -> failure(conn, reason)
    end
  end

  def cancel(conn, %{"owner" => owner, "repo" => repo, "id" => id} = params) do
    options =
      case params["if_state"] do
        state when is_binary(state) -> [if_state: state]
        _absent -> []
      end

    with {:ok, repository} <- repository(conn, owner, repo),
         {:ok, run} <- Deployments.cancel_run(repository, principal(conn), id, options),
         {:ok, run} <- Deployments.fetch_run(repository, principal(conn), run.id) do
      json(conn, DeploymentJson.run(run))
    else
      {:error, reason} -> failure(conn, reason)
    end
  end

  def decide(conn, %{"owner" => owner, "repo" => repo, "id" => id} = params) do
    case params["decision"] do
      decision when decision in ~w(approved rejected) ->
        record_decision(conn, owner, repo, id, decision, params)

      _invalid ->
        failure(conn, :invalid_decision)
    end
  end

  def approvals(conn, %{"owner" => owner, "repo" => repo, "id" => id}) do
    with {:ok, repository} <- repository(conn, owner, repo),
         {:ok, run} <- Deployments.fetch_run(repository, principal(conn), id),
         {:ok, approvals} <- Deployments.list_approvals(repository, principal(conn), run) do
      json(conn, %{"approvals" => Enum.map(approvals, &DeploymentJson.approval/1)})
    else
      {:error, reason} -> failure(conn, reason)
    end
  end

  def events(conn, %{"owner" => owner, "repo" => repo, "id" => id} = params) do
    options = [
      after_sequence: integer(params["after_sequence"], 0),
      limit: integer(params["limit"], 25)
    ]

    with {:ok, repository} <- repository(conn, owner, repo),
         {:ok, run} <- Deployments.fetch_run(repository, principal(conn), id),
         {:ok, events} <- Deployments.list_events(repository, principal(conn), run, options) do
      json(conn, %{
        "events" => Enum.map(events, &DeploymentJson.event/1),
        "after_sequence" => (List.last(events) && List.last(events).sequence) || 0
      })
    else
      {:error, reason} -> failure(conn, reason)
    end
  end

  def publish_check(conn, %{"owner" => owner, "repo" => repo} = params) do
    with {:ok, repository} <- repository(conn, owner, repo),
         {:ok, result} <-
           Deployments.publish_check_result(repository, principal(conn), check_attrs(params)) do
      conn |> put_status(:created) |> json(DeploymentJson.check_result(result))
    else
      {:error, reason} -> failure(conn, reason)
    end
  end

  def issue_grant(conn, %{"owner" => owner, "repo" => repo} = params) do
    with {:ok, repository} <- repository(conn, owner, repo),
         {:ok, {grant, plaintext}} <-
           Deployments.issue_workflow_grant(repository, principal(conn), grant_attrs(params)) do
      conn
      |> put_status(:created)
      |> json(DeploymentJson.workflow_grant(grant, plaintext))
    else
      {:error, reason} -> failure(conn, reason)
    end
  end

  def revoke_grant(conn, %{"owner" => owner, "repo" => repo, "id" => id}) do
    with {:ok, repository} <- repository(conn, owner, repo),
         {:ok, grant} <- Deployments.revoke_workflow_grant(repository, principal(conn), id) do
      json(conn, %{"id" => grant.id, "revoked_at" => grant.revoked_at})
    else
      {:error, reason} -> failure(conn, reason)
    end
  end

  defp record_decision(conn, owner, repo, id, decision, params) do
    attrs = Map.take(params, ["comment"])

    with {:ok, repository} <- repository(conn, owner, repo),
         {:ok, run} <- Deployments.decide_run(repository, principal(conn), id, decision, attrs),
         {:ok, run} <- Deployments.fetch_run(repository, principal(conn), run.id) do
      json(conn, DeploymentJson.run(run))
    else
      {:error, reason} -> failure(conn, reason)
    end
  end

  defp principal(conn), do: conn.assigns.principal

  # A workflow grant is bound to a repository id, and `Authority` compares it, so
  # the lookup here only resolves the path. A human principal resolves it through
  # repository visibility, which is what stops a private repository from being
  # discovered by name.
  defp repository(conn, owner, repo) do
    case principal(conn) do
      %Principal{kind: :user, user: user} ->
        {:ok, Repositories.get_visible_by_path!(owner, repo, user)}

      %Principal{} ->
        {:ok, Repositories.get_by_path!(owner, repo)}
    end
  rescue
    Ecto.NoResultsError -> {:error, :repository_not_found}
  end

  defp environment_attrs(params) do
    Map.take(params, [
      "kind",
      "provider",
      "provider_config",
      "secret_references",
      "retention_days",
      "protection"
    ])
  end

  defp request_attrs(params) do
    Map.take(params, [
      "environment",
      "commit_sha",
      "artifact_digest",
      "artifact_created_at",
      "source_ref",
      "source_workflow",
      "workflow_run_id",
      "idempotency_key"
    ])
  end

  defp check_attrs(params) do
    Map.take(params, [
      "name",
      "commit_sha",
      "artifact_digest",
      "status",
      "evidence_url",
      "evidence_digest",
      "valid_until",
      "source_ref",
      "source_workflow",
      "workflow_run_id"
    ])
  end

  defp grant_attrs(params) do
    Map.take(params, [
      "environment",
      "audience",
      "scopes",
      "source_ref",
      "source_workflow",
      "workflow_run_id",
      "lifetime_seconds"
    ])
  end

  defp list_options(params) do
    [
      limit: integer(params["limit"], 25),
      cursor: params["cursor"],
      state: params["state"]
    ]
  end

  defp integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _malformed -> default
    end
  end

  defp integer(value, _default) when is_integer(value), do: value
  defp integer(_value, default), do: default

  defp failure(conn, {:forbidden, reason}),
    do: error(conn, :forbidden, "forbidden", Atom.to_string(reason))

  defp failure(conn, :repository_not_found),
    do: error(conn, :not_found, "not_found", "repository")

  defp failure(conn, :environment_not_found),
    do: error(conn, :not_found, "not_found", "environment")

  defp failure(conn, :run_not_found), do: error(conn, :not_found, "not_found", "deployment")
  defp failure(conn, :request_not_found), do: error(conn, :not_found, "not_found", "request")

  defp failure(conn, :idempotency_conflict),
    do: error(conn, :conflict, "idempotency_conflict", "same key, different bytes")

  defp failure(conn, :precondition_failed),
    do: error(conn, :conflict, "precondition_failed", "the run is no longer in that state")

  defp failure(conn, {:illegal_transition, from, to}),
    do: error(conn, :conflict, "illegal_transition", from <> " cannot become " <> to)

  defp failure(conn, {:policy_denied, reason}),
    do: error(conn, :unprocessable_entity, "policy_denied", reason)

  defp failure(conn, :unknown_provider),
    do: error(conn, :unprocessable_entity, "unknown_provider", "provider is not configured")

  defp failure(conn, :unknown_commit),
    do: error(conn, :unprocessable_entity, "unknown_commit", "the repository has no such commit")

  defp failure(conn, :invalid_decision),
    do: error(conn, :unprocessable_entity, "invalid_decision", "approved or rejected")

  defp failure(conn, :invalid_grant),
    do: error(conn, :unprocessable_entity, "invalid_grant", "the grant is expired or revoked")

  defp failure(conn, %Ecto.Changeset{} = changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      "error" => %{
        "code" => "invalid_request",
        "message" => "The request is not valid.",
        "detail" => changeset_errors(changeset)
      }
    })
  end

  defp failure(conn, reason) when is_atom(reason),
    do: error(conn, :unprocessable_entity, Atom.to_string(reason), nil)

  defp error(conn, status, code, detail) do
    body = %{"code" => code, "message" => message(code)}

    conn
    |> put_status(status)
    |> json(%{"error" => if(detail, do: Map.put(body, "detail", detail), else: body)})
  end

  defp message("forbidden"), do: "The credential does not carry that authority."
  defp message("not_found"), do: "Not Found"
  defp message("idempotency_conflict"), do: "That idempotency key already names different bytes."
  defp message("precondition_failed"), do: "The run changed state before this request."
  defp message("illegal_transition"), do: "That transition is not part of the lifecycle."
  defp message("policy_denied"), do: "Environment policy does not admit this deployment."
  defp message(code), do: "The request is not valid: " <> code

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
      Enum.reduce(options, message, fn {key, value}, accumulator ->
        String.replace(accumulator, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
