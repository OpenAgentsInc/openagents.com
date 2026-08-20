defmodule OpenAgents.Markdown do
  @moduledoc """
  Renders assistant text as Markdown, safely, including while it is streaming.

  Two problems, solved separately.

  ## Untrusted input

  Model output is not trusted. We render it with `MDEx` and then sanitize the
  resulting HTML with `MDEx.Document.default_sanitize_options/0`, which strips
  dangerous tags and attributes and adds `rel="noopener noreferrer"` to links.

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
    |> then(
      &MDEx.to_html!(&1,
        extension: [strikethrough: true, table: true, tasklist: true],
        render: [unsafe: true],
        sanitize: MDEx.Document.default_sanitize_options()
      )
    )
    |> Phoenix.HTML.raw()
  end

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
