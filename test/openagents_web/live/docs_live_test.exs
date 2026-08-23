defmodule OpenAgentsWeb.DocsLiveTest do
  use OpenAgentsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "the docs page renders with its sidebar", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/docs")

    assert html =~ "Documentation"
    assert has_element?(view, ~s{nav[aria-label="Documentation"]})
    assert has_element?(view, ~s(#docs-sidebar-collapse-toggle[aria-controls="docs-sidebar"]))
    assert has_element?(view, ~s(#docs-sidebar-expand-toggle[aria-controls="docs-sidebar"]))
  end

  test "the sidebar lists Repositories and CLI as separate sections", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/docs")

    for {section, slugs} <- [
          {"sidebar-section-repositories",
           ~w(repositories create-repository import-github clone-push-pull delete-repository)},
          {"sidebar-section-cli", ~w(openagents-cli install-cli cli-command-reference cli-api)}
        ],
        slug <- slugs do
      assert has_element?(view, ~s{##{section} a[href="/docs/#{slug}"]}),
             "#{section} does not link to /docs/#{slug}"
    end

    refute has_element?(view, "#sidebar-section-repositories-and-cli")
  end

  test "the index heads each split section with its own title", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/docs")

    assert has_element?(view, "#repositories", "Repositories")
    assert has_element?(view, "#cli", "CLI")
    refute html =~ "Repositories and CLI"
  end

  test "the docs sidebar has no search bar", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/docs")

    refute has_element?(view, ".docs-sidebar__search")
    refute has_element?(view, ~s{input[placeholder="Search docs..."]})
    refute html =~ "Search docs"
  end
end
