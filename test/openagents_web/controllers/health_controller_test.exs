defmodule OpenAgentsWeb.HealthControllerTest do
  use OpenAgentsWeb.ConnCase

  test "reports healthy when PostgreSQL is reachable", %{conn: conn} do
    conn = get(conn, ~p"/status")

    assert json_response(conn, 200) == %{
             "status" => "ok",
             "revision" => OpenAgents.BuildInfo.revision()
           }
  end
end
