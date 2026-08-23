defmodule OpenAgentsWeb.ApiExtensionControllerTest do
  use OpenAgentsWeb.ConnCase, async: true

  test "GET /api/v3 lists the issue extension fields an agent can rely on", %{conn: conn} do
    conn = get(conn, ~p"/api/v3")

    assert %{
             "api_version" => "v3",
             "extensions" => %{
               "issue.openagents" => %{
                 "version" => _version,
                 "fields" => fields,
                 "filters" => %{"blocked" => _filter},
                 "endpoints" => endpoints
               }
             }
           } = json_response(conn, 200)

    assert %{"blocked" => %{"type" => "boolean"}} = fields
    assert %{"blocked_by" => %{"type" => "array"}} = fields
    assert %{"blocks" => %{"type" => "array"}} = fields
    assert Enum.any?(endpoints, &String.contains?(&1, "/dependencies"))
  end
end
