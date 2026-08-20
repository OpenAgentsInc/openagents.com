defmodule OpenAgentsWeb.ComponentCatalog do
  @moduledoc """
  The component catalog's table of contents.

  Both the sidebar in `layouts/components.html.heex` and the pages rendered by
  `OpenAgentsWeb.ComponentsLive` are generated from this list, so a component
  cannot appear in one and be missing from the other. Adding a component means
  adding an entry here and a matching `component_demo/1` clause in
  `ComponentsLive`; `ComponentsLive` has a test that asserts every slug here
  resolves to a page, and `ComponentCatalogTest` asserts the catalog covers
  every public function component in the modules it claims to document.

  Two component sets ship in this repo and they are catalogued separately:

    * `OpenAgentsWeb.CoreComponents` — the Phoenix-generated set, restyled onto
      basecoat. Imported by `use OpenAgentsWeb, :live_view`.
    * `OpenAgentsWeb.SarahUI` — the Sarah interface primitives, imported
      separately via `sarah_html_helpers`. `button`, `input`, and `icon` exist
      in both sets, which is why the SarahUI slugs are prefixed `sarah-`.

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
      title: "Sarah UI",
      items: [
        %{
          slug: "sarah-button",
          title: "Button",
          icon: "cube",
          source: "OpenAgentsWeb.SarahUI.button/1",
          summary: "Eight variants, four sizes, and a danger tone."
        },
        %{
          slug: "sarah-text-button",
          title: "Text button",
          icon: "text",
          source: "OpenAgentsWeb.SarahUI.text_button/1",
          summary: "Borderless action for inline and secondary affordances."
        },
        %{
          slug: "sarah-input",
          title: "Input",
          icon: "square-text",
          source: "OpenAgentsWeb.SarahUI.input/1",
          summary: "Bare text input primitive, unwrapped by a form field."
        },
        %{
          slug: "sarah-textarea",
          title: "Textarea",
          icon: "text",
          source: "OpenAgentsWeb.SarahUI.textarea/1",
          summary: "Multi-line text primitive."
        },
        %{
          slug: "sarah-label",
          title: "Label",
          icon: "tag",
          source: "OpenAgentsWeb.SarahUI.label/1",
          summary: "Form label bound to a control by id."
        },
        %{
          slug: "sarah-field",
          title: "Field",
          icon: "file-document",
          source: "OpenAgentsWeb.SarahUI.field/1",
          summary: "Wrapper that stacks a label and its control."
        },
        %{
          slug: "sarah-alert",
          title: "Alert",
          icon: "warning",
          source: "OpenAgentsWeb.SarahUI.alert/1",
          summary: "Four variants across box, row, and notice appearances."
        },
        %{
          slug: "sarah-badge",
          title: "Badge",
          icon: "tag",
          source: "OpenAgentsWeb.SarahUI.badge/1",
          summary: "Status pill in six variants."
        },
        %{
          slug: "sarah-card",
          title: "Card",
          icon: "square-image",
          source: "OpenAgentsWeb.SarahUI.card/1",
          summary: "Content container with an optional corner frame and danger variant."
        },
        %{
          slug: "sarah-avatar",
          title: "Avatar",
          icon: "user",
          source: "OpenAgentsWeb.SarahUI.avatar/1",
          summary: "Image or initials fallback in three sizes."
        },
        %{
          slug: "sarah-item",
          title: "Item",
          icon: "dot",
          source: "OpenAgentsWeb.SarahUI.item/1",
          summary: "Status, label, and detail row for activity lists."
        },
        %{
          slug: "sarah-event-header",
          title: "Event header",
          icon: "info",
          source: "OpenAgentsWeb.SarahUI.event_header/1",
          summary: "Titled event row with status, timestamp, and chip slot."
        },
        %{
          slug: "sarah-empty",
          title: "Empty state",
          icon: "circle",
          source: "OpenAgentsWeb.SarahUI.empty/1",
          summary: "Placeholder for lists and panels with nothing to show."
        },
        %{
          slug: "sarah-kbd",
          title: "Keyboard key",
          icon: "keyboard",
          source: "OpenAgentsWeb.SarahUI.kbd/1",
          summary: "Rendered keycap for shortcut documentation."
        },
        %{
          slug: "sarah-menu",
          title: "Menu",
          icon: "menu",
          source: "OpenAgentsWeb.SarahUI.menu/1",
          summary: "Popover menu surface used by the account control."
        },
        %{
          slug: "sarah-frame",
          title: "Frame",
          icon: "grid",
          source: "OpenAgentsWeb.SarahUI.frame/1",
          summary: "Corner-bracket decoration around arbitrary content."
        },
        %{
          slug: "sarah-status-indicator",
          title: "Status indicator",
          icon: "check-circle",
          source: "OpenAgentsWeb.SarahUI.status_indicator/1",
          summary: "Labelled state dot, optionally decorative."
        },
        %{
          slug: "sarah-audio-player",
          title: "Audio player",
          icon: "play",
          source: "OpenAgentsWeb.SarahUI.audio_player/1",
          summary: "Labelled audio element for recordings."
        },
        %{
          slug: "sarah-icon",
          title: "Icon",
          icon: "sparkle",
          source: "OpenAgentsWeb.SarahUI.icon/1",
          summary: "Apps SDK glyph with an optional accessible label."
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
        },
        %{
          slug: "command-bar",
          title: "Command bar",
          icon: "compass",
          source: "OpenAgentsWeb.Layouts.command_bar/1",
          summary: "Top bar with brand lockup, control slot, and account menu."
        },
        %{
          slug: "account-control",
          title: "Account control",
          icon: "user",
          source: "OpenAgentsWeb.Layouts.account_control/1",
          summary: "Avatar trigger and popover menu for the signed-in user."
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

  @doc """
  The modules this catalog claims to document, and the components in each that
  are deliberately not given a page.

  `OpenAgentsWeb.Layouts.app/1` and `flash_group/1` wrap the catalog page
  itself, so they cannot be demoed inside it.
  """
  def documented_modules do
    %{
      OpenAgentsWeb.CoreComponents => [],
      OpenAgentsWeb.SarahUI => [],
      OpenAgentsWeb.Layouts => [:app, :flash_group]
    }
  end
end
