defmodule OpenAgentsWeb.DelegationsController do
  @moduledoc "Unified API for delegating work to Boxes and connected Computers."

  use OpenAgentsWeb, :controller

  alias OpenAgents.Delegations

  def targets(conn, %{"conversation_id" => conversation_id}) do
    case Delegations.inventory(caller(conn), conversation_id) do
      {:ok, projection} -> json(conn, projection)
      {:error, _reason} -> refusal(conn, :not_found, "conversation_not_found")
    end
  end

  def create(conn, %{"conversation_id" => conversation_id} = params) do
    case Delegations.start(caller(conn), conversation_id, params) do
      {:ok, delegation} ->
        conn |> put_status(:accepted) |> json(%{"delegation" => delegation})

      {:error, :invalid_command} ->
        refusal(conn, :unprocessable_entity, "invalid_command")

      {:error, :agent_not_available} ->
        refusal(conn, :unprocessable_entity, "agent_not_available")

      {:error, :cwd_not_allowed} ->
        refusal(conn, :unprocessable_entity, "cwd_not_allowed")

      {:error, :machine_offline} ->
        refusal(conn, :conflict, "computer_offline")

      {:error, :agent_box_control_forbidden} ->
        refusal(conn, :forbidden, "agent_box_control_forbidden")

      {:error, :agent_computer_control_forbidden} ->
        refusal(conn, :forbidden, "agent_computer_control_forbidden")

      {:error, :scope_forbidden} ->
        refusal(conn, :forbidden, "insufficient_scope")

      {:error, :target_not_found} ->
        refusal(conn, :not_found, "target_not_found")

      {:error, reason} ->
        refusal(conn, :unprocessable_entity, error_code(reason))
    end
  end

  def show(conn, %{"conversation_id" => conversation_id, "id" => id}) do
    case Delegations.get(caller(conn), conversation_id, id) do
      {:ok, delegation} -> json(conn, %{"delegation" => delegation})
      {:error, reason} -> delegation_refusal(conn, reason)
    end
  end

  def delete(conn, %{"conversation_id" => conversation_id, "id" => id}) do
    case Delegations.cancel(caller(conn), conversation_id, id) do
      {:ok, delegation} -> conn |> put_status(:accepted) |> json(%{"delegation" => delegation})
      {:error, reason} -> delegation_refusal(conn, reason)
    end
  end

  defp caller(conn) do
    %{
      user: conn.assigns[:current_user],
      agent: conn.assigns[:current_agent],
      scopes: conn.assigns[:delegation_scopes] || []
    }
  end

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "delegation_refused"

  defp refusal(conn, status, code),
    do: conn |> put_status(status) |> json(%{"error" => %{"code" => code}})

  defp delegation_refusal(conn, :agent_box_control_forbidden),
    do: refusal(conn, :forbidden, "agent_box_control_forbidden")

  defp delegation_refusal(conn, :agent_computer_control_forbidden),
    do: refusal(conn, :forbidden, "agent_computer_control_forbidden")

  defp delegation_refusal(conn, :scope_forbidden),
    do: refusal(conn, :forbidden, "insufficient_scope")

  defp delegation_refusal(conn, _reason),
    do: refusal(conn, :not_found, "delegation_not_found")
end
