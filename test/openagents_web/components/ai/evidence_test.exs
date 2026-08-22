defmodule OpenAgentsWeb.AI.EvidenceTest do
  @moduledoc """
  The parts of the evidence surfaces a screenshot cannot check.

  Four failure modes are covered, and all four are invisible by eye. A code
  block that eats the braces in the code it is showing looks like a code block
  until you read it. A disclosure that renders its sources whether or not it is
  open leaks them to anyone reading the markup rather than the page. A token
  meter that pins silently at full says the same thing about a legal context
  and an overrun one. And a confirmation that keeps its controls after a
  decision offers to decide again.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias OpenAgentsWeb.AI.Evidence

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
    |> String.trim()
  end

  defp block(name, text, attributes \\ %{}) do
    attributes
    |> Map.merge(%{__slot__: name, inner_block: fn _changed, _arg -> text end})
  end

  describe "code_block/1" do
    test "keeps the braces in the code it is showing" do
      html =
        render_component(&Evidence.code_block/1,
          id: "cb-braces",
          code: ~s|let obj = {key: "val"}|,
          language: "javascript"
        )

      assert html =~ ~s|let obj = {key: &quot;val&quot;}|
    end

    test "renders one line element per line, so the counter can number them" do
      html =
        render_component(&Evidence.code_block/1,
          id: "cb-lines",
          code: "one\ntwo\nthree",
          show_line_numbers: true
        )

      assert length(query(html, "#cb-lines pre code > span")) == 3
      assert [{_, attrs, _}] = query(html, "#cb-lines pre code")
      assert {"class", class} = List.keyfind(attrs, "class", 0)
      assert class =~ "[counter-reset:line]"
    end

    test "numbers nothing unless asked" do
      html = render_component(&Evidence.code_block/1, id: "cb-plain", code: "one\ntwo")

      assert [{_, attrs, _}] = query(html, "#cb-plain pre code")
      refute List.keyfind(attrs, "class", 0) |> elem(1) =~ "counter-reset"
    end

    test "carries the language and a copy control that holds the whole snippet" do
      html =
        render_component(&Evidence.code_block/1,
          id: "cb-copy",
          code: "IO.puts(1)",
          language: "elixir"
        )

      assert [{_, attrs, _}] = query(html, "#cb-copy")
      assert {"data-language", "elixir"} = List.keyfind(attrs, "data-language", 0)

      assert [{_, copy, _}] = query(html, "#cb-copy-copy")
      assert {"data-copy-text", "IO.puts(1)"} = List.keyfind(copy, "data-copy-text", 0)
    end
  end

  describe "snippet/1" do
    test "puts the command in a read-only field with an accessible name" do
      html =
        render_component(&Evidence.snippet/1,
          id: "sn",
          code: "mix precommit",
          prefix: "$",
          label: "Install command"
        )

      assert [{_, attrs, _}] = query(html, "#sn-input")
      assert {"value", "mix precommit"} = List.keyfind(attrs, "value", 0)
      assert {"readonly", _} = List.keyfind(attrs, "readonly", 0)
      assert {"aria-label", "Install command"} = List.keyfind(attrs, "aria-label", 0)
      assert query(html, "#sn-copy") != []
    end
  end

  describe "terminal/1" do
    test "shows the caret only while output is still arriving" do
      streaming =
        render_component(&Evidence.terminal/1, id: "tm-live", output: "building", streaming: true)

      done = render_component(&Evidence.terminal/1, id: "tm-done", output: "built")

      assert query(streaming, "#tm-live .animate-pulse") != []
      assert query(done, "#tm-done .animate-pulse") == []
    end

    test "renders the output verbatim inside a preformatted block" do
      html = render_component(&Evidence.terminal/1, id: "tm-out", output: "a\nb")

      assert [{_, _, ["a\nb"]}] = query(html, "#tm-out pre")
    end
  end

  describe "terminal_line/1" do
    test "hides the prompt sigil from assistive technology" do
      html =
        render_component(&Evidence.terminal_line/1,
          prompt: "$",
          inner_block: [block(:inner_block, "mix test")]
        )

      assert [{_, attrs, ["$"]}] = query(html, "span[aria-hidden]")
      assert {"aria-hidden", "true"} = List.keyfind(attrs, "aria-hidden", 0)
      assert html =~ "mix test"
    end
  end

  describe "sources/1" do
    test "a closed disclosure is closed" do
      html =
        render_component(&Evidence.sources/1,
          id: "src-closed",
          count: 3,
          inner_block: [block(:inner_block, "the sources")]
        )

      assert [{_, attrs, _}] = query(html, "#src-closed")
      assert List.keyfind(attrs, "open", 0) == nil
      assert html =~ "Used 3 sources"
    end

    test "an open disclosure says so on the element the browser reads" do
      html =
        render_component(&Evidence.sources/1,
          id: "src-open",
          count: 1,
          open: true,
          inner_block: [block(:inner_block, "the sources")]
        )

      assert [{"details", attrs, _}] = query(html, "#src-open")
      assert List.keyfind(attrs, "open", 0) != nil
      assert query(html, "#src-open > summary") != []
    end
  end

  describe "source/1" do
    test "an outbound source opens away from the app and does not leak the referrer" do
      html =
        render_component(&Evidence.source/1, href: "https://example.com/a", title: "Example")

      assert [{_, attrs, _}] = query(html, "a")
      assert {"target", "_blank"} = List.keyfind(attrs, "target", 0)
      assert {"rel", "noreferrer"} = List.keyfind(attrs, "rel", 0)
      assert html =~ "Example"
    end
  end

  describe "inline_citation/1" do
    test "names the first source by host and counts the rest" do
      html =
        render_component(&Evidence.inline_citation/1,
          id: "ic-many",
          inner_block: [block(:inner_block, "the claim")],
          source: [
            block(:source, "", %{url: "https://example.com/a", title: "A", description: nil}),
            block(:source, "", %{url: "https://other.test/b", title: "B", description: nil})
          ]
        )

      assert text(html, "#ic-many button") == "example.com +1"
      assert html =~ "https://example.com/a"
      assert html =~ "https://other.test/b"
    end

    test "a single source is named without a count" do
      html =
        render_component(&Evidence.inline_citation/1,
          id: "ic-one",
          inner_block: [block(:inner_block, "the claim")],
          source: [block(:source, "", %{url: "https://example.com/a", title: "A"})]
        )

      assert text(html, "#ic-one button") == "example.com"
    end

    test "a source written with attributes alone still renders" do
      # `<:source url=... title=... />` is the ordinary call: the slot's three
      # attributes already say everything a source has, so the natural markup is
      # self-closing and carries no inner block. That used to raise.
      html =
        render_component(&Evidence.inline_citation/1,
          id: "ic-bare",
          inner_block: [block(:inner_block, "the claim")],
          source: [
            %{
              __slot__: :source,
              inner_block: nil,
              url: "https://example.com/a",
              title: "A",
              description: "Why it is cited"
            }
          ]
        )

      assert text(html, "#ic-bare button") == "example.com"
      assert html =~ "Why it is cited"
    end

    test "the chip points at the card it opens" do
      html =
        render_component(&Evidence.inline_citation/1,
          id: "ic-aria",
          inner_block: [block(:inner_block, "the claim")],
          source: [block(:source, "", %{url: "https://example.com/a"})]
        )

      assert [{_, attrs, _}] = query(html, "#ic-aria button")
      assert {"aria-describedby", "ic-aria-card"} = List.keyfind(attrs, "aria-describedby", 0)
      assert query(html, "#ic-aria-card") != []
    end
  end

  describe "context/1" do
    test "an empty context reads as nothing spent" do
      html =
        render_component(&Evidence.context/1, id: "ctx-0", used_tokens: 0, max_tokens: 128_000)

      assert [{_, attrs, _}] = query(html, "#ctx-0")
      assert {"data-over-budget", "false"} = List.keyfind(attrs, "data-over-budget", 0)
      assert html =~ "0%"
      assert html =~ "128K"
    end

    test "a part-spent context states the percentage and the compact counts" do
      html =
        render_component(&Evidence.context/1,
          id: "ctx-mid",
          used_tokens: 64_000,
          max_tokens: 128_000
        )

      assert html =~ "50%"
      assert html =~ "64K / 128K"

      assert [{_, attrs, _}] = query(html, "#ctx-mid [role=progressbar]")
      assert {"aria-valuenow", "50"} = List.keyfind(attrs, "aria-valuenow", 0)
    end

    test "an over-budget context is flagged rather than silently pinned at full" do
      html =
        render_component(&Evidence.context/1,
          id: "ctx-over",
          used_tokens: 150_000,
          max_tokens: 128_000
        )

      assert [{_, attrs, _}] = query(html, "#ctx-over")
      assert {"data-over-budget", "true"} = List.keyfind(attrs, "data-over-budget", 0)
      assert html =~ "117.2%"

      assert [{_, bar, _}] = query(html, "#ctx-over [role=progressbar]")
      assert {"aria-valuenow", "100"} = List.keyfind(bar, "aria-valuenow", 0)
    end

    test "the breakdown appears only for the kinds that were used" do
      html =
        render_component(&Evidence.context/1,
          id: "ctx-parts",
          used_tokens: 1200,
          max_tokens: 128_000,
          input_tokens: 1000,
          input_cost: 0.0125,
          total_cost: 0.02
        )

      assert html =~ "Input"
      refute html =~ "Reasoning"
      assert html =~ "$0.01"
      assert html =~ "Total cost"
      assert html =~ "$0.02"
    end
  end

  describe "artifact/1" do
    test "names the artifact and holds its actions apart from its body" do
      html =
        render_component(&Evidence.artifact/1,
          id: "af",
          title: "report.md",
          description: "Draft",
          inner_block: [block(:inner_block, "the body")],
          actions: [block(:actions, "the actions")]
        )

      assert html =~ "report.md"
      assert html =~ "Draft"
      assert html =~ "the body"
      assert html =~ "the actions"
    end
  end

  describe "artifact_action/1" do
    test "an icon-only control keeps its name, and the glyph stays quiet" do
      html = render_component(&Evidence.artifact_action/1, icon: "download", label: "Download")

      assert [{_, attrs, _}] = query(html, "button")
      assert {"aria-label", "Download"} = List.keyfind(attrs, "aria-label", 0)
      assert {"title", "Download"} = List.keyfind(attrs, "title", 0)

      assert [{_, glyph, _}] = query(html, "button svg")
      assert {"aria-hidden", "true"} = List.keyfind(glyph, "aria-hidden", 0)
      assert List.keyfind(glyph, "aria-label", 0) == nil
    end
  end

  describe "confirmation/1" do
    test "before a decision, the controls are the point" do
      html =
        render_component(&Evidence.confirmation/1,
          id: "cf-ask",
          state: :requested,
          title: "Delete the branch?",
          actions: [block(:actions, "the controls")]
        )

      assert [{_, attrs, _}] = query(html, "#cf-ask")
      assert {"data-state", "requested"} = List.keyfind(attrs, "data-state", 0)
      assert html =~ "Delete the branch?"
      assert html =~ "the controls"
      refute html =~ "Approved"
      refute html =~ "Denied"
    end

    test "after a decision, the outcome replaces the controls" do
      html =
        render_component(&Evidence.confirmation/1,
          id: "cf-yes",
          state: :approved,
          title: "Delete the branch?",
          reason: "merged an hour ago",
          actions: [block(:actions, "the controls")]
        )

      assert [{_, attrs, _}] = query(html, "#cf-yes")
      assert {"data-state", "approved"} = List.keyfind(attrs, "data-state", 0)
      assert html =~ "Approved"
      assert html =~ "merged an hour ago"
      refute html =~ "the controls"
    end

    test "a denial reads as a denial" do
      html =
        render_component(&Evidence.confirmation/1,
          id: "cf-no",
          state: :denied,
          title: "Delete the branch?",
          actions: [block(:actions, "the controls")]
        )

      assert html =~ "Denied"
      refute html =~ "the controls"
    end
  end

  describe "question/1" do
    test "single choice is a radio group, and the chosen value arrives checked" do
      html =
        render_component(&Evidence.question/1,
          id: "q-one",
          prompt: "Which branch?",
          name: "branch",
          selected: ["main"],
          option: [
            block(:option, "main", %{value: "main"}),
            block(:option, "next", %{value: "next"})
          ]
        )

      assert [{_, first, _}, {_, second, _}] = query(html, "#q-one input[type=radio]")
      assert {"name", "branch"} = List.keyfind(first, "name", 0)
      assert List.keyfind(first, "checked", 0) != nil
      assert List.keyfind(second, "checked", 0) == nil
      assert query(html, "#q-one-text") != []
    end

    test "multiple choice submits a list" do
      html =
        render_component(&Evidence.question/1,
          id: "q-many",
          prompt: "Which files?",
          name: "files",
          selection_mode: :multiple,
          option: [block(:option, "a.ex", %{value: "a.ex"})]
        )

      assert [{_, attrs, _}] = query(html, "#q-many input[type=checkbox]")
      assert {"name", "files[]"} = List.keyfind(attrs, "name", 0)
    end

    test "a disabled question disables its choices and its submit control" do
      html =
        render_component(&Evidence.question/1,
          id: "q-off",
          prompt: "Which branch?",
          disabled: true,
          option: [block(:option, "main", %{value: "main"})]
        )

      assert [{_, fieldset, _}] = query(html, "#q-off fieldset")
      assert List.keyfind(fieldset, "disabled", 0) != nil
      assert [{_, submit, _}] = query(html, "#q-off button[type=submit]")
      assert List.keyfind(submit, "disabled", 0) != nil
    end
  end

  describe "image/1" do
    test "model output becomes a data URI" do
      html =
        render_component(&Evidence.image/1,
          id: "im-data",
          alt: "A generated skyline",
          base64: "AAAA",
          media_type: "image/png"
        )

      assert [{_, attrs, _}] = query(html, "#im-data")
      assert {"src", "data:image/png;base64,AAAA"} = List.keyfind(attrs, "src", 0)
      assert {"alt", "A generated skyline"} = List.keyfind(attrs, "alt", 0)
    end

    test "an address is used as given" do
      html = render_component(&Evidence.image/1, id: "im-src", alt: "A chart", src: "/a.png")

      assert [{_, attrs, _}] = query(html, "#im-src")
      assert {"src", "/a.png"} = List.keyfind(attrs, "src", 0)
    end
  end
end
