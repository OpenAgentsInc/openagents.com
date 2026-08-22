defmodule OpenAgentsWeb.AI.ReasoningTest do
  @moduledoc """
  The parts of the AI Elements port that a screenshot cannot check.

  Three things can silently regress here. A `<details>` port loses the disclosure
  itself if the `open` attribute stops being written, and the surface then looks
  fine while never opening. A tool state is a word plus a colour, and dropping
  either leaves the reader guessing. And the utility strings are the point of the
  port, so the classes AI Elements carries are asserted rather than assumed.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias OpenAgentsWeb.AI.Reasoning

  defp query(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.to_tree()
  end

  defp text(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
  end

  # `render_component/2` wants slots as the entry list the HEEx compiler would
  # have built, not as a bare function.
  defp slot(name \\ :inner_block, content) when is_binary(content) do
    [%{__slot__: name, inner_block: fn _assigns, _args -> content end}]
  end

  describe "reasoning/1" do
    test "the server writes the open state, so a streaming block renders open" do
      html =
        render_component(&Reasoning.reasoning/1,
          id: "r-open",
          open: true,
          inner_block: slot("thinking")
        )

      assert [{"details", attrs, _}] = query(html, "#r-open")
      assert {"open", _} = List.keyfind(attrs, "open", 0)
    end

    test "a settled block renders closed" do
      html =
        render_component(&Reasoning.reasoning/1,
          id: "r-closed",
          inner_block: slot("thought")
        )

      assert [{"details", attrs, _}] = query(html, "#r-closed")
      refute List.keyfind(attrs, "open", 0)
    end

    test "carries the AI Elements spacing and the group hook the chevron needs" do
      html = render_component(&Reasoning.reasoning/1, id: "r", inner_block: slot(""))

      assert [{"details", attrs, _}] = query(html, "#r")
      assert {"class", class} = List.keyfind(attrs, "class", 0)
      assert class =~ "group"
      assert class =~ "mb-4"
    end
  end

  describe "reasoning_trigger/1" do
    test "shows the streaming label while the model is still thinking" do
      html = render_component(&Reasoning.reasoning_trigger/1, id: "t", streaming: true)

      assert text(html, "#t") =~ "Thinking..."
      assert [{"p", attrs, _}] = query(html, "#t p")
      assert {"class", class} = List.keyfind(attrs, "class", 0)
      assert class =~ "animate-pulse"
    end

    test "shows the elapsed duration once thinking has finished" do
      html = render_component(&Reasoning.reasoning_trigger/1, id: "t", duration: 7)

      assert text(html, "#t") =~ "Thought for 7 seconds"
    end

    test "falls back to a vague duration when none was measured" do
      html = render_component(&Reasoning.reasoning_trigger/1, id: "t")

      assert text(html, "#t") =~ "Thought for a few seconds"
    end

    test "is a summary whose chevron flips with the parent details" do
      html = render_component(&Reasoning.reasoning_trigger/1, id: "t")

      assert [{"summary", _, _}] = query(html, "summary#t")
      assert [{"svg", attrs, _}] = query(html, ~s(#t svg[data-icon="chevron-down"]))
      assert {"class", class} = List.keyfind(attrs, "class", 0)
      assert class =~ "group-open:rotate-180"
    end

    test "the glyphs beside the words announce nothing" do
      html = render_component(&Reasoning.reasoning_trigger/1, id: "t")

      for {"svg", attrs, _} <- query(html, "#t svg") do
        assert {"aria-hidden", "true"} = List.keyfind(attrs, "aria-hidden", 0)
      end
    end
  end

  describe "reasoning_content/1" do
    test "renders the reasoning as markdown rather than escaped text" do
      html =
        render_component(&Reasoning.reasoning_content/1,
          id: "rc",
          text: "A **bold** thought."
        )

      assert [_] = query(html, "#rc strong")
      assert [{"div", attrs, _}] = query(html, "#rc")
      assert {"class", class} = List.keyfind(attrs, "class", 0)
      assert class =~ "text-muted-foreground"
    end

    test "completes unbalanced markup while the text is still arriving" do
      html =
        render_component(&Reasoning.reasoning_content/1,
          id: "rc",
          text: "A **bold",
          streaming: true
        )

      assert [_] = query(html, "#rc strong")
    end
  end

  describe "tool/1 states" do
    defp tool_header(state) do
      render_component(&Reasoning.tool_header/1,
        id: "th",
        type: "tool-getWeather",
        state: state
      )
    end

    test "input-streaming reads as pending and stays neutral" do
      html = tool_header("input-streaming")

      assert text(html, "#th") =~ "Pending"
      assert [{"span", attrs, _}] = query(html, "#th .badge")
      assert {"data-variant", "dim"} = List.keyfind(attrs, "data-variant", 0)
    end

    test "input-available reads as running and pulses" do
      html = tool_header("input-available")

      assert text(html, "#th") =~ "Running"
      assert [{"svg", attrs, _}] = query(html, ~s(#th svg[data-icon="clock"]))
      assert {"class", class} = List.keyfind(attrs, "class", 0)
      assert class =~ "animate-pulse"
    end

    test "output-available reads as completed and carries the success colour" do
      html = tool_header("output-available")

      assert text(html, "#th") =~ "Completed"
      assert [{"span", attrs, _}] = query(html, "#th .badge")
      assert {"data-variant", "success"} = List.keyfind(attrs, "data-variant", 0)
      assert [_] = query(html, ~s(#th svg[data-icon="check-circle"]))
    end

    test "output-error reads as an error and carries the danger colour" do
      html = tool_header("output-error")

      assert text(html, "#th") =~ "Error"
      assert [{"span", attrs, _}] = query(html, "#th .badge")
      assert {"data-variant", "danger"} = List.keyfind(attrs, "data-variant", 0)
      assert [_] = query(html, ~s(#th svg[data-icon="x-circle"]))
    end

    test "the tool name comes from the part type" do
      assert text(tool_header("input-available"), "#th") =~ "getWeather"
    end

    test "a dynamic tool names itself" do
      html =
        render_component(&Reasoning.tool_header/1,
          id: "th",
          type: "dynamic-tool",
          tool_name: "search_docs",
          state: "input-available"
        )

      assert text(html, "#th") =~ "search_docs"
    end

    test "an explicit title wins over the derived name" do
      html =
        render_component(&Reasoning.tool_header/1,
          id: "th",
          title: "Check the weather",
          type: "tool-getWeather",
          state: "output-available"
        )

      assert text(html, "#th") =~ "Check the weather"
      refute text(html, "#th") =~ "getWeather"
    end
  end

  describe "tool_output/1" do
    test "renders nothing when the tool has neither returned nor failed" do
      assert String.trim(render_component(&Reasoning.tool_output/1, id: "to")) == ""
    end

    test "labels a result and gives it the quiet surface" do
      html = render_component(&Reasoning.tool_output/1, id: "to", output: ~s({"c": 12}))

      assert text(html, "#to h4") =~ "Result"
      assert text(html, "#to code") =~ ~s({"c": 12})
      assert [{"div", attrs, _}] = query(html, "#to > div")
      assert {"class", class} = List.keyfind(attrs, "class", 0)
      assert class =~ "bg-muted/50"
    end

    test "labels an error and gives it the destructive surface" do
      html = render_component(&Reasoning.tool_output/1, id: "to", error_text: "timed out")

      assert text(html, "#to h4") =~ "Error"
      assert text(html, "#to") =~ "timed out"
      assert [{"div", attrs, _}] = query(html, "#to > div")
      assert {"class", class} = List.keyfind(attrs, "class", 0)
      assert class =~ "bg-destructive/10"
      assert class =~ "text-destructive"
    end
  end

  describe "tool_input/1" do
    test "labels the parameters and prints them" do
      html = render_component(&Reasoning.tool_input/1, id: "ti", input: ~s({"city": "Oslo"}))

      assert text(html, "#ti h4") =~ "Parameters"
      assert text(html, "#ti code") =~ "Oslo"
    end
  end

  describe "task/1" do
    test "opens by default, as upstream does" do
      html = render_component(&Reasoning.task/1, id: "tk", inner_block: slot(""))

      assert [{"details", attrs, _}] = query(html, "#tk")
      assert {"open", _} = List.keyfind(attrs, "open", 0)
    end

    test "a task with items rules them off against the left edge" do
      html =
        render_component(&Reasoning.task_content/1,
          id: "tc",
          inner_block: slot("Read lib/app.ex")
        )

      assert text(html, "#tc") =~ "Read lib/app.ex"
      assert [{"div", attrs, _}] = query(html, "#tc > div")
      assert {"class", class} = List.keyfind(attrs, "class", 0)
      assert class =~ "border-l-2"
      assert class =~ "border-muted"
      assert class =~ "pl-4"
    end

    test "a task with no items still renders its rule, and nothing else" do
      html =
        render_component(&Reasoning.task_content/1, id: "tc", inner_block: slot(""))

      assert String.trim(text(html, "#tc")) == ""
      assert [{"div", _, _}] = query(html, "#tc > div")
    end

    test "an item is quiet body text" do
      html =
        render_component(&Reasoning.task_item/1,
          id: "ti-1",
          inner_block: slot("Read lib/app.ex")
        )

      assert text(html, "#ti-1") =~ "Read lib/app.ex"
      assert [{"div", attrs, _}] = query(html, "#ti-1")
      assert {"class", class} = List.keyfind(attrs, "class", 0)
      assert class =~ "text-muted-foreground"
      assert class =~ "text-sm"
    end

    test "the trigger states what the task is" do
      html = render_component(&Reasoning.task_trigger/1, id: "tt", title: "Searching the repo")

      assert [{"summary", _, _}] = query(html, "summary#tt")
      assert text(html, "#tt") =~ "Searching the repo"
    end

    test "a file in a task item is a chip on the secondary surface" do
      html =
        render_component(&Reasoning.task_item_file/1,
          id: "tf",
          inner_block: slot("app.ex")
        )

      assert [{"div", attrs, _}] = query(html, "#tf")
      assert {"class", class} = List.keyfind(attrs, "class", 0)
      assert class =~ "bg-secondary"
      assert class =~ "inline-flex"
    end
  end

  describe "chain_of_thought/1" do
    test "one details element carries both the header and the content" do
      html =
        render_component(&Reasoning.chain_of_thought/1,
          id: "cot",
          open: true,
          inner_block: slot("")
        )

      assert [{"details", attrs, _}] = query(html, "#cot")
      assert {"open", _} = List.keyfind(attrs, "open", 0)
    end

    test "the header names the trace by default" do
      html = render_component(&Reasoning.chain_of_thought_header/1, id: "coth")

      assert text(html, "#coth") =~ "Chain of thought"
    end

    test "a step dims according to its status" do
      for {status, expected} <- [
            {:active, "text-foreground"},
            {:complete, "text-muted-foreground"},
            {:pending, "text-muted-foreground/50"}
          ] do
        html =
          render_component(&Reasoning.chain_of_thought_step/1,
            id: "step",
            label: "Reading the spec",
            status: status
          )

        assert [{"div", attrs, _}] = query(html, "#step")
        assert {"class", class} = List.keyfind(attrs, "class", 0)
        assert class =~ expected
      end
    end

    test "a step shows its description when it has one" do
      html =
        render_component(&Reasoning.chain_of_thought_step/1,
          id: "step",
          label: "Reading the spec",
          description: "docs/spec.md"
        )

      assert text(html, "#step") =~ "docs/spec.md"
    end

    test "a search result is a quiet badge" do
      html =
        render_component(&Reasoning.chain_of_thought_search_result/1,
          id: "sr",
          inner_block: slot("openagents.com")
        )

      assert [{"span", attrs, _}] = query(html, "#sr")
      assert {"class", class} = List.keyfind(attrs, "class", 0)
      assert class =~ "badge"
      assert {"data-variant", "dim"} = List.keyfind(attrs, "data-variant", 0)
    end

    test "an image shows its caption when it has one" do
      html =
        render_component(&Reasoning.chain_of_thought_image/1,
          id: "img",
          caption: "The rendered chart",
          inner_block: slot("")
        )

      assert text(html, "#img p") =~ "The rendered chart"
    end
  end

  describe "plan/1" do
    defp plan(overrides) do
      render_component(
        &Reasoning.plan/1,
        Keyword.merge(
          [
            id: "plan",
            header: slot(:header, "Ship the parser"),
            inner_block: slot("step one")
          ],
          overrides
        )
      )
    end

    test "the header is the disclosure control and the body collapses with it" do
      html = plan([])

      assert [{"details", _, _}] = query(html, "#plan details")
      assert [{"summary", _, _}] = query(html, ~s(#plan summary[data-slot="plan-header"]))
      assert text(html, ~s(#plan [data-slot="plan-content"])) =~ "step one"
    end

    test "the footer sits outside the collapsing region so it survives closing" do
      html =
        plan(
          open: false,
          footer: slot(:footer, "Approve")
        )

      assert [] == query(html, ~s(#plan details [data-slot="plan-footer"]))
      assert text(html, ~s(#plan > [data-slot="plan-footer"])) =~ "Approve"
    end

    test "the title and description shimmer only while the plan is streaming" do
      streaming =
        render_component(&Reasoning.plan_title/1,
          id: "pt",
          streaming: true,
          inner_block: slot("Ship it")
        )

      settled =
        render_component(&Reasoning.plan_title/1,
          id: "pt",
          inner_block: slot("Ship it")
        )

      assert [{"h3", streaming_attrs, _}] = query(streaming, "#pt")
      assert [{"h3", settled_attrs, _}] = query(settled, "#pt")
      assert {"class", streaming_class} = List.keyfind(streaming_attrs, "class", 0)
      assert {"class", settled_class} = List.keyfind(settled_attrs, "class", 0)
      assert streaming_class =~ "animate-pulse"
      refute settled_class =~ "animate-pulse"
    end

    test "the trigger keeps the screen-reader wording for what it does" do
      html = render_component(&Reasoning.plan_trigger/1, id: "ptr")

      assert text(html, "#ptr .sr-only") =~ "Toggle plan"
    end
  end

  describe "checkpoint/1" do
    test "runs a rule out from its controls" do
      html =
        render_component(&Reasoning.checkpoint/1,
          id: "cp",
          inner_block: slot("Restore")
        )

      assert text(html, "#cp") =~ "Restore"
      assert [{"hr", attrs, _}] = query(html, "#cp hr")
      assert {"class", class} = List.keyfind(attrs, "class", 0)
      assert class =~ "flex-1"
      assert class =~ "bg-border"
    end

    test "the mark is a bookmark glyph that announces nothing" do
      html = render_component(&Reasoning.checkpoint_icon/1, id: "cpi")

      assert [{"svg", attrs, _}] = query(html, "#cpi")
      assert {"data-icon", "saved-xs"} = List.keyfind(attrs, "data-icon", 0)
      assert {"aria-hidden", "true"} = List.keyfind(attrs, "aria-hidden", 0)
    end

    test "a trigger turns its tooltip into a native title" do
      html =
        render_component(&Reasoning.checkpoint_trigger/1,
          id: "cpt",
          tooltip: "Restore this checkpoint",
          inner_block: slot("Restore")
        )

      assert [{"button", attrs, _}] = query(html, "#cpt")
      assert {"title", "Restore this checkpoint"} = List.keyfind(attrs, "title", 0)
      assert {"data-variant", "ghost"} = List.keyfind(attrs, "data-variant", 0)
    end
  end
end
