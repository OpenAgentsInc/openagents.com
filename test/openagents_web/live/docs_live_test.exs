defmodule OpenAgentsWeb.DocsLiveTest do
  use OpenAgentsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "the docs page renders with its sidebar", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/docs")

    assert html =~ "Documentation"
    assert has_element?(view, ~s{nav[aria-label="Documentation"]})
  end

  test "the docs sidebar has no search bar", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/docs")

    refute has_element?(view, ".docs-sidebar__search")
    refute has_element?(view, ~s{input[placeholder="Search docs..."]})
    refute html =~ "Search docs"
  end
end
