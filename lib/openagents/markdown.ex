defmodule OpenAgents.Markdown do
  @moduledoc """
  Renders assistant text as Markdown, safely, including while it is streaming.

  Two problems, solved separately.

  ## Untrusted input

  Model output is not trusted. MDEx parses CommonMark with dangerous rendering
  disabled, then Ammonia applies a second exact allowlist for tags, attributes,
  and URL schemes. Raw HTML is refused, dangerous links lose their `href`, and
  external links receive fixed isolation attributes. Input size, AST nesting,
  and rendered output are independently bounded before the result is marked
  safe.

  ## Partial input

  While a turn streams, the text arrives mid-token: `**bold` with no closer,
  a fence that has opened and not closed, a link whose URL is half-typed.
  Rendering that literally is what produces the raw asterisks a reader sees
  today; rendering it naively makes the layout jump as each delimiter lands.

  `complete/1` closes the open constructs before parsing, so MDEx always
  sees a well-formed document. The approach is taken from Streamdown's `remend`
  package: scan once, track what is open, and close it — while respecting
  escapes, refusing to close inside an open code fence, and refusing to close a
  marker with nothing after it. It is a heuristic, deliberately, and the guards
  matter more than the completeness.
  """

  @allowed_tags ~w(a blockquote br code del em h1 h2 h3 h4 h5 h6 hr li ol p pre strong table tbody td th thead tr ul)
  @safe_schemes ~w(http https mailto)

  @maximum_input_bytes 1_000_000
  @maximum_output_bytes 2_000_000
  @maximum_nesting_depth 32
  @maximum_fallback_bytes 64_000

  @mdex_options [
    extension: [strikethrough: true, table: true],
    parse: [relaxed_autolinks: false],
    render: [hardbreaks: true, unsafe: false, escape: false],
    sanitize: [
      tags: @allowed_tags,
      clean_content_tags: ~w(script style),
      tag_attributes: %{
        "a" => ~w(href target),
        "code" => ~w(class),
        "pre" => ~w(class)
      },
      generic_attributes: [],
      url_schemes: @safe_schemes,
      url_relative: :passthrough,
      link_rel: "noopener noreferrer nofollow",
      set_tag_attribute_values: %{"a" => %{"target" => "_blank"}}
    ]
  ]

  @empty_link ~s(<a href="" target="_blank" rel="noopener noreferrer nofollow">)

  # The sanitizer gives every link the same isolation attributes, which is
  # right for a link that leaves the site and wrong for one that does not: a
  # link to our own page opened a second tab, and the reader ends up with a
  # trail of tabs for what is one visit.
  #
  # `safe_url/1` has already rewritten `//host` to `https://host`, so at this
  # point a leading single `/` means same-origin, and `#` means this very page.
  # Everything else -- any scheme, any bare host -- is still treated as leaving.
  @internal_link ~r{<a href="(/(?!/)[^"]*|#[^"]*)" target="_blank" rel="noopener noreferrer nofollow">}

  @same_tab ~S(<a href="\1">)

  @emphasis_markers ~w(*** ___ ** __ ~~ * _)

  @incomplete_block_marker ~r/^(?:\s{0,3}(?:\d{1,9}[.)]?|[#>*+\-]{1,6})\s*|\s*\|?[:|\-\s]+\|?)$/u

  @doc """
  Renders Markdown to safe HTML.

  Pass `streaming: true` while the text is still arriving so open constructs are
  closed before parsing.
  """
  @spec to_html(String.t(), keyword()) :: {:safe, iodata()}
  def to_html(text, options \\ []) when is_binary(text) do
    cond do
      byte_size(text) > @maximum_input_bytes ->
        limited(text, "input exceeds #{@maximum_input_bytes} bytes")

      true ->
        source = if options[:streaming], do: complete(text), else: text
        render(source, options)
    end
  end

  defp render(text, options) do
    mdex_options = mdex_options(options)

    with {:ok, document} <- MDEx.parse_document(text, mdex_options),
         :ok <- validate_nesting(document),
         document <- normalize_links(document),
         {:ok, rendered} <- MDEx.to_html(document, mdex_options),
         rendered <- String.replace(rendered, @empty_link, "<a>"),
         rendered <- String.replace(rendered, @internal_link, @same_tab),
         :ok <- validate_output(rendered) do
      {:safe, rendered}
    else
      {:error, :nesting_limit} ->
        limited(text, "nesting exceeds #{@maximum_nesting_depth} levels")

      {:error, :output_limit} ->
        limited(text, "rendered output exceeds #{@maximum_output_bytes} bytes")

      {:error, _parse_or_render_error} ->
        limited(text, "input could not be rendered safely")
    end
  end

  defp validate_nesting(document) do
    if nesting_depth(document) <= @maximum_nesting_depth,
      do: :ok,
      else: {:error, :nesting_limit}
  end

  defp nesting_depth(%{nodes: nodes}) when is_list(nodes) do
    1 + Enum.reduce(nodes, 0, fn node, depth -> max(depth, nesting_depth(node)) end)
  end

  defp nesting_depth(_leaf), do: 1

  defp normalize_links(document) do
    MDEx.Document.update_nodes(document, MDEx.Link, fn link ->
      %{link | url: safe_url(link.url)}
    end)
  end

  defp safe_url(value) do
    trimmed = value |> to_string() |> String.trim()

    cond do
      trimmed == "" -> ""
      String.starts_with?(trimmed, "//") -> "https:" <> trimmed
      String.starts_with?(trimmed, ["/", "#"]) -> trimmed
      scheme_of(trimmed) in @safe_schemes -> trimmed
      scheme_of(trimmed) == nil -> "https://" <> trimmed
      true -> ""
    end
  end

  defp validate_output(rendered) do
    if byte_size(rendered) <= @maximum_output_bytes,
      do: :ok,
      else: {:error, :output_limit}
  end

  defp scheme_of(url) do
    case Regex.run(~r/\A([a-zA-Z][a-zA-Z0-9+.-]*):/, url) do
      [_, scheme] -> String.downcase(scheme)
      nil -> nil
    end
  end

  # Hard breaks are correct for a person's message, where the line breaks they
  # typed are part of what they said. They are wrong for authored documents,
  # whose source is wrapped at a comfortable editing width: every one of those
  # wraps became a `<br>`, so a docs page rendered at the width of its source
  # file rather than the width of its column, and no amount of CSS could widen
  # it.
  defp mdex_options(options) do
    if Keyword.get(options, :hardbreaks, true) do
      @mdex_options
    else
      put_in(@mdex_options, [:render, :hardbreaks], false)
    end
  end

  defp limited(text, reason) do
    excerpt = truncate_utf8(text, @maximum_fallback_bytes)

    html = [
      "<p><strong>Markdown rendering limited.</strong> ",
      escape(reason),
      ".</p><pre>",
      escape(excerpt),
      if(byte_size(text) > byte_size(excerpt), do: "\n…", else: ""),
      "</pre>"
    ]

    {:safe, html}
  end

  defp truncate_utf8(value, maximum_bytes) when byte_size(value) <= maximum_bytes, do: value

  defp truncate_utf8(value, maximum_bytes) do
    value
    |> binary_part(0, maximum_bytes)
    |> trim_to_valid_utf8(4)
  end

  defp trim_to_valid_utf8(value, attempts) do
    cond do
      String.valid?(value) -> value
      attempts == 0 or byte_size(value) == 0 -> ""
      true -> trim_to_valid_utf8(binary_part(value, 0, byte_size(value) - 1), attempts - 1)
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
      |> drop_incomplete_html_tag()
      |> drop_incomplete_block_marker()
      |> close_inline_code()
      |> finish_partial_emphasis_closer()
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
  defp drop_incomplete_image(text) do
    text
    |> String.replace(~r/!\[[^\]]*\]\([^)]*\z/u, "")
    |> String.replace(~r/!\[[^\]\n]*\z/u, "")
  end

  # A half-arrived URL must never reach an href. The text survives; the link
  # does not.
  defp flatten_incomplete_link(text) do
    text
    |> String.replace(~r/\[([^\]]*)\]\([^)]*\z/u, "\\1")
    |> String.replace(~r/\[([^\]\n]*)\z/u, "\\1")
  end

  # Streamdown's `remend` removes a tag-shaped tail until its closing `>`
  # arrives. Raw HTML is refused later regardless, but dropping the partial
  # source here also prevents `<di` from flashing as ordinary text first.
  defp drop_incomplete_html_tag(text) do
    String.replace(text, ~r/<[!?\/]?[[:alpha:]][^>\n]*\z/u, "")
  end

  # A block marker cannot be classified until some content follows it. For
  # example, `1` becomes `1. ` and then an ordered-list item; rendering each
  # prefix changes the DOM from a paragraph into a list and exposes the raw
  # marker for a frame. Keep every completed block visible, but withhold this
  # ambiguous final line until its first content character arrives.
  defp drop_incomplete_block_marker(text) do
    lines = String.split(text, "\n")
    tail = List.last(lines)

    if Regex.match?(@incomplete_block_marker, tail) do
      lines
      |> Enum.drop(-1)
      |> Enum.join("\n")
      |> then(&if(length(lines) > 1, do: &1 <> "\n", else: &1))
    else
      text
    end
  end

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

  # A closing delimiter can arrive one character at a time. At the intermediate
  # `**bold*` prefix, appending a full `**` produces `**bold***`, which CommonMark
  # renders as bold text followed by a literal asterisk. Add only the missing
  # part of the closer. If the shorter trailing delimiter is already balanced,
  # it belongs to a nested span and must remain untouched.
  defp finish_partial_emphasis_closer(text) do
    case Regex.run(~r/(\*+|_+|~+)\z/u, text, capture: :all_but_first) do
      [tail] -> finish_partial_emphasis_closer(text, tail)
      nil -> text
    end
  end

  defp finish_partial_emphasis_closer(text, tail) do
    character = String.first(tail)
    tail_length = String.length(tail)
    shorter_marker = String.duplicate(character, tail_length)

    shorter_marker_balanced? =
      shorter_marker in @emphasis_markers and not unbalanced?(text, shorter_marker)

    partial_opener =
      Enum.find(@emphasis_markers, fn marker ->
        String.first(marker) == character and
          String.length(marker) > tail_length and
          unbalanced?(text, marker) and
          content_after_last?(text, marker)
      end)

    if partial_opener && not shorter_marker_balanced? do
      text <> String.duplicate(character, String.length(partial_opener) - tail_length)
    else
      text
    end
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
