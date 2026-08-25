defmodule OpenAgentsWeb.FleetTargetController do
  @moduledoc """
  The operator-only fleet promotion API.

  This is not the tenant deployment control plane. `OpenAgents.Deployments`
  lets a repository deploy its own code under `deployments:write`; this
  promotes the OpenAgents release itself, and only a current operator holding
  `deployments:promote` reaches it. Neither scope substitutes for the other,
  and `forge:write` reaches neither.

  Every decision belongs to `OpenAgents.Forge.Promotion`, the same context the
  `/admin/forge` **Promote** button calls, so this controller only reads the
  request, names the source channel, and shapes the answer. Creating a
  promotion states an intent and returns `202 Accepted`: the builder,
  classifier, direct-load, relup, and rolling-replacement lanes still own
  execution, and the caller polls the target to a terminal state.

  Refusals use `OpenAgentsWeb.ApiError`, the one `/api/v1` envelope, so release
  tooling reads one shape and branches on one stable code.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.Forge.{Promotion, Repos, Target, Targets}
  alias OpenAgentsWeb.ApiError

  @maximum_limit 50

  def create(conn, params) do
    attrs =
      params
      |> Map.take(["repo", "sha", "environment", "idempotency_key", "expected_current_target_id"])
      |> Map.put("source", "api")
      |> Map.put("request_id", request_id(conn))

    case Promotion.promote(conn.assigns.current_user, attrs) do
      {:ok, %{target: target, replayed: replayed?}} ->
        conn
        |> put_status(if(replayed?, do: :ok, else: :accepted))
        |> json(created(conn, target, replayed?))

      {:error, reason} ->
        failure(conn, reason)
    end
  end

  def show(conn, %{"id" => id}) do
    case fetch(id) do
      {:ok, target} -> json(conn, projection(conn, target))
      {:error, reason} -> failure(conn, reason)
    end
  end

  def index(conn, params) do
    repo = repository(params)

    json(conn, %{
      "repo" => repo,
      "targets" => repo |> Targets.recent(limit(params)) |> Enum.map(&projection(conn, &1))
    })
  end

  defp created(conn, target, replayed?) do
    conn
    |> projection(target)
    |> Map.put("replayed", replayed?)
    |> Map.put("request_id", request_id(conn))
  end

  # Bounded on purpose. A status response tells automation which terminal
  # state a promotion reached; it never names a node, a filesystem path, a
  # credential, or an unrestricted failure detail.
  defp projection(conn, %Target{} = target) do
    details = target.details || %{}

    %{
      "id" => target.id,
      "repo" => target.repo,
      "sha" => target.sha,
      "status" => target.status,
      "terminal" => target.status in ~w(live failed reverted),
      "promoted_by" => target.promoted_by,
      "environment" => Map.get(details, "promotion_environment", "production"),
      "source" => Map.get(details, "promotion_source", "operator_console"),
      "artifact_digest" => Map.get(details, "artifact_digest"),
      "deployment_lane" => Map.get(details, "deployment_lane"),
      "error_code" => error_code(details),
      "promoted_at" => target.inserted_at,
      "updated_at" => target.updated_at,
      "status_url" => status_url(conn, target)
    }
  end

  defp error_code(details) do
    Enum.find_value(["error_code", "relup_error_code", "rolling_error_code"], fn key ->
      case Map.get(details, key) do
        code when is_binary(code) -> code
        _absent -> nil
      end
    end)
  end

  defp status_url(conn, %Target{id: id}) do
    url(conn, ~p"/api/v1/admin/forge/targets/#{id}")
  end

  defp fetch(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case OpenAgents.Repo.get(Target, uuid) do
          %Target{} = target -> {:ok, target}
          nil -> {:error, :target_not_found}
        end

      :error ->
        {:error, :target_not_found}
    end
  end

  defp repository(params) do
    case params["repo"] do
      repo when is_binary(repo) and repo != "" -> repo
      _absent -> Repos.allowed_repos() |> List.first() || "openagents.com"
    end
  end

  defp limit(params) do
    case Integer.parse(to_string(params["limit"] || "")) do
      {limit, ""} when limit in 1..@maximum_limit -> limit
      _absent_or_invalid -> 10
    end
  end

  defp request_id(conn) do
    conn |> get_resp_header("x-request-id") |> List.first()
  end

  # Codes come from `OpenAgentsWeb.ApiError`'s one table, so this surface cannot
  # disagree with the rest of `/api/v1` about what a refusal is worth.
  defp failure(conn, :not_operator), do: ApiError.refuse(conn, "not_operator")

  defp failure(conn, :target_not_found), do: ApiError.not_found(conn)

  defp failure(conn, :idempotency_conflict),
    do: ApiError.refuse(conn, "idempotency_conflict")

  defp failure(conn, :precondition_failed),
    do: ApiError.refuse(conn, "precondition_failed")

  defp failure(conn, :unknown_sha), do: ApiError.refuse(conn, "unknown_commit")

  defp failure(conn, :invalid_sha),
    do: invalid(conn, "sha", "must be one full 40-character commit SHA")

  defp failure(conn, :invalid_repository),
    do: invalid(conn, "repo", "must name a repository")

  defp failure(conn, :repository_not_deployable),
    do: invalid(conn, "repo", "has no fleet to promote to")

  defp failure(conn, :unsupported_environment),
    do: invalid(conn, "environment", "must be production")

  defp failure(conn, :invalid_idempotency_key),
    do:
      invalid(
        conn,
        "idempotency_key",
        "must be 8 to 255 characters, generated by the caller"
      )

  defp failure(conn, :invalid_expected_target),
    do: invalid(conn, "expected_current_target_id", "must be a target ID")

  defp failure(conn, :invalid_source), do: invalid(conn, "source", "is not a promotion source")

  defp failure(conn, {:invalid, %Ecto.Changeset{} = changeset}),
    do: ApiError.changeset(conn, changeset)

  defp failure(conn, _reason), do: invalid(conn, "request", "could not be admitted")

  defp invalid(conn, field, message), do: ApiError.validation_failed(conn, %{field => [message]})
end
