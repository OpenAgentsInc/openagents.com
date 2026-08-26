defmodule OpenAgentsWeb.PageControllerTest do
  use OpenAgentsWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "The Agent Forge"
  end

  test "the landing page sells the forge, not a CLI install", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    # The landing page carried an install command under the hero. It went
    # through two wrong answers before this one: `curl … | bash`, withdrawn
    # along with the binary release it installed, and then `npm i -g …`, which
    # was a substitution when the instruction had been to remove it. The
    # homepage is not where the CLI gets sold.
    refute html =~ ~s(id="home-install")
    refute html =~ "install.sh"
    refute html =~ "npm i -g"
  end
end
