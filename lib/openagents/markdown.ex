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

  @emphasis_markers ~w(*** ___ ** __ ~~ * _)

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
        render(source)
    end
  end

  defp render(text) do
    with {:ok, document} <- MDEx.parse_document(text, @mdex_options),
         :ok <- validate_nesting(document),
         document <- normalize_links(document),
         {:ok, rendered} <- MDEx.to_html(document),
         rendered <- String.replace(rendered, @empty_link, "<a>"),
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
