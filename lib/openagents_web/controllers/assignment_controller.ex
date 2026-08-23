defmodule OpenAgentsWeb.AssignmentController do
  @moduledoc "API endpoints for assigning one forge issue to one Box."

  use OpenAgentsWeb, :controller
  import Ecto.Query

  alias OpenAgents.Forge.{Assignment, Assignments}

  def create(conn, %{"conversation_id" => conversation_id, "box_id" => box_id} = params) do
    principal = conn.assigns[:current_agent] || conn.assigns[:current_user]

    case OpenAgentsWeb.BoxRateLimiter.allow?(principal_id(principal), :run_create) do
      {:error, :rate_limited} ->
        refusal(conn, :too_many_requests, "rate_limited")

      :ok ->
        create_assignment(conn, conversation_id, box_id, params, principal)
    end
  end

  defp create_assignment(conn, conversation_id, box_id, params, principal) do
    attrs =
      params
      |> Map.put("conversation_id", conversation_id)
      |> Map.put("box_id", box_id)
      |> Map.put("requesting_principal", principal)
      |> Map.put("requesting_user", conn.assigns[:current_user])

    case Assignments.create(attrs) do
      {:ok, assignment, _secret} ->
        conn |> put_status(:accepted) |> json(%{"assignment" => projection(assignment)})

      {:error, :agent_box_control_forbidden} ->
        refusal(conn, :forbidden, "agent_box_control_forbidden")

      {:error, :assignment_issue_claimed} ->
        refusal(conn, :conflict, "assignment_issue_claimed")

      {:error, :assignment_box_busy} ->
        refusal(conn, :conflict, "assignment_box_busy")

      {:error, :protected_branch} ->
        refusal(conn, :forbidden, "protected_branch")

      {:error, :conversation_not_found} ->
        refusal(conn, :not_found, "conversation_not_found")

      {:error, :box_not_owned} ->
        refusal(conn, :not_found, "box_not_found")

      {:error, reason} ->
        refusal(conn, :unprocessable_entity, error_code(reason))
    end
  end

  defp principal_id(%{id: id}), do: id
  defp principal_id(_), do: "unknown"

  def show(conn, %{"assignment_id" => id}) do
    case fetch(id, conn) do
      %Assignment{} = assignment -> json(conn, %{"assignment" => projection(assignment)})
      nil -> refusal(conn, :not_found, "assignment_not_found")
    end
  end

  def cancel(conn, %{"assignment_id" => id}) do
    case fetch(id, conn) do
      %Assignment{} = assignment ->
        if assignment.run, do: OpenAgents.BoxRuns.cancel(assignment.run)

        {:ok, assignment} =
          Assignments.finish(assignment, "cancelled", nil, "cancelled_by_request")

        conn |> put_status(:accepted) |> json(%{"assignment" => projection(assignment)})

      nil ->
        refusal(conn, :not_found, "assignment_not_found")
    end
  end

  defp fetch(id, conn) do
    owner =
      case conn.assigns[:current_user] do
        nil -> OpenAgents.Agents.box_control_owner(conn.assigns[:current_agent])
        user -> user
      end

    if owner &&
         OpenAgents.Conversations.get_conversation_for_user(
           owner,
           conn.params["conversation_id"]
         ) do
      case Ecto.UUID.cast(id) do
        {:ok, id} ->
          OpenAgents.Repo.one(
            from assignment in Assignment,
              join: box in OpenAgents.Box.ConversationBox,
              on: box.id == assignment.conversation_box_id,
              where:
                assignment.id == ^id and box.conversation_id == ^conn.params["conversation_id"],
              preload: [conversation_box: box, run: :conversation_box]
          )

        :error ->
          nil
      end
    else
      nil
    end
  end

  defp projection(%Assignment{} = assignment) do
    %{
      "id" => assignment.id,
      "repository_id" => assignment.repository_id,
      "issue_id" => assignment.issue_id,
      "box_id" => assignment_box_id(assignment),
      "branch" => assignment.branch,
      "state" => assignment.state,
      "terminal_branch" => assignment.terminal_branch,
      "terminal_commit" => assignment.terminal_commit,
      "failure_reason" => assignment.failure_reason,
      "deadline_at" => iso(assignment.deadline_at),
      "admitted_at" => iso(assignment.admitted_at),
      "started_at" => iso(assignment.started_at),
      "finished_at" => iso(assignment.finished_at)
    }
  end

  defp assignment_box_id(%Assignment{conversation_box: %{box_id: box_id}}), do: box_id
  defp assignment_box_id(%Assignment{conversation_box_id: id}), do: id

  defp iso(nil), do: nil
  defp iso(value), do: DateTime.to_iso8601(value)
  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_), do: "assignment_refused"

  defp refusal(conn, status, code),
    do: conn |> put_status(status) |> json(%{"error" => %{"code" => code}})
end
