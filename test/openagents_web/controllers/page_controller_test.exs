defmodule OpenAgentsWeb.PageControllerTest do
  use OpenAgentsWeb.ConnCase

  test "GET /", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "Introducing"
    assert html =~ "Coder."
    assert html =~ "Your all-in-one coding agent."
  end

  test "the landing page leads with the install command", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    # The homepage sells Coder, and the whole of the pitch a reader has to act
    # on is one line they can paste. It is the same command
    # `priv/docs/install-cli.md` documents and the same script this site
    # serves, so a reader who copies it from the hero and a reader who copies
    # it from the docs run the same installer.
    assert html =~ ~s(id="home-install-command")
    assert html =~ "curl -fsSL https://openagents.com/install.sh | sh"
    assert html =~ "irm https://openagents.com/install.ps1 | iex"

    # `npm i -g @openagentsinc/cli` was a previous answer and is not one now:
    # there is no npm package, and a homepage that prints an install command
    # nothing publishes is worse than one that prints none.
    refute html =~ "npm i -g"
  end

  test "GET /install.ps1 serves the Windows installer", %{conn: conn} do
    conn = get(conn, "/install.ps1")

    assert conn.status == 200
    assert conn.resp_body =~ "irm https://openagents.com/install.ps1 | iex"
    assert conn.resp_body =~ "SHA256SUMS-"
  end
end
