defmodule OpenAgentsWeb.ComponentCatalog do
  @moduledoc """
  The executable inventory for the OpenAgents component system.

  The sidebar and demo pages both read this list. Tests require every public
  function component in `OpenAgentsWeb.UI` and the documented layout modules to
  appear here, so the catalog cannot drift behind the supported API.

  `OpenAgentsWeb.UI` is the general product component module: it combines the
  vendored Basecoat structure with the OpenAgents style pack, and new reusable
  primitives start there. Surface modules beside it — the SCV graph, the landing
  page, the issue tracker, and the four AI Elements ports under
  `OpenAgentsWeb.AI` — hold composition that is specific to one surface. Icon
  demos use the preferred vendored Apps SDK set; see `docs/ICONS.md` for the
  exceptional Heroicons fallback policy and current fallback inventory.

  The `OpenAgentsWeb.AI` modules are catalogued one entry per family rather than
  one per function. `reasoning/1` and the trigger and body it wraps are one
  entry, because they are one thing a caller reaches for, and the parts are only
  legible inside the composition. The parts are excluded in
  `documented_modules/0` with the family that demonstrates them.
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
          slug: "openagents-stack-map",
          title: "Stack map",
          icon: "stack",
          source: "OpenAgentsWeb.UI.stack_map/1",
          summary: "One pull request stack, layers top-first, down to the trunk it targets."
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
        },
        %{
          slug: "openagents-time-ago",
          title: "Time ago",
          icon: "clock",
          source: "OpenAgentsWeb.UI.time_ago/1",
          summary: "One relative stamp, with the exact moment in title and datetime."
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
    },
    %{
      title: "AI conversation",
      items: [
        %{
          slug: "ai-conversation",
          title: "Conversation",
          icon: "chat",
          source: "OpenAgentsWeb.AI.Conversation.conversation/1",
          summary:
            "The transcript scroller, pinned to the newest turn until the reader leaves it."
        },
        %{
          slug: "ai-message",
          title: "Message",
          icon: "comment",
          source: "OpenAgentsWeb.AI.Conversation.message/1",
          summary: "One turn: a face, a Markdown body, and the controls under it."
        },
        %{
          slug: "ai-shimmer",
          title: "Shimmer",
          icon: "sparkle",
          source: "OpenAgentsWeb.AI.Conversation.shimmer/1",
          summary: "A highlight travelling through a line, so waiting reads as work."
        },
        %{
          slug: "ai-suggestions",
          title: "Suggestions",
          icon: "lightbulb",
          source: "OpenAgentsWeb.AI.Conversation.suggestions/1",
          summary:
            "Openers the reader can send unedited, on a row that scrolls rather than wraps."
        },
        %{
          slug: "ai-toolbar",
          title: "Conversation toolbar",
          icon: "settings-slider",
          source: "OpenAgentsWeb.AI.Conversation.toolbar/1",
          summary: "The bar that floats over a transcript, named so the keyboard can reach it."
        },
        %{
          slug: "ai-controls",
          title: "Conversation controls",
          icon: "tools",
          source: "OpenAgentsWeb.AI.Conversation.controls/1",
          summary: "Grouped actions that stay legible over whatever they sit on."
        },
        %{
          slug: "ai-persona",
          title: "Persona",
          icon: "agent",
          source: "OpenAgentsWeb.AI.Conversation.persona/1",
          summary: "Who is answering, and what they are doing right now."
        }
      ]
    },
    %{
      title: "AI reasoning",
      items: [
        %{
          slug: "ai-reasoning",
          title: "Reasoning",
          icon: "brain",
          source: "OpenAgentsWeb.AI.Reasoning.reasoning/1",
          summary:
            "Model thinking on native disclosure: open while it streams, closed once it lands."
        },
        %{
          slug: "ai-chain-of-thought",
          title: "Chain of thought",
          icon: "nodes",
          source: "OpenAgentsWeb.AI.Reasoning.chain_of_thought/1",
          summary: "Steps down a rail, each one complete, active, or still pending."
        },
        %{
          slug: "ai-tool",
          title: "Tool call",
          icon: "settings-wrench",
          source: "OpenAgentsWeb.AI.Reasoning.tool/1",
          summary: "One call and its states, from streaming input to a denied result."
        },
        %{
          slug: "ai-task",
          title: "Task",
          icon: "tasks",
          source: "OpenAgentsWeb.AI.Reasoning.task/1",
          summary: "A piece of finished work and the files it touched."
        },
        %{
          slug: "ai-plan",
          title: "Plan",
          icon: "notebook-check",
          source: "OpenAgentsWeb.AI.Reasoning.plan/1",
          summary: "Intended steps on a card whose body collapses while its footer stays."
        },
        %{
          slug: "ai-checkpoint",
          title: "Checkpoint",
          icon: "flag",
          source: "OpenAgentsWeb.AI.Reasoning.checkpoint/1",
          summary: "A point the run can be restored to, marked in the transcript."
        }
      ]
    },
    %{
      title: "AI composer",
      items: [
        %{
          slug: "ai-prompt-input",
          title: "Prompt input",
          icon: "chat-compose",
          source: "OpenAgentsWeb.AI.PromptInput.prompt_input/1",
          summary: "The composer: a Phoenix form, a growing textarea, and a toolbar under it."
        },
        %{
          slug: "ai-prompt-input-action-menu",
          title: "Composer action menu",
          icon: "plus-circle",
          source: "OpenAgentsWeb.AI.PromptInput.prompt_input_action_menu/1",
          summary: "Attach and capture actions on a native popover, with no script."
        },
        %{
          slug: "ai-prompt-input-model-select",
          title: "Composer model select",
          icon: "dropdown",
          source: "OpenAgentsWeb.AI.PromptInput.prompt_input_model_select/1",
          summary: "A real select for the model, so the composer form carries the choice."
        },
        %{
          slug: "ai-attachments",
          title: "Attachments",
          icon: "paperclip",
          source: "OpenAgentsWeb.AI.PromptInput.attachments/1",
          summary: "Staged files as a grid, an inline row, or a list, each with an empty state."
        },
        %{
          slug: "ai-speech-input",
          title: "Speech input",
          icon: "mic",
          source: "OpenAgentsWeb.AI.PromptInput.speech_input/1",
          summary: "Push-to-talk whose whole visual state is CSS keyed off data attributes."
        },
        %{
          slug: "ai-mic-selector",
          title: "Microphone selector",
          icon: "voice",
          source: "OpenAgentsWeb.AI.PromptInput.mic_selector/1",
          summary: "Which device is listening, filled in from the browser after mount."
        },
        %{
          slug: "ai-model-selector",
          title: "Model selector",
          icon: "search",
          source: "OpenAgentsWeb.AI.PromptInput.model_selector/1",
          summary: "A searchable model palette on a popover, filtered in the browser."
        },
        %{
          slug: "ai-queue",
          title: "Queue",
          icon: "stack",
          source: "OpenAgentsWeb.AI.PromptInput.queue/1",
          summary: "Turns waiting to be sent, in sections that collapse."
        }
      ]
    },
    %{
      title: "AI evidence",
      items: [
        %{
          slug: "ai-code-block",
          title: "Code block",
          icon: "square-code",
          source: "OpenAgentsWeb.AI.Evidence.code_block/1",
          summary: "Filename, language, actions, and line numbers that cannot be selected."
        },
        %{
          slug: "ai-snippet",
          title: "Snippet",
          icon: "clipboard-copy",
          source: "OpenAgentsWeb.AI.Evidence.snippet/1",
          summary: "One command in a read-only field, beside the control that copies it."
        },
        %{
          slug: "ai-terminal",
          title: "Terminal",
          icon: "terminal",
          source: "OpenAgentsWeb.AI.Evidence.terminal/1",
          summary: "Command output on a fixed dark ground, with a caret while it runs."
        },
        %{
          slug: "ai-sources",
          title: "Sources",
          icon: "book-open",
          source: "OpenAgentsWeb.AI.Evidence.sources/1",
          summary: "What an answer was drawn from: counted first, listed on request."
        },
        %{
          slug: "ai-inline-citation",
          title: "Inline citation",
          icon: "quote",
          source: "OpenAgentsWeb.AI.Evidence.inline_citation/1",
          summary: "A hostname chip mid-sentence that opens onto the sources behind it."
        },
        %{
          slug: "ai-context",
          title: "Context meter",
          icon: "usage",
          source: "OpenAgentsWeb.AI.Evidence.context/1",
          summary: "How much of the window a turn spent, stated as a number and as an arc."
        },
        %{
          slug: "ai-artifact",
          title: "Artifact",
          icon: "document",
          source: "OpenAgentsWeb.AI.Evidence.artifact/1",
          summary: "Something the model produced, framed with the actions that act on it."
        },
        %{
          slug: "ai-confirmation",
          title: "Confirmation",
          icon: "shield-check",
          source: "OpenAgentsWeb.AI.Evidence.confirmation/1",
          summary: "An ask before an irreversible step, which keeps showing its answer."
        },
        %{
          slug: "ai-question",
          title: "Question",
          icon: "question-mark-circle",
          source: "OpenAgentsWeb.AI.Evidence.question/1",
          summary: "Choices as real radios or checkboxes, plus room to say something else."
        },
        %{
          slug: "ai-image",
          title: "Image",
          icon: "file-image",
          source: "OpenAgentsWeb.AI.Evidence.image/1",
          summary: "A generated image in a frame that cannot push the page around."
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
      OpenAgentsWeb.UI.Circle => [],
      # The AI Elements ports are catalogued one entry per family, not one per
      # function. A family is a head a caller reaches for and the parts it is
      # composed from; the parts are excluded here and demoed inside the head's
      # page, where the composition is the thing worth reading.
      OpenAgentsWeb.AI.Conversation => [
        # The scroller's own parts: the column of turns, the placeholder it
        # shows when there are none, and the pinned control. All three are
        # demoed through `conversation/1`.
        :conversation_content,
        :conversation_empty_state,
        :conversation_scroll_button,
        # A turn is assembled from these four in the order the caller chooses,
        # so they are demoed through `message/1`.
        :message_content,
        :message_avatar,
        :message_actions,
        :message_action,
        # One opener out of the row; demoed through `suggestions/1`.
        :suggestion
      ],
      OpenAgentsWeb.AI.Reasoning => [
        # The disclosure summary and the streamed body; demoed through
        # `reasoning/1`, which is where the open and closed states read.
        :reasoning_trigger,
        :reasoning_content,
        # The header, body, steps, search results, and figures of a chain;
        # demoed through `chain_of_thought/1`.
        :chain_of_thought_header,
        :chain_of_thought_content,
        :chain_of_thought_step,
        :chain_of_thought_search_results,
        :chain_of_thought_search_result,
        :chain_of_thought_image,
        # A call's header, state badge, body, arguments, and result. The state
        # badge carries the taxonomy, so all seven states are demoed through
        # `tool/1` rather than on a page of their own.
        :tool_header,
        :tool_status_badge,
        :tool_content,
        :tool_input,
        :tool_output,
        # The summary, body, entries, and file chips of one task; demoed
        # through `task/1`.
        :task_trigger,
        :task_content,
        :task_item,
        :task_item_file,
        # A plan's name, prose, actions, and disclosure control. `plan/1` takes
        # slots, so these only make sense inside it and are demoed there.
        :plan_title,
        :plan_description,
        :plan_action,
        :plan_trigger,
        # The glyph and the restore control inside a checkpoint; demoed through
        # `checkpoint/1`.
        :checkpoint_icon,
        :checkpoint_trigger
      ],
      OpenAgentsWeb.AI.PromptInput => [
        # The composer's shell: the input group, the textarea bound to the
        # form field, the two bands around it, and the toolbar that holds the
        # tools and the submit control. All demoed through `prompt_input/1`,
        # which is the only place their geometry is legible.
        :prompt_input_body,
        :prompt_input_textarea,
        :prompt_input_header,
        :prompt_input_footer,
        :prompt_input_toolbar,
        :prompt_input_tools,
        :prompt_input_button,
        :prompt_input_submit,
        # The popover, its list, its rows, and the two actions that ship with
        # it; demoed through `prompt_input_action_menu/1`.
        :prompt_input_action_menu_trigger,
        :prompt_input_action_menu_content,
        :prompt_input_action_menu_item,
        :prompt_input_action_add_attachments,
        :prompt_input_action_add_screenshot,
        # One option in the composer's model select; demoed through
        # `prompt_input_model_select/1`.
        :prompt_input_model_select_item,
        # One staged file and its parts. The three layout variants are what
        # distinguish them, so they are demoed together through
        # `attachments/1`.
        :attachment,
        :attachment_preview,
        :attachment_info,
        :attachment_remove,
        :attachment_empty,
        # One device in the microphone list; demoed through `mic_selector/1`.
        :mic_selector_item,
        # The trigger, the search field, and the list, groups, rows, and
        # trimmings of the model palette; demoed through `model_selector/1`,
        # where the filtering hook is what makes them worth looking at.
        :model_selector_trigger,
        :model_selector_input,
        :model_selector_list,
        :model_selector_empty,
        :model_selector_group,
        :model_selector_item,
        :model_selector_name,
        :model_selector_shortcut,
        :model_selector_separator,
        :model_selector_logo,
        :model_selector_logo_group,
        # A queue's sections, rows, and the attachments hanging off a row; all
        # demoed through `queue/1`.
        :queue_section,
        :queue_section_trigger,
        :queue_section_label,
        :queue_section_content,
        :queue_list,
        :queue_item,
        :queue_item_indicator,
        :queue_item_content,
        :queue_item_description,
        :queue_item_actions,
        :queue_item_action,
        :queue_item_attachment,
        :queue_item_image,
        :queue_item_file,
        :queue_empty
      ],
      OpenAgentsWeb.AI.Evidence => [
        # One line of terminal output; demoed through `terminal/1`, which owns
        # the ground it is legible against.
        :terminal_line,
        # One source in the list; demoed through `sources/1`.
        :source,
        # The contents of a citation's card; demoed through
        # `inline_citation/1`, since the card only exists inside it.
        :inline_citation_source,
        :inline_citation_quote,
        # A control in an artifact's header; demoed through `artifact/1`.
        :artifact_action,
        # The approve and deny controls; demoed through `confirmation/1`,
        # which is what decides whether they are still shown.
        :confirmation_action
      ]
    }
  end
end
