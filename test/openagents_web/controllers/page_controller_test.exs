defmodule OpenAgentsWeb.PageControllerTest do
  use OpenAgentsWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "The agent forge"
  end
end
