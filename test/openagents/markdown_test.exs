defmodule OpenAgents.MarkdownTest do
  @moduledoc """
  Markdown rendering is the one place model output becomes markup, so the
  security cases carry as much weight here as the formatting ones.
  """

  use ExUnit.Case, async: true
  alias OpenAgents.Markdown

  defp html(text, options \\ []) do
    text |> Markdown.to_html(options) |> Phoenix.HTML.safe_to_string()
  end

  describe "formatting" do
    test "renders the constructs an assistant actually emits" do
      rendered =
        html("""
        So far:

        - You asked me to reply **"LOCAL AUTH OK"**, and I did.
        - I identified myself as *Sarah*.
        """)

      assert rendered =~ "<ul>"
      assert rendered =~ "<li>"
      assert rendered =~ "<strong>"
      assert rendered =~ "<em>Sarah</em>"
      # The literal syntax is gone, which is the whole point.
      refute rendered =~ "**"
    end

    test "renders code spans and fences" do
      assert html("call `mix precommit` first") =~ "<code"
      fenced = html("```elixir\nIO.puts(\"hi\")\n```")
      assert fenced =~ "<pre>"
      assert fenced =~ "<code"
      assert fenced =~ "IO.puts"
    end

    test "renders headings, quotes, rules, and strikethrough" do
      assert html("## Heading") =~ "<h2>"
      assert html("> quoted") =~ "<blockquote>"
      assert html("~~gone~~") =~ "<del>"
    end

    test "renders ordered lists as ordered-list markup" do
      rendered = html("1. First\n2. Second")

      assert rendered =~ "<ol>"
      assert rendered =~ "<li>First</li>"
      assert rendered =~ "<li>Second</li>"
    end

    test "renders tables and malformed Markdown without crashing" do
      table = html("| A | B |\n|---|---|\n| 1 | 2 |")

      assert table =~ "<table>"
      assert table =~ "<th>A</th>"
      assert table =~ "<td>2</td>"

      malformed = html("[unfinished **link](https://example.com and `code")

      assert is_binary(malformed)
      refute malformed =~ "<script"
    end

    test "complete persisted content is stable through the streaming path" do
      persisted = """
      ## Result

      - **Safe** [link](https://example.com)
      - `mix precommit`
      """

      assert html(persisted, streaming: true) == html(persisted)
    end
  end

  describe "untrusted input" do
    test "raw HTML is refused while its harmless text remains" do
      rendered = html("before <script>alert(1)</script> after")

      refute rendered =~ "<script>"
      refute rendered =~ "&lt;script&gt;"
      assert rendered =~ "alert(1)"
    end

    test "an event-handler attribute cannot survive" do
      rendered = html(~s|<img src=x onerror="alert(1)">|)

      refute rendered =~ "onerror"
      refute rendered =~ "<img"
    end

    test "javascript and data URLs are dropped from links" do
      for scheme <- ["javascript:alert(1)", "data:text/html,<script>x</script>", "vbscript:x"] do
        rendered = html("[click](#{scheme})")

        refute rendered =~ "href"
        # The words survive even though the link does not.
        assert rendered =~ "click"
      end
    end

    test "safe schemes are kept and leave without a referrer" do
      rendered = html("[docs](https://example.com/x)")

      assert rendered =~ ~s(href="https://example.com/x")
      assert rendered =~ ~s(rel="noopener noreferrer nofollow")
      assert rendered =~ ~s(target="_blank")
    end

    test "relative, fragment, mail, and protocol-relative links are normalized safely" do
      assert html("[path](/docs)") =~ ~s(href="/docs")
      assert html("[section](#part)") =~ ~s(href="#part")
      assert html("[mail](mailto:team@example.com)") =~ ~s(href="mailto:team@example.com")
      assert html("[cdn](//example.com/x)") =~ ~s(href="https://example.com/x")
    end

    test "a link that stays on the site opens in the same tab" do
      # A second tab per internal link leaves the reader with a trail of them
      # for what is one visit.
      for markdown <- ["[path](/docs)", "[root](/)", "[section](#part)"] do
        rendered = html(markdown)

        refute rendered =~ ~s(target="_blank"), "opened a new tab: #{markdown}"

        refute rendered =~ ~s(rel="noopener noreferrer nofollow"),
               "isolated a same-origin link: #{markdown}"
      end
    end

    test "a link that only looks internal still leaves" do
      # `//host` is a protocol-relative URL: it reads as a path and is not one.
      # It is rewritten to https earlier, and must still be treated as leaving.
      rendered = html("[cdn](//example.com/x)")

      assert rendered =~ ~s(href="https://example.com/x")
      assert rendered =~ ~s(target="_blank")
      assert rendered =~ ~s(rel="noopener noreferrer nofollow")
    end

    test "a bare domain is resolved as https rather than relative to Sarah" do
      assert html("[site](example.com)") =~ ~s(href="https://example.com")
    end

    test "quotes in link text cannot break out of the attribute" do
      rendered = html(~s|[x](https://example.com/"onmouseover="alert(1))|)

      refute rendered =~ ~s(onmouseover=")
    end

    test "oversized input returns a bounded escaped fallback" do
      rendered = html(String.duplicate("<", 1_000_001))

      assert rendered =~ "Markdown rendering limited."
      assert rendered =~ "input exceeds 1000000 bytes"
      assert byte_size(rendered) < 400_000
      refute rendered =~ "<script"
    end

    test "excessive nesting returns a bounded fallback" do
      # Blockquotes produce real nested AST nodes and exercise the structural
      # limit independently of raw input size.
      rendered = html(String.duplicate("> ", 40) <> "deep")

      assert rendered =~ "Markdown rendering limited."
      assert rendered =~ "nesting exceeds 32 levels"
      assert rendered =~ "deep"
    end

    test "render expansion is bounded independently of input size" do
      rendered = html(String.duplicate("&", 500_000))

      assert rendered =~ "Markdown rendering limited."
      assert rendered =~ "rendered output exceeds 2000000 bytes"
      assert byte_size(rendered) < 400_000
    end
  end

  describe "complete/1 for partial streams" do
    test "closes an unterminated bold, italic, and strikethrough" do
      assert Markdown.complete("a **bold") == "a **bold**"
      assert Markdown.complete("a *it") == "a *it*"
      assert Markdown.complete("a ~~gone") == "a ~~gone~~"
    end

    test "closes unterminated inline code" do
      assert Markdown.complete("run `mix tes") == "run `mix tes`"
    end

    test "closes an open fence and completes nothing inside it" do
      completed = Markdown.complete("```elixir\nx = \"**not bold")

      assert String.ends_with?(completed, "\n```")
      refute String.ends_with?(completed, "****")
    end

    test "leaves balanced text alone" do
      for text <- ["**done**", "plain words", "`code` and **bold**", "a * b * c"] do
        assert Markdown.complete(text) == text
      end
    end

    test "drops a marker that has nothing after it yet" do
      # The model is mid-token. Closing would render an empty emphasis and
      # leaving it would show the reader raw syntax, so it is dropped until the
      # content it decorates arrives.
      assert Markdown.complete("text **") == "text "
      assert Markdown.complete("text `") == "text "
      assert Markdown.complete("text *") == "text "
    end

    test "withholds an ambiguous trailing block marker until content arrives" do
      for marker <- ["1", "1.", "1. ", "-", "- ", "##", "## ", ">", "> ", "|"] do
        assert Markdown.complete(marker) == "",
               "rendered incomplete block marker #{inspect(marker)}"
      end

      assert Markdown.complete("Done\n2.") == "Done\n"
      assert Markdown.complete("1. First") == "1. First"
      assert Markdown.complete("## Heading") == "## Heading"
    end

    test "ignores escaped markers" do
      assert Markdown.complete("2 \\* 3") == "2 \\* 3"
    end

    test "a half-arrived link keeps its text and grows no href" do
      completed = Markdown.complete("see [the docs](https://exam")

      refute completed =~ "href"
      refute completed =~ "]("
      assert completed =~ "the docs"
    end

    test "a half-arrived link label and HTML tag do not expose their delimiters" do
      assert Markdown.complete("see [the doc") == "see the doc"
      assert Markdown.complete("before <sect") == "before "
    end

    test "a half-arrived image is dropped rather than rendered broken" do
      assert Markdown.complete("look ![alt](https://exam") == "look "
    end

    test "partial text renders without leaking syntax at any prefix" do
      full = "Here is **bold** and `code` and [a link](https://example.com)."

      for length <- 1..String.length(full) do
        rendered = full |> String.slice(0, length) |> html(streaming: true)

        refute rendered =~ "**", "raw bold syntax leaked at prefix #{length}"
        refute rendered =~ "](", "raw link syntax leaked at prefix #{length}"
      end
    end
  end
end
