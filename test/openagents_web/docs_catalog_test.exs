defmodule OpenAgentsWeb.DocsCatalogTest do
  @moduledoc """
  Documentation drifts silently. These assert the two ways it goes wrong: a
  catalogued page with no source file, and a page describing a surface the
  application no longer serves.
  """

  use OpenAgentsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias OpenAgentsWeb.DocsCatalog

  test "slugs are unique" do
    slugs = DocsCatalog.slugs()
    assert length(slugs) == length(Enum.uniq(slugs))
  end

  test "every catalogued page has a Markdown source that renders" do
    for item <- DocsCatalog.items() do
      assert {:ok, page} = DocsCatalog.render(item.slug),
             "#{item.slug} is catalogued but priv/docs/#{item.slug}.md does not render"

      assert page.item.slug == item.slug
    end
  end

  test "every Markdown source is catalogued" do
    orphans =
      DocsCatalog.source_dir()
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.map(&(&1 |> Path.basename() |> Path.rootname()))
      |> Enum.reject(&(&1 in DocsCatalog.slugs()))

    assert orphans == [],
           "these pages exist but are unreachable from the sidebar: #{Enum.join(orphans, ", ")}"
  end

  test "every page documents a route the application actually serves" do
    # A docs site that describes surfaces which do not exist is worse than one
    # missing pages: the reader cannot tell which half they are reading.
    for item <- DocsCatalog.items() do
      path = String.replace(item.route, ~r/:[a-z_]+/, "placeholder")

      assert Phoenix.Router.route_info(OpenAgentsWeb.Router, "GET", path, "openagents.com") !=
               :error,
             "#{item.slug} documents #{item.route}, which no longer resolves"
    end
  end

  test "Repositories and CLI are separate single-subject sections" do
    sections =
      Map.new(DocsCatalog.sections(), &{&1.title, Enum.map(&1.items, fn i -> i.slug end)})

    assert Map.fetch!(sections, "Repositories") == [
             "repositories",
             "create-repository",
             "import-github",
             "clone-push-pull",
             "delete-repository"
           ]

    assert Map.fetch!(sections, "CLI") == [
             "openagents-cli",
             "install-cli",
             "cli-command-reference",
             "cli-api"
           ]

    refute Map.has_key?(sections, "Repositories and CLI")
  end

  test "neither split section repeats its own title as a page title" do
    # The sidebar read `Repositories and CLI > Repositories and CLI` before the
    # split, which told the reader nothing about where they were.
    for section <- DocsCatalog.sections(), section.title in ["Repositories", "CLI"] do
      titles = Enum.map(section.items, & &1.title)

      refute section.title in titles,
             "the #{section.title} section contains a page also titled #{section.title}"
    end
  end

  test "every /docs link in the Markdown sources resolves to a catalogued page" do
    # A broken cross-link reads as a missing feature rather than a missing
    # page, so it is worth catching here rather than in a reader's tab.
    slugs = MapSet.new(DocsCatalog.slugs())

    broken =
      DocsCatalog.source_dir()
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        source = Path.basename(path)

        ~r{\(/docs/([a-z0-9-]+)}
        |> Regex.scan(File.read!(path), capture: :all_but_first)
        |> Enum.map(fn [slug] -> {source, slug} end)
        |> Enum.reject(fn {_source, slug} -> MapSet.member?(slugs, slug) end)
      end)

    assert broken == [],
           "these links point at pages the catalog does not have: " <>
             Enum.map_join(broken, ", ", fn {source, slug} -> "#{source} -> /docs/#{slug}" end)
  end

  test "headings become the table of contents, ignoring fenced code" do
    toc = DocsCatalog.headings("# Title\n\n## Real\n\n```\n## Not a heading\n```\n\n### Nested\n")

    assert toc == [
             %{title: "Real", level: 2, id: "real"},
             %{title: "Nested", level: 3, id: "nested"}
           ]
  end

  test "every table-of-contents entry links to an id the page contains" do
    for item <- DocsCatalog.items() do
      {:ok, page} = DocsCatalog.render(item.slug)
      html = page.html |> Phoenix.HTML.safe_to_string()

      for heading <- page.toc do
        assert html =~ ~s(id="#{heading.id}"),
               "#{item.slug} lists #{heading.title} in its rail, but the body has no ##{heading.id}"
      end
    end
  end

  test "published CLI docs cover authentication, installation, imports, and API access" do
    assert {:ok, install} = DocsCatalog.render("install-cli")
    assert install.markdown =~ "npm install --global @openagentsinc/cli"
    assert install.markdown =~ "npx --yes @openagentsinc/cli@latest"
    assert install.markdown =~ "openagents auth login --resume"
    assert install.markdown =~ "returns immediately"
    assert install.markdown =~ "`OPENAGENTS_AGENT_TOKEN` is an internal agent-runtime credential"
    assert install.markdown =~ "Do not run `auth setup-git` through `npx`"

    assert {:ok, import} = DocsCatalog.render("import-github")
    assert import.markdown =~ "one-time copy"
    assert import.markdown =~ "--wait-timeout 0"
    assert import.markdown =~ "A client timeout does not cancel"

    assert {:ok, api} = DocsCatalog.render("cli-api")
    assert api.markdown =~ "openagents api"
    assert api.markdown =~ ".issues[]"
    assert api.markdown =~ "projectsV2/PROJECT_NUMBER/items"
    assert api.markdown =~ ~s({"issue_number":11)
    refute api.markdown =~ ~s({"issue_id":42)
    assert api.markdown =~ "does not provide `openagents issue`"
    assert api.markdown =~ "`openagents project` commands"
  end

  describe "the docs surface" do
    test "the index lists every page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/docs")

      for item <- DocsCatalog.items() do
        assert has_element?(view, ~s{a[href="/docs/#{item.slug}"]}),
               "the index does not link to #{item.slug}"
      end
    end

    test "every page renders its Markdown as HTML", %{conn: conn} do
      for item <- DocsCatalog.items() do
        {:ok, _view, html} = live(conn, ~p"/docs/#{item.slug}")
        assert html =~ ~s(id="docs-#{item.slug}")
      end
    end

    test "an unknown page redirects to the index", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/docs"}}} = live(conn, ~p"/docs/not-a-page")
    end
  end
end
