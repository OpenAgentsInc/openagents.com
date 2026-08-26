defmodule OpenAgentsWeb.PageControllerTest do
  use OpenAgentsWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "The Agent Forge"
  end

  test "the landing page names the one command that installs the CLI", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~s(id="home-install-command")
    assert html =~ "npm i -g @openagentsinc/cli"

    # The binary release was withdrawn: its artifacts and every channel pointer
    # were deleted, so this command can only fail now, and it shipped commands
    # that printed fabricated data. A page that still offers it is worse than a
    # page with no install command at all.
    refute html =~ "install.sh"
  end
end
