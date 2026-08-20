defmodule OpenAgentsWeb.ComponentCatalog do
  @moduledoc """
  The component catalog's table of contents.

  Both the sidebar in `layouts/components.html.heex` and the pages rendered by
  `OpenAgentsWeb.ComponentsLive` are generated from this list, so a component
  cannot appear in one and be missing from the other. Adding a component means
  adding an entry here and a matching `component_demo/1` clause in
  `ComponentsLive`; `ComponentsLive` has a test that asserts every slug here
  resolves to a page.

  Icon names are drawn from the vendored Apps SDK set (`OpenAgentsWeb.Icons`).
  """

  @sections [
    %{
      title: "Core components",
      items: [
        %{
          slug: "button",
          title: "Button",
          icon: "cube",
          source: "OpenAgentsWeb.CoreComponents.button/1",
          summary: "Default, primary, navigation, and disabled variants."
        },
        %{
          slug: "input",
          title: "Input",
          icon: "square-text",
          source: "OpenAgentsWeb.CoreComponents.input/1",
          summary: "Text, select, textarea, and checkbox fields inside a form."
        },
        %{
          slug: "header",
          title: "Header",
          icon: "book",
          source: "OpenAgentsWeb.CoreComponents.header/1",
          summary: "Page title with an optional subtitle and action slot."
        },
        %{
          slug: "table",
          title: "Table",
          icon: "table-cells-filled",
          source: "OpenAgentsWeb.CoreComponents.table/1",
          summary: "Row listing with column and action slots."
        },
        %{
          slug: "list",
          title: "List",
          icon: "file-document",
          source: "OpenAgentsWeb.CoreComponents.list/1",
          summary: "Title and description pairs in a definition list."
        },
        %{
          slug: "icon",
          title: "Icon",
          icon: "grid",
          source: "OpenAgentsWeb.CoreComponents.icon/1",
          summary: "Inline glyphs from the vendored icon set."
        },
        %{
          slug: "flash",
          title: "Flash",
          icon: "bell",
          source: "OpenAgentsWeb.CoreComponents.flash/1",
          summary: "Info and error toasts rendered by the layout's flash group."
        }
      ]
    },
    %{
      title: "Layout",
      items: [
        %{
          slug: "theme-toggle",
          title: "Theme toggle",
          icon: "moon",
          source: "OpenAgentsWeb.Layouts.theme_toggle/1",
          summary: "System, light, and dark. The same control sits in the site header."
        }
      ]
    },
    %{
      title: "Forge",
      items: [
        %{
          slug: "repo-header",
          title: "Repo header",
          icon: "folder",
          source: "OpenAgentsWeb.Components.RepoHeader.repo_header/1",
          summary: "Repository breadcrumb and tab bar with issue counts."
        }
      ]
    }
  ]

  @doc "Sidebar sections, in display order."
  def sections, do: @sections

  @doc "Every catalog item, flattened, in display order."
  def items, do: Enum.flat_map(@sections, & &1.items)

  @doc "Every slug in the catalog."
  def slugs, do: Enum.map(items(), & &1.slug)

  @doc "Look up one item by slug. Returns nil when the slug is unknown."
  def fetch(slug), do: Enum.find(items(), &(&1.slug == slug))
end
