defmodule OpenAgentsWeb.ComponentsLiveTest do
  use OpenAgentsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders every reusable component on /components", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/components")

    assert html =~ "Component library"
    assert has_element?(view, "#components-gallery")
    assert has_element?(view, "#demo-button-primary", "Primary")
    assert has_element?(view, "#component-form")
    assert has_element?(view, "#demo-table")
    assert has_element?(view, "#demo-icons")
    assert has_element?(view, "#demo-theme-toggle")
    assert has_element?(view, "#section-flash")
  end

  test "info flash action shows the flash", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/components")

    view
    |> element("#demo-flash-info")
    |> render_click()

    assert render(view) =~ "This is the info flash from CoreComponents."
  end
end
