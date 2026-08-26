defmodule OpenAgentsWeb.PageControllerTest do
  use OpenAgentsWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "The Agent Forge"
  end

  test "the landing page names the one command that installs the CLI", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~s(id="home-install-command")
    assert html =~ "curl -fsSL https://openagents.com/install.sh | bash"
  end
end
