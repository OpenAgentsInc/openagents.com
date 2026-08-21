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
          slug: "openagents-alert",
          title: "Alert",
          icon: "warning",
          source: "OpenAgentsWeb.UI.alert/1",
          summary: "Four variants across box, row, and notice appearances."
        },
        %{
          slug: "openagents-audio-player",
          title: "Audio player",
          icon: "play",
          source: "OpenAgentsWeb.UI.audio_player/1",
          summary: "Labeled audio element for recordings."
        },
        %{
          slug: "openagents-avatar",
          title: "Avatar",
          icon: "user",
          source: "OpenAgentsWeb.UI.avatar/1",
          summary: "Image or initials fallback in three sizes."
        },
        %{
          slug: "openagents-badge",
          title: "Badge",
          icon: "tag",
          source: "OpenAgentsWeb.UI.badge/1",
          summary: "Status pill in six variants."
        },
        %{
          slug: "openagents-breadcrumb",
          title: "Breadcrumb",
          icon: "compass",
          source: "OpenAgentsWeb.UI.breadcrumb/1",
          summary: "Ancestor trail ending in the current page, which is not a link."
        },
        %{
          slug: "openagents-button",
          title: "Button",
          icon: "cube",
          source: "OpenAgentsWeb.UI.button/1",
          summary: "Eight variants, four sizes, navigation, and a danger tone."
        },
        %{
          slug: "openagents-card",
          title: "Card",
          icon: "square-image",
          source: "OpenAgentsWeb.UI.card/1",
          summary: "Content container with an optional corner frame and danger variant."
        },
        %{
          slug: "openagents-copy-button",
          title: "Copy button",
          icon: "copy",
          source: "OpenAgentsWeb.UI.copy_button/1",
          summary: "Copies text and confirms it, so the reader is not left guessing."
        },
        %{
          slug: "openagents-diff-file",
          title: "Diff",
          icon: "code",
          source: "OpenAgentsWeb.UI.diff_file/1",
          summary: "One file's diff: hunks, both line numbers, addressable lines."
        },
        %{
          slug: "openagents-empty",
          title: "Empty state",
          icon: "circle",
          source: "OpenAgentsWeb.UI.empty/1",
          summary: "Placeholder for lists and panels with nothing to show."
        },
        %{
          slug: "openagents-event-header",
          title: "Event header",
          icon: "info",
          source: "OpenAgentsWeb.UI.event_header/1",
          summary: "Titled event row with status, timestamp, and chip slot."
        },
        %{
          slug: "openagents-field",
          title: "Field",
          icon: "file-document",
          source: "OpenAgentsWeb.UI.field/1",
          summary: "Wrapper that stacks a label, control, and validation message."
        },
        %{
          slug: "openagents-file-table",
          title: "File table",
          icon: "folder",
          source: "OpenAgentsWeb.UI.file_table/1",
          summary: "A repository tree: ref bar, latest commit, and entries."
        },
        %{
          slug: "openagents-frame",
          title: "Frame",
          icon: "grid",
          source: "OpenAgentsWeb.UI.frame/1",
          summary: "Corner-bracket decoration around arbitrary content."
        },
        %{
          slug: "openagents-github-login",
          title: "GitHub login",
          icon: "brand-github",
          source: "OpenAgentsWeb.UI.github_login/1",
          summary: "Sign-in form that goes pending on submit."
        },
        %{
          slug: "openagents-header",
          title: "Header",
          icon: "book",
          source: "OpenAgentsWeb.UI.header/1",
          summary: "Page heading with supporting text and an action slot."
        },
        %{
          slug: "openagents-icon",
          title: "Icon",
          icon: "sparkle",
          source: "OpenAgentsWeb.UI.icon/1",
          summary: "Apps SDK glyph with an optional accessible label."
        },
        %{
          slug: "openagents-input",
          title: "Input",
          icon: "square-text",
          source: "OpenAgentsWeb.UI.input/1",
          summary: "Form-aware text, select, textarea, checkbox, and raw inputs."
        },
        %{
          slug: "openagents-item",
          title: "Item",
          icon: "dot",
          source: "OpenAgentsWeb.UI.item/1",
          summary: "Status, label, and detail row for activity lists."
        },
        %{
          slug: "openagents-kbd",
          title: "Keyboard key",
          icon: "keyboard",
          source: "OpenAgentsWeb.UI.kbd/1",
          summary: "Rendered keycap for shortcut documentation."
        },
        %{
          slug: "openagents-label",
          title: "Label",
          icon: "tag",
          source: "OpenAgentsWeb.UI.label/1",
          summary: "Form label bound to a control by ID."
        },
        %{
          slug: "openagents-list",
          title: "List",
          icon: "file-document",
          source: "OpenAgentsWeb.UI.list/1",
          summary: "Title and description pairs."
        },
        %{
          slug: "openagents-menu",
          title: "Menu",
          icon: "menu",
          source: "OpenAgentsWeb.UI.menu/1",
          summary: "Native popover menu surface used by the account control."
        },
        %{
          slug: "openagents-repo-about",
          title: "Repo about",
          icon: "info",
          source: "OpenAgentsWeb.UI.repo_about/1",
          summary: "The rail beside a repository: description, licence, languages."
        },
        %{
          slug: "openagents-repo-tabs",
          title: "Repo tabs",
          icon: "category",
          source: "OpenAgentsWeb.UI.repo_tabs/1",
          summary: "A repository's sections as links, the current one marked by aria-current."
        },
        %{
          slug: "openagents-repo-view",
          title: "Repository view",
          icon: "folders",
          source: "OpenAgentsWeb.UI.repo_view/1",
          summary: "The whole repository home: identity, sections, tree, and rail in one frame."
        },
        %{
          slug: "openagents-status-indicator",
          title: "Status indicator",
          icon: "check-circle",
          source: "OpenAgentsWeb.UI.status_indicator/1",
          summary: "Labeled state dot, optionally decorative."
        },
        %{
          slug: "openagents-table",
          title: "Table",
          icon: "table-cells-filled",
          source: "OpenAgentsWeb.UI.table/1",
          summary: "Responsive rows with regular-list and LiveView stream support."
        },
        %{
          slug: "openagents-text-button",
          title: "Text button",
          icon: "text",
          source: "OpenAgentsWeb.UI.text_button/1",
          summary: "Borderless action for inline and secondary affordances."
        },
        %{
          slug: "openagents-textarea",
          title: "Textarea",
          icon: "text",
          source: "OpenAgentsWeb.UI.textarea/1",
          summary: "Unwrapped multiline text primitive."
        }
      ]
    },
    %{
      title: "Layout",
      items: [
        %{
          slug: "sidebar-brand",
          title: "Sidebar brand",
          icon: "book",
          source: "OpenAgentsWeb.Layouts.sidebar_brand/1",
          summary: "Wordmark and section name as two separate destinations."
        },
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
      title: "Landing",
      items: [
        %{
          slug: "sidebar-footer",
          title: "Sidebar footer",
          icon: "stack",
          source: "OpenAgentsWeb.Layouts.sidebar_footer/1",
          summary: "Secondary destinations, gated by environment and role."
        },
        %{
          slug: "landing-section",
          title: "Section",
          icon: "stack",
          source: "OpenAgentsWeb.UI.Landing.section/1",
          summary: "Page band: rhythm, measure, and a closing hairline."
        },
        %{
          slug: "landing-hero",
          title: "Hero",
          icon: "sparkle",
          source: "OpenAgentsWeb.UI.Landing.hero/1",
          summary: "Eyebrow, headline, prose, actions, and a lit figure."
        },
        %{
          slug: "landing-glow",
          title: "Glow",
          icon: "sun",
          source: "OpenAgentsWeb.UI.Landing.glow/1",
          summary: "Two-ellipse radial lift, in five positions."
        },
        %{
          slug: "landing-beam",
          title: "Beam",
          icon: "bolt",
          source: "OpenAgentsWeb.UI.Landing.beam/1",
          summary: "Radial bloom behind a single element."
        },
        %{
          slug: "landing-mockup",
          title: "Mockup",
          icon: "desktop",
          source: "OpenAgentsWeb.UI.Landing.mockup/1",
          summary: "Framed figure in a window or phone shape."
        },
        %{
          slug: "landing-feature-grid",
          title: "Feature grid",
          icon: "grid",
          source: "OpenAgentsWeb.UI.Landing.feature_grid/1",
          summary: "Two-to-four column grid of capability statements."
        },
        %{
          slug: "landing-stats",
          title: "Stats",
          icon: "chart",
          source: "OpenAgentsWeb.UI.Landing.stats/1",
          summary: "A row of figures with labels and captions."
        },
        %{
          slug: "landing-pricing-column",
          title: "Pricing column",
          icon: "tag",
          source: "OpenAgentsWeb.UI.Landing.pricing_column/1",
          summary: "One plan, with a lit top rule and a featured state."
        },
        %{
          slug: "landing-faq",
          title: "FAQ",
          icon: "info",
          source: "OpenAgentsWeb.UI.Landing.faq/1",
          summary: "Questions on native disclosure, no JavaScript."
        },
        %{
          slug: "landing-cta",
          title: "Call to action",
          icon: "arrow-right",
          source: "OpenAgentsWeb.UI.Landing.cta/1",
          summary: "The closing ask, over a glow that rises on hover."
        },
        %{
          slug: "landing-logo-wall",
          title: "Logo wall",
          icon: "star",
          source: "OpenAgentsWeb.UI.Landing.logo_wall/1",
          summary: "A row of names at one weight."
        },
        %{
          slug: "landing-footer",
          title: "Landing footer",
          icon: "stack",
          source: "OpenAgentsWeb.UI.Landing.landing_footer/1",
          summary: "Mark, tagline, and columns of links."
        },
        %{
          slug: "landing-layout-lines",
          title: "Layout lines",
          icon: "grid",
          source: "OpenAgentsWeb.UI.Landing.layout_lines/1",
          summary: "Dashed rules marking the content column."
        }
      ]
    },
    %{
      title: "Issues",
      items: [
        %{
          slug: "issue-status",
          title: "Issue status",
          icon: "circle",
          source: "OpenAgentsWeb.UI.Circle.issue_status/1",
          summary: "Six category shapes, one of them a filled arc read from a number."
        },
        %{
          slug: "issue-state",
          title: "Issue state",
          icon: "check-circle",
          source: "OpenAgentsWeb.UI.Circle.issue_state/1",
          summary: "GitHub's two states and the one close reason that reads differently."
        },
        %{
          slug: "issue-detail",
          title: "Issue detail",
          icon: "document",
          source: "OpenAgentsWeb.UI.Circle.issue_detail/1",
          summary: "Heading, the work, and a rail that moves rather than hiding."
        },
        %{
          slug: "properties-panel",
          title: "Properties panel",
          icon: "settings-slider",
          source: "OpenAgentsWeb.UI.Circle.properties_panel/1",
          summary: "Labelled groups of editable properties, present even when empty."
        },
        %{
          slug: "timeline",
          title: "Timeline",
          icon: "history",
          source: "OpenAgentsWeb.UI.Circle.timeline/1",
          summary: "Everything that happened to an issue, threaded oldest first."
        },
        %{
          slug: "timeline-event",
          title: "Timeline event",
          icon: "dot",
          source: "OpenAgentsWeb.UI.Circle.timeline_event/1",
          summary: "One fact about an issue, deliberately quieter than a comment."
        },
        %{
          slug: "timeline-comment",
          title: "Timeline comment",
          icon: "comment",
          source: "OpenAgentsWeb.UI.Circle.timeline_comment/1",
          summary: "Authored prose in a card, so the thread stays scannable."
        },
        %{
          slug: "comment-composer",
          title: "Comment composer",
          icon: "chat-compose",
          source: "OpenAgentsWeb.UI.Circle.comment_composer/1",
          summary: "A well that is the control, rather than a labelled box and a loose button."
        },
        %{
          slug: "field-menu",
          title: "Field menu",
          icon: "dropdown",
          source: "OpenAgentsWeb.UI.Circle.field_menu/1",
          summary: "A property you can change, as a native popover over its own value."
        },
        %{
          slug: "field-menu-item",
          title: "Field menu item",
          icon: "check",
          source: "OpenAgentsWeb.UI.Circle.field_menu_item/1",
          summary: "One option: a toggle in a set, or one choice out of several."
        },
        %{
          slug: "issue-priority",
          title: "Issue priority",
          icon: "bar-chart",
          source: "OpenAgentsWeb.UI.Circle.issue_priority/1",
          summary: "Four ascending bars, plus an alarm that breaks the ramp on purpose."
        },
        %{
          slug: "issue-label",
          title: "Issue label",
          icon: "tag",
          source: "OpenAgentsWeb.UI.Circle.issue_label/1",
          summary: "A dot and a word, toned from the ladder rather than a per-label colour."
        },
        %{
          slug: "assignee",
          title: "Assignee",
          icon: "user",
          source: "OpenAgentsWeb.UI.Circle.assignee/1",
          summary: "Who owns an issue, including the drawn state for nobody."
        },
        %{
          slug: "assignee-stack",
          title: "Assignee stack",
          icon: "group",
          source: "OpenAgentsWeb.UI.Circle.assignee_stack/1",
          summary: "Overlapping faces that separate on hover, with a count for the rest."
        },
        %{
          slug: "issue-row",
          title: "Issue row",
          icon: "menu",
          source: "OpenAgentsWeb.UI.Circle.issue_row/1",
          summary: "The shape a tracker is mostly made of: scan column, title, trailing facts."
        },
        %{
          slug: "issue-card",
          title: "Issue card",
          icon: "square-text",
          source: "OpenAgentsWeb.UI.Circle.issue_card/1",
          summary: "The same issue with width and no neighbours, for a board column."
        },
        %{
          slug: "issue-group",
          title: "Issue group",
          icon: "stack",
          source: "OpenAgentsWeb.UI.Circle.issue_group/1",
          summary: "A named run of issues under a sticky header washed by its own status."
        },
        %{
          slug: "issue-board",
          title: "Issue board",
          icon: "grid",
          source: "OpenAgentsWeb.UI.Circle.issue_board/1",
          summary: "Columns side by side, each scrolling on its own."
        },
        %{
          slug: "filter-chip",
          title: "Filter chip",
          icon: "filter",
          source: "OpenAgentsWeb.UI.Circle.filter_chip/1",
          summary: "One filter read as subject, operator, value, each its own segment."
        },
        %{
          slug: "filter-bar",
          title: "Filter bar",
          icon: "filter",
          source: "OpenAgentsWeb.UI.Circle.filter_bar/1",
          summary: "The applied filters, somewhere to add one, and a way to drop them all."
        },
        %{
          slug: "view-tabs",
          title: "View tabs",
          icon: "category",
          source: "OpenAgentsWeb.UI.Circle.view_tabs/1",
          summary: "Saved views as pills; the current one carries aria-current, not just colour."
        },
        %{
          slug: "issue-toolbar",
          title: "Issue toolbar",
          icon: "settings-slider",
          source: "OpenAgentsWeb.UI.Circle.issue_toolbar/1",
          summary: "What you are looking at on the left, what you can do to it on the right."
        },
        %{
          slug: "command-palette",
          title: "Command palette",
          icon: "search",
          source: "OpenAgentsWeb.UI.Circle.command_palette/1",
          summary: "A native dialog on ⌘K, filtered as you type."
        },
        %{
          slug: "command-group",
          title: "Command group",
          icon: "folders",
          source: "OpenAgentsWeb.UI.Circle.command_group/1",
          summary: "A titled run of commands that hides itself when filtering empties it."
        },
        %{
          slug: "command-item",
          title: "Command item",
          icon: "keyboard-shortcut",
          source: "OpenAgentsWeb.UI.Circle.command_item/1",
          summary: "A glyph, a name, and the keys that reach it without the palette."
        },
        %{
          slug: "project-row",
          title: "Project row",
          icon: "cube",
          source: "OpenAgentsWeb.UI.Circle.project_row/1",
          summary: "Name on the left, everything measurable in columns that line up."
        },
        %{
          slug: "team-row",
          title: "Team row",
          icon: "members",
          source: "OpenAgentsWeb.UI.Circle.team_row/1",
          summary: "Identity, membership, and what a team owns."
        },
        %{
          slug: "member-row",
          title: "Member row",
          icon: "avatar-profile",
          source: "OpenAgentsWeb.UI.Circle.member_row/1",
          summary: "Display name and handle together, with role, tenure, and teams."
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
      # og_tags renders head metadata for crawlers, not a visible surface, so
      # it has no demoable page.
      OpenAgentsWeb.Layouts => [:app, :flash_group, :og_tags],
      # graph_defs/1 emits marker definitions into a parent graph surface; it
      # renders nothing on its own, so it has no demoable page. graph_surface/1
      # is the host element and is demoed through the components that use it.
      OpenAgentsWeb.UI.Graph => [:graph_defs, :graph_surface],
      OpenAgentsWeb.Components.RepoHeader => [],
      OpenAgentsWeb.UI.Landing => [],
      OpenAgentsWeb.UI.Circle => []
    }
  end
end
