defmodule OpenAgentsWeb.ApiExtensionControllerTest do
  use OpenAgentsWeb.ConnCase, async: true

  test "GET /api/v1 lists the issue extension fields an agent can rely on", %{conn: conn} do
    conn = get(conn, ~p"/api/v1")

    assert %{
             "api_version" => "v1",
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

  test "GET /api/v1 publishes one route entry for every live API v1 route", %{conn: conn} do
    published =
      conn
      |> get(~p"/api/v1")
      |> json_response(200)
      |> Map.fetch!("routes")

    live =
      OpenAgentsWeb.Router.__routes__()
      |> Enum.filter(&String.starts_with?(&1.path, "/api/v1"))
      |> Enum.map(fn route ->
        {String.upcase(Atom.to_string(route.verb)),
         Regex.replace(~r/:([a-z_]+)/, route.path, fn _whole, segment -> "{#{segment}}" end)}
      end)
      |> MapSet.new()

    assert MapSet.new(published, &{&1["method"], &1["path"]}) == live
  end

  test "every published route names its authority, family, and error contract", %{conn: conn} do
    published =
      conn
      |> get(~p"/api/v1")
      |> json_response(200)
      |> Map.fetch!("routes")

    for route <- published do
      assert route["authority"] in ~w(anonymous optional_bearer required_bearer),
             "#{route["method"]} #{route["path"]} has no authority classification"

      assert route["errors"] in ~w(envelope legacy),
             "#{route["method"]} #{route["path"]} has no error contract classification"

      assert is_binary(route["family"]) and route["family"] != ""
      assert is_boolean(route["mutation"])
    end
  end

  test "GET /api/v1 publishes the error envelope and its stable codes", %{conn: conn} do
    body = conn |> get(~p"/api/v1") |> json_response(200)

    assert body["errors"]["envelope"] == OpenAgentsWeb.ApiError.envelope_keys()

    assert body["errors"]["stable_codes"] ==
             Map.new(OpenAgentsWeb.ApiError.codes(), fn {code, status} -> {code, status} end)

    assert body["errors"]["stable_codes"]["not_found"] == 404
    assert is_binary(body["errors"]["field_errors"])
  end

  test "GET /api/v1 names every family the router serves", %{conn: conn} do
    body = conn |> get(~p"/api/v1") |> json_response(200)

    published = MapSet.new(body["routes"], & &1["family"])

    assert MapSet.new(body["families"]) == published
    assert "issue" in body["families"]
    assert "project" in body["families"]
  end
end
