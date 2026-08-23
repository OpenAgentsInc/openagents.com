defmodule OpenAgentsWeb.AppShellViewportTest do
  @moduledoc """
  The application shell is sized against the visible viewport (#128).

  `100vh` on a mobile browser is the viewport with the chrome collapsed, so a
  shell measured in it is taller than what the reader can see: the tail of the
  page sits under the toolbar, and because the document itself does not scroll
  there is no gesture that collapses the chrome to reveal it. The fix is
  dynamic viewport units, which are the same value on a desktop viewport.

  These assertions exist so a future `h-screen` shell cannot silently
  reintroduce a page a phone cannot read to the end of.
  """

  use OpenAgentsWeb.ConnCase, async: false

  test "the signed-in shell measures itself in dynamic viewport units", %{conn: conn} do
    conn = log_in_github_user(conn, "app-shell-viewport-user")
    html = html_response(get(conn, ~p"/"), 200)

    assert html =~ ~s(id="app-shell")
    assert html =~ "h-dvh"
    refute html =~ "h-screen"
  end

  test "the signed-out document does not measure itself in static viewport units", %{conn: conn} do
    html = html_response(get(conn, ~p"/"), 200)

    assert html =~ "h-dvh"
    refute html =~ "h-screen"
  end

  test "no stylesheet sizes a full-height surface in static viewport units" do
    for file <- ["assets/css/app.css", "assets/css/openagents.css"] do
      css = File.read!(file)

      refute css =~ ~r/height:\s*100vh/, "#{file} sizes a surface with 100vh"
    end
  end
end
