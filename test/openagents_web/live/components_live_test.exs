defmodule OpenAgentsWeb.ComponentsLiveTest do
  use OpenAgentsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias OpenAgentsWeb.ComponentCatalog

  test "the index lists every component in the catalog", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/components")

    assert html =~ "Component library"
    assert has_element?(view, "#components-index")

    for item <- ComponentCatalog.items() do
      assert has_element?(view, ~s{a[href="/components/#{item.slug}"]}),
             "index is missing a link to #{item.slug}"
    end
  end

  test "every catalog slug renders its own page", %{conn: conn} do
    for item <- ComponentCatalog.items() do
      {:ok, view, html} = live(conn, ~p"/components/#{item.slug}")

      assert has_element?(view, "#component-#{item.slug}"),
             "#{item.slug} did not render a component page"

      assert html =~ item.title
      assert html =~ item.source
    end
  end

  test "each page marks its own sidebar row as selected", %{conn: conn} do
    for item <- ComponentCatalog.items() do
      {:ok, view, _html} = live(conn, ~p"/components/#{item.slug}")

      assert has_element?(
               view,
               ~s{.sidebar-row[data-selected] a[href="/components/#{item.slug}"]}
             ),
             "#{item.slug} did not mark its sidebar row selected"
    end
  end

  test "the sidebar is present on component pages", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/components/button")

    assert has_element?(view, ~s{nav[aria-label="Component library"]})
    assert has_element?(view, ~s{a[href="/components/icons"]})
  end

  test "an unknown slug redirects back to the index", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/components"}}} =
             live(conn, ~p"/components/not-a-component")
  end

  test "the icons page keeps its own route ahead of the slug route", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/components/icons")

    assert html =~ "glyphs"
    refute has_element?(view, "#component-icons")
  end

  test "the button page renders the button variants", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/components/button")

    assert has_element?(view, "#demo-button-primary", "Primary")
    assert has_element?(view, "#demo-button-disabled")
  end

  test "the input page renders the demo form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/components/input")

    assert has_element?(view, "#component-form")
  end

  test "info flash action shows the flash", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/components/flash")

    view
    |> element("#demo-flash-info")
    |> render_click()

    assert render(view) =~ "This is the info flash from CoreComponents."
  end
end
