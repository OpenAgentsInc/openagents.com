defmodule OpenAgentsWeb.HealthController do
  use OpenAgentsWeb, :controller

  def show(conn, _params) do
    case {OpenAgents.Repo.query("SELECT 1"), OpenAgents.Cluster.local_report()} do
      {{:ok, _result}, %{"ready" => true, "revision" => revision}} ->
        json(conn, %{status: "ok", revision: revision})

      {{:ok, _result}, report} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          status: "unavailable",
          reason: "runtime_not_ready",
          boot_converged: report["boot_converged"],
          deployment_ready: report["deployment_ready"],
          admission_ready: report["admission_ready"]
        })

      {{:error, _reason}, _report} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "unavailable", reason: "database_unavailable"})
    end
  end
end
