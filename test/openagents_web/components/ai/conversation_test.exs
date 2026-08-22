defmodule OpenAgentsWeb.AI.ConversationTest do
  @moduledoc """
  What the port has to keep true, and what a screenshot cannot check.

  Three things break silently. A conditional that renders both branches at once
  looks fine until a caller supplies the override and gets two headings. A
  Tailwind class that this product's tokens do not define renders as nothing —
  no error, no colour. And the difference between streaming and settled Markdown
  is one unclosed asterisk, which reads as a typo rather than as a bug.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias OpenAgentsWeb.AI.Conversation

  defp query(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.to_tree()
  end

  defp slot(content) do
    [%{__slot__: :inner_block, inner_block: fn _changed, _argument -> content end}]
  end

  describe "conversation/1" do
    test "announces arriving turns and scrolls in a box of its own" do
      html =
        render_component(&Conversation.conversation/1,
          id: "chat",
          inner_block: slot("a turn")
        )

      assert query(html, "#chat[role=log]") != []
      assert query(html, "#chat[phx-hook$='.StickToBottom']") != []
      assert query(html, "#chat-viewport[data-conversation-viewport]") != []
      assert html =~ "overflow-y-hidden"
      assert html =~ "overflow-y-auto"
    end

    test "carries its own scroll button, outside the scrolling viewport" do
      html =
        render_component(&Conversation.conversation/1,
          id: "chat",
          inner_block: slot("a turn")
        )

      assert query(html, "#chat > #chat-scroll-button") != []
      assert query(html, "#chat-viewport #chat-scroll-button") == []
    end

    test "omits the scroll button when the caller places its own" do
      html =
        render_component(&Conversation.conversation/1,
          id: "chat",
          scroll_button: false,
          inner_block: slot("a turn")
        )

      assert query(html, "#chat-scroll-button") == []
      assert query(html, "#chat-viewport") != []
    end
  end

  describe "conversation_content/1" do
    test "stacks turns in one column" do
      html =
        render_component(&Conversation.conversation_content/1,
          id: "turns",
          inner_block: slot("a turn")
        )

      assert query(html, "#turns") != []
      assert html =~ "flex flex-col gap-8 p-4"
    end
  end

  describe "conversation_empty_state/1" do
    test "explains what would appear here" do
      html = render_component(&Conversation.conversation_empty_state/1, id: "blank")

      assert [{"h3", _, ["No messages yet"]}] = query(html, "#blank h3")
      assert [{"p", _, ["Start a conversation to see messages here"]}] = query(html, "#blank p")
    end

    test "draws a glyph only when one is named" do
      without = render_component(&Conversation.conversation_empty_state/1, id: "blank")

      with_icon =
        render_component(&Conversation.conversation_empty_state/1, id: "blank", icon: "chat")

      assert query(without, "#blank svg") == []
      assert query(with_icon, "#blank svg") != []
    end

    test "a caller's own content replaces the heading rather than joining it" do
      html =
        render_component(&Conversation.conversation_empty_state/1,
          id: "blank",
          inner_block: slot("Nothing to see")
        )

      assert query(html, "#blank h3") == []
      assert query(html, "#blank p") == []
      assert html =~ "Nothing to see"
    end
  end

  describe "conversation_scroll_button/1" do
    test "starts hidden, names itself, and points down" do
      html = render_component(&Conversation.conversation_scroll_button/1, id: "back")

      assert [{"button", attributes, _}] = query(html, "#back")
      assert {"aria-label", "Scroll to the newest message"} in attributes
      assert {"data-conversation-scroll-button", "true"} in attributes
      assert {"data-variant", "outline"} in attributes

      class = Enum.find_value(attributes, fn {name, value} -> name == "class" && value end)
      assert class =~ "hidden"
      assert class =~ "rounded-full"

      assert query(html, "#back svg[data-icon=arrow-down]") != []
    end
  end

  describe "message/1" do
    test "a user turn carries the marker its content styles read" do
      html =
        render_component(&Conversation.message/1,
          id: "m1",
          from: "user",
          inner_block: slot("hello")
        )

      assert query(html, "#m1.is-user") != []
      assert query(html, "#m1.is-assistant") == []
      assert query(html, "#m1[data-from=user]") != []
    end

    test "every other role reads as the assistant side" do
      html =
        render_component(&Conversation.message/1,
          id: "m2",
          from: "assistant",
          inner_block: slot("hello")
        )

      assert query(html, "#m2.is-assistant") != []
      assert query(html, "#m2.is-user") == []
    end
  end

  describe "message_content/1" do
    test "the user bubble is painted by the group, not by the content" do
      html = render_component(&Conversation.message_content/1, id: "b", inner_block: slot("hi"))

      assert html =~ "group-[.is-user]:bg-secondary"
      assert html =~ "group-[.is-user]:rounded-lg"
      assert html =~ "group-[.is-assistant]:text-foreground"
    end

    test "renders Markdown rather than the characters that spell it" do
      html = render_component(&Conversation.message_content/1, id: "b", text: "**bold**")

      assert [{"strong", _, ["bold"]}] = query(html, "#b strong")
    end

    test "a settled turn keeps an unclosed marker literal" do
      html = render_component(&Conversation.message_content/1, id: "b", text: "**bold")

      assert query(html, "#b strong") == []
      assert html =~ "**bold"
    end

    test "a streaming turn closes what has not arrived yet" do
      html =
        render_component(&Conversation.message_content/1,
          id: "b",
          text: "**bold",
          streaming: true
        )

      assert [{"strong", _, ["bold"]}] = query(html, "#b strong")
    end
  end

  describe "message_avatar/1" do
    test "falls back to two letters of the name" do
      html = render_component(&Conversation.message_avatar/1, id: "who", name: "Sonnet")

      assert query(html, "#who img") == []
      assert html =~ "So"
      assert html =~ "size-8"
      assert html =~ "ring-border"
    end

    test "shows the image when there is one" do
      html =
        render_component(&Conversation.message_avatar/1,
          id: "who",
          name: "Sonnet",
          src: "/images/sonnet.png"
        )

      assert query(html, "#who img[src='/images/sonnet.png']") != []
    end
  end

  describe "message_actions/1 and message_action/1" do
    test "the row is a row" do
      html = render_component(&Conversation.message_actions/1, id: "acts", inner_block: slot("x"))

      assert html =~ "flex items-center gap-1"
    end

    test "an icon-only action names itself twice: once for a pointer, once aloud" do
      html =
        render_component(&Conversation.message_action/1,
          id: "copy",
          tooltip: "Copy",
          inner_block: slot("")
        )

      assert [{"button", attributes, _}] = query(html, "#copy")
      assert {"title", "Copy"} in attributes
      assert {"aria-label", "Copy"} in attributes
      assert {"data-variant", "ghost"} in attributes
      assert [{"span", _, ["Copy"]}] = query(html, "#copy span.sr-only")
    end

    test "an action with nothing to say carries no empty name" do
      html = render_component(&Conversation.message_action/1, id: "bare", inner_block: slot("x"))

      assert query(html, "#bare span.sr-only") == []
    end
  end

  describe "shimmer/1" do
    test "clips a moving band to the glyphs and scales it to the line" do
      html = render_component(&Conversation.shimmer/1, id: "s", text: "Thinking")

      assert [{"p", attributes, [text]}] = query(html, "#s")
      assert String.trim(text) == "Thinking"
      assert {"style", "--spread: 16px"} in attributes

      # The sweep is the `shimmer-sweep` keyframes in `openagents.css`, which
      # select on this marker. The stand-in `animate-pulse` is gone: two
      # animations on one element and the shorthand simply replaces the first,
      # so the band would have breathed instead of travelling.
      assert {"data-shimmer", "true"} in attributes

      class = Enum.find_value(attributes, fn {name, value} -> name == "class" && value end)
      assert class =~ "bg-clip-text"
      assert class =~ "text-transparent"
      refute class =~ "animate-pulse"
      assert class =~ "motion-reduce:animate-none"
      assert class =~ "var(--color-muted-foreground)"
    end

    test "takes the element the caller asks for" do
      html = render_component(&Conversation.shimmer/1, id: "s", tag: "span", text: "Hi")

      assert query(html, "span#s") != []
      assert query(html, "p#s") == []
    end
  end

  describe "suggestions/1 and suggestion/1" do
    test "the rail clips sideways and never wraps" do
      html = render_component(&Conversation.suggestions/1, id: "rail", inner_block: slot("x"))

      assert html =~ "overflow-x-auto"
      assert html =~ "flex w-max flex-nowrap"
    end

    test "an opener says its own text and carries it as a value" do
      html = render_component(&Conversation.suggestion/1, id: "s1", suggestion: "Explain this")

      assert [{"button", attributes, _}] = query(html, "#s1")
      assert {"value", "Explain this"} in attributes
      assert {"data-variant", "outline"} in attributes
      assert html =~ "Explain this"
      assert html =~ "rounded-full"
    end

    test "a caller's own label wins over the text" do
      html =
        render_component(&Conversation.suggestion/1,
          id: "s1",
          suggestion: "Explain this",
          inner_block: slot("Explain")
        )

      assert [{"button", _, children}] = query(html, "#s1")
      assert IO.iodata_to_binary(children) =~ "Explain"
      refute IO.iodata_to_binary(children) =~ "Explain this"
    end
  end

  describe "toolbar/1 and controls/1" do
    test "the bar draws its edge from the border token, not from the text colour" do
      html = render_component(&Conversation.toolbar/1, id: "bar", inner_block: slot("x"))

      assert html =~ "border border-border"
      assert html =~ "bg-background"
    end

    test "the bar is only a toolbar when it has a name to announce" do
      named =
        render_component(&Conversation.toolbar/1,
          id: "bar",
          label: "Node",
          inner_block: slot("x")
        )

      bare = render_component(&Conversation.toolbar/1, id: "bar", inner_block: slot("x"))

      assert query(named, "#bar[role=toolbar][aria-label=Node]") != []
      assert query(bare, "#bar[role]") == []
    end

    test "the cluster flattens whatever buttons land in it" do
      html = render_component(&Conversation.controls/1, id: "zoom", inner_block: slot("x"))

      assert html =~ "border border-border"
      assert html =~ "bg-card"
      assert html =~ "[&amp;&gt;button]:bg-transparent!"
    end
  end

  describe "persona/1" do
    test "a state with no marker of its own joins the nearest meaning" do
      thinking =
        render_component(&Conversation.persona/1, id: "p", name: "Sarah", state: "thinking")

      asleep = render_component(&Conversation.persona/1, id: "p", name: "Sarah", state: "asleep")

      assert query(thinking, "#p[data-state=thinking] .status-indicator[data-state=running]") !=
               []

      assert query(asleep, "#p[data-state=asleep] .status-indicator[data-state=ended]") != []
    end

    test "the marker stays quiet because the word beside it already says it" do
      html = render_component(&Conversation.persona/1, id: "p", name: "Sarah", state: "listening")

      assert query(html, "#p .status-indicator[aria-hidden=true]") != []
      assert html =~ "Listening"
      assert html =~ "size-16 shrink-0"
    end

    test "a caller's own status wording wins over the default" do
      html =
        render_component(&Conversation.persona/1,
          id: "p",
          name: "Sarah",
          state: "speaking",
          status_label: "Reading the diff aloud"
        )

      assert html =~ "Reading the diff aloud"
      refute html =~ "Speaking"
    end
  end
end
