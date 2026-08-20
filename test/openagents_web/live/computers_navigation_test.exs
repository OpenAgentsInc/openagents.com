defmodule OpenAgentsWeb.ComputersNavigationTest do
  use OpenAgentsWeb.ConnCase
  import Phoenix.LiveViewTest

  test "the canonical Computers surface carries authenticated application chrome", %{conn: conn} do
    conn = log_in_chatting_user(conn, "computers-surface")
    {:ok, view, _html} = live(conn, ~p"/computers")

    assert has_element?(view, "#computers-page")
    assert has_element?(view, "#computers-manager")
    refute has_element?(view, "header.command-bar")
    assert has_element?(view, ~s(#sidebar a.sidebar-row__hit[href="/chat"]))
    assert has_element?(view, "#account-bar-trigger")
  end

  test "the legacy authenticated path redirects to the canonical URL without its query", %{
    conn: conn
  } do
    conn = log_in_github_user(conn, "computers-legacy-path")
    conn = get(conn, "/machines?code=must-not-survive")

    assert redirected_to(conn, 302) == ~p"/computers"
    refute get_resp_header(conn, "location") |> List.first() |> String.contains?("code=")
  end
end
