defmodule OpenAgentsWeb.UI.CircleTest do
  @moduledoc """
  The parts of the issue surfaces a screenshot cannot check.

  Three failure modes are covered here because all three are invisible by eye:
  a state indicator that carries its meaning only in colour, an indicator that
  announces itself twice when its word is already on screen, and an arc whose
  fill silently stops tracking the number it is drawn from.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias OpenAgentsWeb.UI.Circle

  defp query(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.to_tree()
  end

  defp status(overrides) do
    render_component(
      &Circle.issue_status/1,
      Keyword.merge([category: :started, label: "In progress"], overrides)
    )
  end

  defp priority(level, show_label) do
    render_component(&Circle.issue_priority/1, level: level, show_label: show_label)
  end

  defp row(overrides) do
    render_component(
      &Circle.issue_row/1,
      Keyword.merge(
        [
          identifier: "OA-142",
          title: "A title",
          status_category: :started,
          status_label: "In progress",
          progress: 35,
          priority: :high
        ],
        overrides
      )
    )
  end

  defp chip(on_remove) do
    render_component(&Circle.filter_chip/1,
      subject: "Status",
      operator: "is",
      value: "Done",
      on_remove: on_remove
    )
  end

  describe "issue_status/1" do
    test "the arc is drawn from the percentage rather than from a fixed set" do
      for percent <- [0, 35, 100] do
        assert query(
                 status(progress: percent),
                 ~s{.issue-status__arc[style="--issue-arc: #{percent}"]}
               ) != []
      end
    end

    # A progress value is a count over a count, so it can arrive as anything.
    # The arc still has to be drawable: an absent or out-of-range value must
    # not produce a gradient stop the browser refuses.
    test "an absent or out-of-range percentage still draws" do
      for {given, drawn} <- [{nil, 0}, {-10, 0}, {140, 100}] do
        assert query(
                 status(progress: given),
                 ~s{.issue-status__arc[style="--issue-arc: #{drawn}"]}
               ) != []
      end
    end

    test "the glyph announces the state when no word is beside it" do
      assert query(status(category: :completed, label: "Done"), ~s{[aria-label="Done"]}) != []
    end

    test "the glyph goes quiet once the word is visible" do
      rendered = status(category: :completed, label: "Done", show_label: true)

      assert query(rendered, "[aria-label]") == []
      assert query(rendered, ~s{[aria-hidden="true"]}) != []
      assert rendered =~ "Done"
    end

    test "every category resolves to a shape" do
      for category <- [:triage, :backlog, :unstarted, :started, :completed, :canceled] do
        rendered = status(category: category, label: "Any", progress: 50)

        assert query(rendered, ~s{.issue-status[data-category="#{category}"]}) != []
        assert query(rendered, ".issue-status__arc, .issue-status__glyph") != []
      end
    end
  end

  describe "issue_priority/1" do
    test "the level is carried by an attribute, so it survives greyscale" do
      for level <- [:none, :low, :medium, :high] do
        assert query(priority(level, false), ~s{.issue-priority[data-level="#{level}"]}) != []
      end
    end

    test "urgent leaves the ramp and is drawn as its own mark" do
      assert query(priority(:urgent, false), ".issue-priority__bars") == []
      assert query(priority(:urgent, false), ".issue-priority__alarm") != []
    end

    test "the indicator names the level when no word is beside it" do
      assert query(priority(:high, false), ~s{[aria-label="High priority"]}) != []
      assert query(priority(:high, true), "[aria-label]") == []
    end
  end

  describe "assignee/1" do
    test "unassigned is drawn and named rather than left blank" do
      rendered = render_component(&Circle.assignee/1, [])

      assert query(rendered, ~s{.assignee__empty[aria-label="Unassigned"]}) != []
    end

    test "presence is decorative, because the row already names the person" do
      rendered =
        render_component(&Circle.assignee/1,
          name: "Mason Carter",
          presence: :online,
          show_name: true
        )

      assert query(rendered, ".assignee__presence[aria-label]") == []
      assert query(rendered, ~s{.assignee__presence[data-presence="online"]}) != []
    end
  end

  describe "assignee_stack/1" do
    test "the count says how many did not fit" do
      people = for n <- 1..8, do: %{name: "Person #{n}"}
      rendered = render_component(&Circle.assignee_stack/1, people: people, limit: 5)

      assert length(query(rendered, ".avatar")) == 5
      assert rendered =~ "+3"
    end

    test "a stack that fits carries no count" do
      rendered = render_component(&Circle.assignee_stack/1, people: [%{name: "Ada"}])

      assert query(rendered, ".assignee-stack__count") == []
    end
  end

  describe "issue_row/1" do
    test "the title is a link only when it has somewhere to go" do
      assert query(row(navigate: "/issues/1"), ~s{a.issue-row__title[href="/issues/1"]}) != []
      assert query(row(navigate: nil), "a.issue-row__title") == []
      assert query(row(navigate: nil), "span.issue-row__title") != []
    end

    test "an unassigned row still draws the assignee position" do
      assert query(row(assignee: nil), ".assignee__empty") != []
    end
  end

  describe "filter_chip/1" do
    test "the remove control names the filter it drops" do
      assert query(
               chip(Phoenix.LiveView.JS.hide()),
               ~s{button[aria-label="Remove the Status filter"]}
             ) != []
    end

    test "a chip with no command offers no dead control" do
      assert query(chip(nil), "button") == []
    end
  end

  describe "view_tabs/1" do
    test "the current view is stated, not merely coloured" do
      rendered =
        render_component(&Circle.view_tabs/1,
          label: "Issue views",
          tab: [
            %{__slot__: :tab, label: "Active", navigate: "/a", selected: true, inner_block: nil},
            %{__slot__: :tab, label: "Backlog", navigate: "/b", inner_block: nil}
          ]
        )

      assert query(rendered, ~s{a[aria-current="page"][href="/a"]}) != []
      assert query(rendered, ~s{a[href="/b"][aria-current]}) == []
    end
  end

  describe "command_item/1" do
    test "the filter key is the label, folded so typing matches it" do
      rendered =
        render_component(&Circle.command_item/1, label: "Copy Issue URL", keys: ["⌘", "."])

      assert query(rendered, ~s{[data-command-label="copy issue url"]}) != []
      assert length(query(rendered, "kbd")) == 2
    end
  end

  describe "issue_state/1" do
    # The ruling in docs/2026-08-20-linear-design-github-shape.md: GitHub has
    # two states and we have what GitHub has. This is the one place that maps
    # them, so a page cannot quietly disagree with another about what closed
    # looks like.
    test "GitHub's two states, plus the one close reason that reads differently" do
      for {state, reason, category, label} <- [
            {"open", nil, "unstarted", "Open"},
            {"closed", "completed", "completed", "Closed"},
            {"closed", nil, "completed", "Closed"},
            {"closed", "not_planned", "canceled", "Closed as not planned"},
            {"closed", "duplicate", "canceled", "Closed as duplicate"}
          ] do
        rendered = render_component(&Circle.issue_state/1, state: state, reason: reason)

        assert query(rendered, ~s{.issue-status[data-category="#{category}"]}) != [],
               "#{state}/#{reason || "nil"} did not take the #{category} shape"

        assert query(rendered, ~s{[aria-label="#{label}"]}) != []
      end
    end

    test "a duplicate is cancelled rather than completed" do
      # It is the one reason where GitHub's own glyph differs from a plain
      # close, and reading it as completed would claim work that never happened.
      completed = render_component(&Circle.issue_state/1, state: "closed", reason: "completed")
      duplicate = render_component(&Circle.issue_state/1, state: "closed", reason: "duplicate")

      assert query(completed, ~s{[data-category="completed"]}) != []
      assert query(duplicate, ~s{[data-category="canceled"]}) != []
    end
  end

  describe "field_menu/1" do
    test "the trigger names itself, because what it shows is a picture" do
      rendered =
        render_component(&Circle.field_menu/1,
          id: "state-menu",
          label: "Change the state",
          trigger: [%{__slot__: :trigger, inner_block: fn _, _ -> "glyph" end}],
          inner_block: [%{__slot__: :inner_block, inner_block: fn _, _ -> "options" end}]
        )

      assert query(rendered, ~s{button[aria-label="Change the state"]}) != []
    end

    test "the trigger points at the panel it opens, and the panel exists" do
      rendered =
        render_component(&Circle.field_menu/1,
          id: "state-menu",
          label: "Change the state",
          trigger: [%{__slot__: :trigger, inner_block: fn _, _ -> "glyph" end}],
          inner_block: [%{__slot__: :inner_block, inner_block: fn _, _ -> "options" end}]
        )

      assert query(rendered, ~s{button[popovertarget="state-menu"]}) != []
      assert query(rendered, ~s{[popover]#state-menu}) != []
    end
  end

  describe "field_menu_item/1" do
    # A set and a single choice claim different things, and a screen reader
    # cannot tell them apart from a tick.
    test "a toggle presses, a choice becomes current" do
      toggled = render_component(&Circle.field_menu_item/1, label: "Bug", selected: true)
      unset = render_component(&Circle.field_menu_item/1, label: "Bug")

      assert query(toggled, ~s{button[aria-pressed="true"]}) != []
      assert query(unset, ~s{button[aria-pressed="false"]}) != []

      chosen =
        render_component(&Circle.field_menu_item/1,
          label: "Closed",
          mode: :choice,
          selected: true
        )

      assert query(chosen, ~s{button[aria-current="true"]}) != []
      assert query(chosen, "button[aria-pressed]") == []
    end

    test "dismissing the panel is opt-in, because a set stays open" do
      # Ticking three labels in a row only works if the menu survives the first
      # tick, so `closes` is asked for rather than assumed.
      staying = render_component(&Circle.field_menu_item/1, label: "Bug")
      closing = render_component(&Circle.field_menu_item/1, label: "Open", closes: "state-menu")

      assert query(staying, "button[popovertarget]") == []

      assert query(closing, ~s{button[popovertarget="state-menu"][popovertargetaction="hide"]}) !=
               []
    end
  end

  describe "timeline_event/1" do
    test "an event with no known actor states the fact without inventing a subject" do
      rendered = render_component(&Circle.timeline_event/1, text: "closed this as completed")

      assert query(rendered, ".timeline-event__actor") == []
      assert rendered =~ "closed this as completed"
    end

    test "the glyph is decorative, because the sentence beside it says the same thing" do
      rendered =
        render_component(&Circle.timeline_event/1, actor: "ada", text: "opened this issue")

      assert query(rendered, ".timeline-event__glyph[aria-hidden]") != []
      assert query(rendered, ".timeline-event svg[aria-label]") == []
    end
  end

  describe "issue_row/1 controls" do
    # The row stays presentational; a caller with somewhere to send a change
    # replaces the cell. The static rendering has to get out of the way when it
    # does, or the row shows the value twice.
    test "a state slot replaces the static glyph rather than joining it" do
      rendered =
        render_component(&Circle.issue_row/1,
          identifier: "#1",
          title: "A title",
          status_category: :unstarted,
          status_label: "Open",
          state: [%{__slot__: :state, inner_block: fn _, _ -> "CONTROL" end}]
        )

      assert rendered =~ "CONTROL"
      assert query(rendered, ".issue-row__scan .issue-status") == []
    end

    test "an assignee slot replaces the static face" do
      rendered =
        render_component(&Circle.issue_row/1,
          identifier: "#1",
          title: "A title",
          status_category: :unstarted,
          status_label: "Open",
          people: [%{__slot__: :people, inner_block: fn _, _ -> "CONTROL" end}]
        )

      assert rendered =~ "CONTROL"
      assert query(rendered, ".assignee") == []
    end

    test "with no slots the row renders exactly what it did before" do
      rendered =
        render_component(&Circle.issue_row/1,
          identifier: "#1",
          title: "A title",
          status_category: :unstarted,
          status_label: "Open"
        )

      assert query(rendered, ".issue-row__scan .issue-status") != []
      assert query(rendered, ".assignee") != []
    end
  end

  describe "the stylesheet" do
    setup do
      section =
        "assets/css/openagents.css"
        |> File.read!()
        |> String.split("/* ── Issues ──")
        |> List.last()

      %{section: section}
    end

    # The whole point of the port was to avoid a second palette. A literal hex
    # value in this section would be one of Circle's thirteen status colours
    # arriving by the back door.
    test "the Issues section paints only with tokens", %{section: section} do
      literals =
        ~r/(?<![-\w])#[0-9a-fA-F]{3,8}\b/
        |> Regex.scan(section)
        |> List.flatten()

      assert literals == [], """
      The Issues section names colours directly instead of resolving to a
      token: #{Enum.join(literals, ", ")}

      There are no permitted literals. The modal scrim, which is the one value
      that cannot come from `--ink-void` (that token flips to near-white in
      light mode and a white scrim hides nothing), has its own `--scrim` token.
      """
    end

    test "each category that departs from the default grey has a tint", %{section: section} do
      for category <- ~w(triage backlog started completed canceled) do
        assert section =~ ~s{[data-category="#{category}"]},
               "no tint rule for the #{category} category"
      end
    end
  end
end
