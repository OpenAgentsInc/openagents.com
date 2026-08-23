defmodule OpenAgentsWeb.CapacityController do
  @moduledoc """
  Owner-authenticated capacity and device-to-job matching endpoints.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.Capacity

  def show(conn, _params) do
    json(conn, Capacity.projection(conn.assigns.current_user))
  end

  def matches(conn, params) do
    case Capacity.match(conn.assigns.current_user, params) do
      {:ok, response} ->
        json(conn, response)

      {:error, %{"error" => %{"code" => code}} = response} ->
        conn
        |> put_status(status_for(code))
        |> json(response)
    end
  end

  defp status_for("computer_not_found"), do: :not_found
  defp status_for("quantity_unavailable"), do: :conflict

  defp status_for(code)
       when code in ["evidence_stale", "evidence_unavailable", "incident_drained"],
       do: :service_unavailable

  defp status_for(_code), do: :unprocessable_entity
end
