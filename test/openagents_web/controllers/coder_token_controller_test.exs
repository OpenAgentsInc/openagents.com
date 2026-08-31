defmodule OpenAgentsWeb.CoderTokenControllerTest do
  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.ApiTokens

  test "mints a Coder-audience token for the authenticated account", %{conn: conn} do
    user = github_user("coder-token", "token-user")

    {:ok, _token, plaintext} =
      ApiTokens.create(user, %{name: "Coder", scopes: ["chat:account"]})

    response =
      conn
      |> put_req_header("authorization", "Bearer " <> plaintext)
      |> post(~p"/api/v1/coder/token")

    assert %{
             "token" => token,
             "audience" => "coder",
             "expires_in" => 3600
           } = json_response(response, 200)

    assert is_binary(token) and byte_size(token) > 0
    assert get_resp_header(response, "cache-control") == ["no-store"]
  end

  test "requires the chat account scope", %{conn: conn} do
    assert %{"code" => "unauthenticated"} =
             conn
             |> post(~p"/api/v1/coder/token")
             |> json_response(401)
  end
end
