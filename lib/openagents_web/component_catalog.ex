defmodule OpenAgentsWeb.ComponentCatalog do
  @moduledoc """
  The executable inventory for the OpenAgents component system.

  The sidebar and demo pages both read this list. Tests require every public
  function component in `OpenAgentsWeb.UI` and the documented layout modules to
  appear here, so the catalog cannot drift behind the supported API.

  `OpenAgentsWeb.UI` is the only product component module. It combines the
  vendored Basecoat structure with the OpenAgents style pack. Icon demos use the
  preferred vendored Apps SDK set; see `docs/ICONS.md` for the exceptional
  Heroicons fallback policy and current fallback inventory.
  """

  @sections [
    %{
      title: "OpenAgents UI",
      items: [
        %{
          slug: "openagents-button",
          title: "Button",
          icon: "cube",
          source: "OpenAgentsWeb.UI.button/1",
          summary: "Eight variants, four sizes, navigation, and a danger tone."
        },
        %{
          slug: "openagents-text-button",
          title: "Text button",
          icon: "text",
          source: "OpenAgentsWeb.UI.text_button/1",
          summary: "Borderless action for inline and secondary affordances."
        },
        %{
          slug: "openagents-input",
          title: "Input",
          icon: "square-text",
          source: "OpenAgentsWeb.UI.input/1",
          summary: "Form-aware text, select, textarea, checkbox, and raw inputs."
        },
        %{
          slug: "openagents-textarea",
          title: "Textarea",
          icon: "text",
          source: "OpenAgentsWeb.UI.textarea/1",
          summary: "Unwrapped multiline text primitive."
        },
        %{
          slug: "openagents-label",
          title: "Label",
          icon: "tag",
          source: "OpenAgentsWeb.UI.label/1",
          summary: "Form label bound to a control by ID."
        },
        %{
          slug: "openagents-field",
          title: "Field",
          icon: "file-document",
          source: "OpenAgentsWeb.UI.field/1",
          summary: "Wrapper that stacks a label, control, and validation message."
        },
        %{
          slug: "openagents-breadcrumb",
          title: "Breadcrumb",
          icon: "compass",
          source: "OpenAgentsWeb.UI.breadcrumb/1",
          summary: "Ancestor trail ending in the current page, which is not a link."
        },
        %{
          slug: "openagents-copy-button",
          title: "Copy button",
          icon: "copy",
          source: "OpenAgentsWeb.UI.copy_button/1",
          summary: "Copies text and confirms it, so the reader is not left guessing."
        },
        %{
          slug: "openagents-header",
          title: "Header",
          icon: "book",
          source: "OpenAgentsWeb.UI.header/1",
          summary: "Page heading with supporting text and an action slot."
        },
        %{
          slug: "openagents-table",
          title: "Table",
          icon: "table-cells-filled",
          source: "OpenAgentsWeb.UI.table/1",
          summary: "Responsive rows with regular-list and LiveView stream support."
        },
        %{
          slug: "openagents-list",
          title: "List",
          icon: "file-document",
          source: "OpenAgentsWeb.UI.list/1",
          summary: "Title and description pairs."
        },
        %{
          slug: "openagents-alert",
          title: "Alert",
          icon: "warning",
          source: "OpenAgentsWeb.UI.alert/1",
          summary: "Four variants across box, row, and notice appearances."
        },
        %{
          slug: "openagents-badge",
          title: "Badge",
          icon: "tag",
          source: "OpenAgentsWeb.UI.badge/1",
          summary: "Status pill in six variants."
        },
        %{
          slug: "openagents-card",
          title: "Card",
          icon: "square-image",
          source: "OpenAgentsWeb.UI.card/1",
          summary: "Content container with an optional corner frame and danger variant."
        },
        %{
          slug: "openagents-avatar",
          title: "Avatar",
          icon: "user",
          source: "OpenAgentsWeb.UI.avatar/1",
          summary: "Image or initials fallback in three sizes."
        },
        %{
          slug: "openagents-item",
          title: "Item",
          icon: "dot",
          source: "OpenAgentsWeb.UI.item/1",
          summary: "Status, label, and detail row for activity lists."
        },
        %{
          slug: "openagents-event-header",
          title: "Event header",
          icon: "info",
          source: "OpenAgentsWeb.UI.event_header/1",
          summary: "Titled event row with status, timestamp, and chip slot."
        },
        %{
          slug: "openagents-empty",
          title: "Empty state",
          icon: "circle",
          source: "OpenAgentsWeb.UI.empty/1",
          summary: "Placeholder for lists and panels with nothing to show."
        },
        %{
          slug: "openagents-kbd",
          title: "Keyboard key",
          icon: "keyboard",
          source: "OpenAgentsWeb.UI.kbd/1",
          summary: "Rendered keycap for shortcut documentation."
        },
        %{
          slug: "openagents-menu",
          title: "Menu",
          icon: "menu",
          source: "OpenAgentsWeb.UI.menu/1",
          summary: "Native popover menu surface used by the account control."
        },
        %{
          slug: "openagents-frame",
          title: "Frame",
          icon: "grid",
          source: "OpenAgentsWeb.UI.frame/1",
          summary: "Corner-bracket decoration around arbitrary content."
        },
        %{
          slug: "openagents-status-indicator",
          title: "Status indicator",
          icon: "check-circle",
          source: "OpenAgentsWeb.UI.status_indicator/1",
          summary: "Labeled state dot, optionally decorative."
        },
        %{
          slug: "openagents-audio-player",
          title: "Audio player",
          icon: "play",
          source: "OpenAgentsWeb.UI.audio_player/1",
          summary: "Labeled audio element for recordings."
        },
        %{
          slug: "openagents-icon",
          title: "Icon",
          icon: "sparkle",
          source: "OpenAgentsWeb.UI.icon/1",
          summary: "Apps SDK glyph with an optional accessible label."
        }
      ]
    },
    %{
      title: "Layout",
      items: [
        %{
          slug: "sidebar-section",
          title: "Sidebar section",
          icon: "chevron-down",
          source: "OpenAgentsWeb.Layouts.sidebar_section/1",
          summary: "A collapsible group of sidebar rows, built on native details."
        },
        %{
          slug: "sidebar-link",
          title: "Sidebar link",
          icon: "menu",
          source: "OpenAgentsWeb.Layouts.sidebar_link/1",
          summary: "A navigation row that patches within a LiveView and navigates out of it."
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
          summary: "Avatar trigger and native popover menu for the signed-in user."
        }
      ]
    },
    %{
      title: "SCV graph",
      items: [
        %{
          slug: "graph-node",
          title: "Graph node",
          icon: "circle",
          source: "OpenAgentsWeb.UI.Graph.graph_node/1",
          summary:
            "Circle for a live SCV, rect for inert data; ring style carries lifecycle state."
        },
        %{
          slug: "graph-link",
          title: "Graph link",
          icon: "compass",
          source: "OpenAgentsWeb.UI.Graph.graph_link/1",
          summary: "Surface-anchored link with a shape-conforming termination and a step pulse."
        },
        %{
          slug: "scv-streams",
          title: "SCV streams",
          icon: "text",
          source: "OpenAgentsWeb.UI.Graph.scv_streams/1",
          summary: "Each agent beside the tail of what it is currently saying."
        },
        %{
          slug: "scv-swarm",
          title: "SCV swarm",
          icon: "grid",
          source: "OpenAgentsWeb.UI.Graph.scv_swarm/1",
          summary: "Many SCVs at once in a deterministic staged layout."
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

  @doc "Looks up one item by slug. Returns `nil` when the slug is unknown."
  def fetch(slug), do: Enum.find(items(), &(&1.slug == slug))

  @doc "Modules covered by the executable catalog and deliberate exclusions."
  def documented_modules do
    %{
      OpenAgentsWeb.UI => [],
      OpenAgentsWeb.Layouts => [:app, :flash_group],
      # graph_defs/1 emits marker definitions into a parent graph surface; it
      # renders nothing on its own, so it has no demoable page. graph_surface/1
      # is the host element and is demoed through the components that use it.
      OpenAgentsWeb.UI.Graph => [:graph_defs, :graph_surface],
      OpenAgentsWeb.Components.RepoHeader => []
    }
  end
end
