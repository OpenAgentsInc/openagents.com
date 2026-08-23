defmodule OpenAgentsWeb.HealthControllerTest do
  use OpenAgentsWeb.ConnCase

  setup do
    OpenAgents.Forge.CacheReadiness.reset()
    on_exit(&OpenAgents.Forge.CacheReadiness.reset/0)
    :ok
  end

  test "reports healthy when PostgreSQL is reachable", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert json_response(conn, 200) == %{
             "status" => "ok",
             "revision" => OpenAgents.BuildInfo.revision()
           }
  end

  test "retains the non-Cloud Run healthz alias", %{conn: conn} do
    assert %{"status" => "ok"} = conn |> get(~p"/healthz") |> json_response(200)
  end

  test "refuses readiness while boot code diverges from the live target", %{conn: conn} do
    key = {OpenAgents.Forge.BootConverge, :state}
    previous = :persistent_term.get(key, :missing)

    :persistent_term.put(key, %{
      "state" => "degraded",
      "ready" => false,
      "reason" => "artifact_missing",
      "sha" => String.duplicate("a", 40),
      "attempts" => 2,
      "retry_in_ms" => 1_000
    })

    on_exit(fn ->
      if previous == :missing,
        do: :persistent_term.erase(key),
        else: :persistent_term.put(key, previous)
    end)

    conn = get(conn, ~p"/healthz")

    assert json_response(conn, 503) == %{
             "status" => "unavailable",
             "reason" => "runtime_not_ready",
             "boot_converged" => false,
             "deployment_ready" => true,
             "admission_ready" => true,
             "forge_cache_ready" => true
           }
  end

  test "refuses readiness while a rolling provider drains the node", %{conn: conn} do
    on_exit(&OpenAgents.Cluster.Admission.restore/0)
    :ok = OpenAgents.Cluster.Admission.remove()

    conn = get(conn, ~p"/healthz")

    assert json_response(conn, 503) == %{
             "status" => "unavailable",
             "reason" => "runtime_not_ready",
             "boot_converged" => true,
             "deployment_ready" => true,
             "admission_ready" => false,
             "forge_cache_ready" => true
           }
  end

  test "refuses readiness after a repository cache cannot materialize", %{conn: conn} do
    :ok = OpenAgents.Forge.CacheReadiness.mark_unavailable("broken-cache", :materialize_cache)

    conn = get(conn, ~p"/healthz")

    assert json_response(conn, 503) == %{
             "status" => "unavailable",
             "reason" => "runtime_not_ready",
             "boot_converged" => true,
             "deployment_ready" => true,
             "admission_ready" => true,
             "forge_cache_ready" => false
           }
  end
end
