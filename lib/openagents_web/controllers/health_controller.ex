defmodule OpenAgentsWeb.HealthController do
  use OpenAgentsWeb, :controller

  def show(conn, _params) do
    case OpenAgents.Repo.query("SELECT 1") do
      {:ok, _result} ->
        json(conn, %{status: "ok", revision: OpenAgents.BuildInfo.revision()})

      {:error, _reason} ->
        conn |> put_status(:service_unavailable) |> json(%{status: "unavailable"})
    end
  end
end
