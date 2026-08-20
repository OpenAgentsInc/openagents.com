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
    {:ok, view, _html} = live(conn, ~p"/components/openagents-button")

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
    {:ok, view, _html} = live(conn, ~p"/components/openagents-button")

    assert has_element?(view, "#demo-button-primary", "Primary")
    assert has_element?(view, "#demo-button-disabled")
  end

  test "the input page renders the demo form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/components/openagents-input")

    assert has_element?(view, "#component-form")
  end

  test "the catalog exposes no nonfunctional theme control", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/components")

    refute has_element?(view, ~s{a[href="/components/theme-toggle"]})
  end

  test "the theme control is one action, not a three-rung picker" do
    # This previously asserted three buttons -- system, light, dark. The owner
    # replaced that with a single toggle: storing nothing IS system, and it is
    # the default until someone chooses, so a third button made the common case
    # (never touching this) look like an unmade decision.
    document =
      OpenAgentsWeb.Layouts.theme_toggle(%{})
      |> rendered_to_string()
      |> LazyHTML.from_fragment()

    buttons = document |> LazyHTML.query(~s{button.theme-toggle}) |> LazyHTML.to_tree()
    assert length(buttons) == 1

    assert document
           |> LazyHTML.query(~s{button.theme-toggle[aria-label="Toggle theme"]})
           |> LazyHTML.to_tree() != []

    # Both glyphs ship; which one shows is decided at runtime from the effective
    # theme, because with nothing stored only the browser knows it.
    for glyph <- ~w(theme-toggle__sun theme-toggle__moon) do
      assert document |> LazyHTML.query(~s{.#{glyph}}) |> LazyHTML.to_tree() != [],
             "the #{glyph} glyph is missing, so the control cannot name its destination"
    end

    # No rung survives from the old picker.
    assert document |> LazyHTML.query(~s{[data-theme-option]}) |> LazyHTML.to_tree() == []
  end
end
