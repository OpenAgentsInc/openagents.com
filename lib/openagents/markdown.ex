defmodule OpenAgents.Markdown do
  @moduledoc """
  Renders assistant text as Markdown, safely, including while it is streaming.

  Two problems, solved separately.

  ## Untrusted input

  Model output is not trusted. Earmark passes raw HTML straight through and will
  happily emit a `javascript:` href, so neither its HTML output nor its
  transformer is used. Instead the parsed AST is walked against an allowlist of
  tags and attributes, and this module writes the HTML itself so every text node
  is escaped here rather than somewhere further down. Anything not on the
  allowlist is dropped, and its text is kept.

  ## Partial input

  While a turn streams, the text arrives mid-token: `**bold` with no closer,
  a fence that has opened and not closed, a link whose URL is half-typed.
  Rendering that literally is what produces the raw asterisks a reader sees
  today; rendering it naively makes the layout jump as each delimiter lands.

  `complete/1` closes the open constructs before parsing, so the parser always
  sees a well-formed document. The approach is taken from Streamdown's `remend`
  package: scan once, track what is open, and close it — while respecting
  escapes, refusing to close inside an open code fence, and refusing to close a
  marker with nothing after it. It is a heuristic, deliberately, and the guards
  matter more than the completeness.
  """

  @block_tags ~w(p ul ol li blockquote pre h1 h2 h3 h4 h5 h6 hr table thead tbody tr th td)
  @inline_tags ~w(strong em del code a br)
  @allowed_tags @block_tags ++ @inline_tags

  @void_tags ~w(br hr)

  # `code` carries Earmark's own `inline` marker; everything else is dropped.
  @allowed_attributes %{"a" => ["href"], "code" => ["class"], "pre" => ["class"]}

  @safe_schemes ~w(http https mailto)

  @emphasis_markers ~w(*** ___ ** __ ~~ * _)

  @doc """
  Renders Markdown to safe HTML.

  Pass `streaming: true` while the text is still arriving so open constructs are
  closed before parsing.
  """
  @spec to_html(String.t(), keyword()) :: {:safe, iodata()}
  def to_html(text, options \\ []) when is_binary(text) do
    text
    |> then(fn raw -> if options[:streaming], do: complete(raw), else: raw end)
    |> parse()
    |> Enum.map(&render_node/1)
    |> then(&{:safe, &1})
  end

  defp parse(text) do
    case Earmark.Parser.as_ast(text, gfm: true, breaks: true) do
      {:ok, ast, _messages} -> ast
      {:error, ast, _messages} -> ast
    end
  end

  # ── Rendering ──────────────────────────────────────────────────────────────

  defp render_node(text) when is_binary(text), do: escape(text)

  defp render_node({tag, attributes, children, _meta}) when tag in @allowed_tags do
    rendered = Enum.map(children, &render_node/1)

    cond do
      tag in @void_tags -> ["<", tag, attributes(tag, attributes), " />"]
      true -> ["<", tag, attributes(tag, attributes), ">", rendered, "</", tag, ">"]
    end
  end

  # An unknown tag keeps its text and loses its markup, which is the safe
  # direction: a reader still sees the words.
  defp render_node({_tag, _attributes, children, _meta}), do: Enum.map(children, &render_node/1)

  defp render_node(_other), do: []

  defp attributes(tag, attributes) do
    allowed = Map.get(@allowed_attributes, tag, [])

    attributes
    |> Enum.filter(fn {name, _value} -> name in allowed end)
    |> Enum.flat_map(&attribute(tag, &1))
  end

  defp attribute("a", {"href", value}) do
    case safe_url(value) do
      nil ->
        []

      url ->
        # Model output can link anywhere, so a link leaves without carrying the
        # referrer or a handle on this window.
        [~s( href="), escape(url), ~s(" rel="noopener noreferrer nofollow" target="_blank")]
    end
  end

  defp attribute(_tag, {name, value}), do: [" ", name, ~s(="), escape(value), ~s(")]

  defp safe_url(value) do
    trimmed = value |> to_string() |> String.trim()

    cond do
      trimmed == "" -> nil
      String.starts_with?(trimmed, ["/", "#"]) -> trimmed
      scheme_of(trimmed) in @safe_schemes -> trimmed
      # No scheme at all is a bare domain; treat it as https rather than
      # letting the browser resolve it relative to OpenAgents.
      scheme_of(trimmed) == nil -> "https://" <> trimmed
      true -> nil
    end
  end

  defp scheme_of(url) do
    case Regex.run(~r/\A([a-zA-Z][a-zA-Z0-9+.-]*):/, url) do
      [_, scheme] -> String.downcase(scheme)
      nil -> nil
    end
  end

  defp escape(value), do: value |> to_string() |> Phoenix.HTML.html_escape() |> elem(1)

  # ── Completion of partial Markdown ─────────────────────────────────────────

  @doc """
  Closes Markdown constructs left open by a partial stream.

  Ported in spirit from Streamdown's `remend`: an unterminated marker is closed
  so the parser sees a well-formed document rather than literal syntax.
  """
  @spec complete(String.t()) :: String.t()
  def complete(text) when is_binary(text) do
    if open_fence?(text) do
      # Inside a fence everything is literal, so nothing inline may be closed —
      # only the fence itself.
      text <> "\n```"
    else
      text
      |> drop_incomplete_image()
      |> flatten_incomplete_link()
      |> close_inline_code()
      |> close_emphasis()
    end
  end

  defp open_fence?(text) do
    text
    |> String.split("\n")
    |> Enum.count(&String.starts_with?(String.trim_leading(&1), "```"))
    |> rem(2) == 1
  end

  # A half-arrived image cannot be shown, so it is removed rather than rendered
  # as a broken one.
  defp drop_incomplete_image(text), do: String.replace(text, ~r/!\[[^\]]*\]\([^)]*\z/, "")

  # A half-arrived URL must never reach an href. The text survives; the link
  # does not.
  defp flatten_incomplete_link(text), do: String.replace(text, ~r/\[([^\]]*)\]\([^)]*\z/, "\\1")

  defp close_inline_code(text) do
    if text |> strip_escapes() |> count_solo_backticks() |> rem(2) == 1 do
      # An opener with nothing after it is a marker mid-arrival. Dropping it
      # beats closing it, because closing renders an empty span and leaving it
      # shows the reader raw syntax for one frame.
      if String.ends_with?(text, "`"),
        do: String.replace_suffix(text, "`", ""),
        else: text <> "`"
    else
      text
    end
  end

  defp count_solo_backticks(text) do
    text
    |> String.replace("```", "")
    |> String.graphemes()
    |> Enum.count(&(&1 == "`"))
  end

  defp close_emphasis(text) do
    # Recomputed per marker: dropping a dangling one changes what the next
    # marker sees.
    Enum.reduce(@emphasis_markers, text, fn marker, accumulator ->
      scannable = accumulator |> strip_escapes() |> strip_code_spans()

      cond do
        not unbalanced?(scannable, marker) -> accumulator
        content_after_last?(scannable, marker) -> accumulator <> marker
        String.ends_with?(accumulator, marker) -> String.replace_suffix(accumulator, marker, "")
        true -> accumulator
      end
    end)
  end

  # Longer markers are counted first and removed, so `**` does not also register
  # as two `*`.
  defp unbalanced?(text, marker) do
    text
    |> remove_longer_markers(marker)
    |> then(&(&1 |> String.split(marker) |> length() |> Kernel.-(1)))
    |> rem(2) == 1
  end

  defp remove_longer_markers(text, marker) do
    @emphasis_markers
    |> Enum.filter(
      &(String.length(&1) > String.length(marker) and String.first(&1) == String.first(marker))
    )
    |> Enum.reduce(text, fn longer, accumulator -> String.replace(accumulator, longer, "") end)
  end

  # `**` with nothing after it is a marker the model is still typing, not an
  # emphasis to close.
  defp content_after_last?(text, marker) do
    case text |> remove_longer_markers(marker) |> String.split(marker) |> List.last() do
      nil -> false
      tail -> String.trim(tail) != ""
    end
  end

  defp strip_escapes(text), do: String.replace(text, ~r/\\./, "")

  defp strip_code_spans(text), do: String.replace(text, ~r/`[^`\n]*`/, "")
end
