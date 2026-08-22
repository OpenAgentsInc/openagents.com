defmodule OpenAgentsWeb.OG.Templates do
  @moduledoc """
  SVG templates for Open Graph cards: one pure function per card kind, all
  sharing a frame. Every dynamic string has already passed through
  `OpenAgentsWeb.OG.escape/1`, `clamp/2`, and `wrap/3` by the time it lands
  here — this module adds no trust of its own.

  The palette is the dark ladder from `assets/css/app.css` pinned to hex
  values: a crawler renders the image once, so the card cannot follow the
  visitor's theme. No remote references are emitted, and the only path data
  embedded is our own brand mark.
  """

  alias OpenAgentsWeb.OG
  alias OpenAgentsWeb.OG.BrandMark

  @width 1200
  @height 630
  @margin 72

  # Attribute-ready font stack: single quotes sit inside a double-quoted XML
  # attribute, which needs no further escaping.
  @font ~S('Geist Sans', 'Segoe UI', system-ui, -apple-system, sans-serif)

  @background "#08090a"
  @surface "#141516"
  @text "#f7f8f8"
  @muted "#8a8f98"
  @line "#23252a"
  @accent "#5e6ad2"
  @accent_bright "#828fff"

  # One vertical grid for every resource card: kicker, up to two heading
  # lines beside an optional avatar disc, up to two description lines, a chip
  # row, one stats line, and the brand footer.
  @kicker_y 118
  @heading_top 150
  @description_ys [358, 402]
  @chips_y 436
  @stats_y 524
  @footer_y @height - 44

  @state_colors %{open: "#3fb950", done: "#8957e5", muted: @muted}

  @doc "Render a card to an SVG string at the canonical 1200x630 size."
  def render(%OG{} = card) do
    inner =
      case card.kind do
        :site -> site_body(card)
        _kind -> resource_body(card)
      end

    [
      ~s(<svg xmlns="http://www.w3.org/2000/svg" width="#{@width}" height="#{@height}" viewBox="0 0 #{@width} #{@height}" role="img">),
      ~s(<rect x="1" y="1" width="#{@width - 2}" height="#{@height - 2}" rx="24" fill="#{@background}" stroke="#{@line}" stroke-width="2"/>),
      inner,
      footer(),
      "</svg>"
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  ## Bodies -------------------------------------------------------------------

  defp site_body(card) do
    compact([
      kicker(card.kicker, 188),
      heading_block(OG.wrap(card.heading || "", 30, 2), 64, 224, @margin),
      text_lines(OG.wrap(card.description || "", 48, 2), 32, @muted, [420, 466])
    ])
  end

  defp resource_body(%OG{} = card) do
    repo_card? = card.kind == :repo
    size = if repo_card?, do: 84, else: 56
    budget = if repo_card?, do: 24, else: 36

    compact([
      kicker(card.kicker, @kicker_y),
      avatar_disc(card.avatar, @heading_top),
      heading_block(OG.wrap(card.heading || "", budget, 2), size, @heading_top, heading_x(card)),
      text_lines(OG.wrap(card.description || "", 54, 2), 31, @muted, @description_ys),
      chips_row(@chips_y, card.chips),
      stats_row(@stats_y, card.stats),
      provenance(card.provenance)
    ])
  end

  defp compact(parts) do
    parts
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  ## Pieces -------------------------------------------------------------------

  defp kicker(nil, _y), do: nil

  defp kicker(text, y) do
    escaped = text |> String.upcase() |> OG.clamp(64) |> OG.escape()

    tag("text",
      x: @margin,
      y: y,
      "font-family": @font,
      "font-size": 27,
      "letter-spacing": 3,
      fill: @muted,
      content: escaped
    )
  end

  # The heading indents past the avatar disc when one is present.
  defp heading_x(%OG{avatar: nil}), do: @margin
  defp heading_x(%OG{avatar: login}) when is_binary(login), do: @margin + 100

  defp avatar_disc(nil, _top), do: nil

  defp avatar_disc(login, top) when is_binary(login) do
    radius = 40
    cx = @margin + radius
    cy = top + radius

    initial =
      case login |> String.replace(~r/[^\w]/, "") |> String.first() do
        nil -> "?"
        "" -> "?"
        char -> String.upcase(char)
      end

    circle =
      tag("circle",
        cx: cx,
        cy: cy,
        r: radius,
        fill: @accent,
        "fill-opacity": 0.35,
        stroke: @accent_bright,
        "stroke-width": 2
      )

    glyph =
      tag("text",
        x: cx,
        y: cy + 15,
        "text-anchor": "middle",
        "font-family": @font,
        "font-size": 44,
        "font-weight": 600,
        fill: @accent_bright,
        content: initial
      )

    [circle, glyph]
  end

  # `top` marks where the first line's ink begins; SVG baselines sit a full em
  # below that, and successive lines step by 1.18em.
  defp heading_block([], _size, _top, _x), do: nil

  defp heading_block(lines, size, top, x) when is_list(lines) do
    Enum.map(Enum.with_index(lines), fn {line, index} ->
      baseline = trunc(top + size * (1 + index * 1.18))

      tag("text",
        x: x,
        y: baseline,
        "font-family": @font,
        "font-size": size,
        "font-weight": 600,
        fill: @text,
        content: OG.escape(line)
      )
    end)
  end

  defp text_lines([], _size, _fill, _ys), do: nil

  defp text_lines(lines, size, fill, ys) when is_list(lines) and is_list(ys) do
    Enum.map(Enum.zip(lines, ys), fn {line, y} ->
      tag("text",
        x: @margin,
        y: y,
        "font-family": @font,
        "font-size": size,
        fill: fill,
        content: OG.escape(line)
      )
    end)
  end

  defp chips_row(_y, []), do: nil

  defp chips_row(y, chips) do
    {elements, _final_x} =
      chips
      |> Enum.take(5)
      |> Enum.map_reduce(@margin, fn chip, x ->
        label = OG.clamp(chip.label, 34)
        color = Map.get(chip, :tone) && Map.get(@state_colors, chip.tone)

        width = max(String.length(label) * 14 + 46, 96)

        rect_attrs =
          if color do
            [fill: color, "fill-opacity": 0.16, stroke: color, "stroke-width": 2]
          else
            [fill: @surface, stroke: @line, "stroke-width": 2]
          end

        rect =
          tag("rect", Keyword.merge([x: x, y: y, width: width, height: 50, rx: 25], rect_attrs))

        label_text =
          tag("text",
            x: x + div(width, 2),
            y: y + 33,
            "text-anchor": "middle",
            "font-family": @font,
            "font-size": 26,
            fill: color || @muted,
            content: OG.escape(label)
          )

        {[rect, label_text], x + width + 18}
      end)

    elements
  end

  defp stats_row(_y, []), do: nil

  defp stats_row(y, stats) do
    joined =
      stats
      |> Enum.take(4)
      |> Enum.map(&OG.clamp(&1, 44))
      |> Enum.join("   ·   ")

    [
      tag("text",
        x: @margin,
        y: y,
        "font-family": @font,
        "font-size": 29,
        fill: @muted,
        content: OG.escape(joined)
      )
    ]
  end

  # Provenance sits right-aligned on the stats line: quiet, but present.
  defp provenance(nil), do: nil
  defp provenance(""), do: nil

  defp provenance(text) do
    [
      tag("text",
        x: @width - @margin,
        y: @stats_y,
        "text-anchor": "end",
        "font-family": @font,
        "font-size": 27,
        fill: @muted,
        content: OG.escape(OG.clamp(text, 40))
      )
    ]
  end

  defp footer do
    # The mark is drawn a shade smaller than the wordmark's cap height, which
    # is what keeps a glyph from outweighing the words beside it.
    scale = 0.62
    translate_y = @footer_y - trunc(BrandMark.height() * scale)

    # Strokes, not fills: the glyph is a ring with a gap and a bar, and both
    # keep their round caps only as strokes. `vector-effect` is deliberately
    # absent — the card is rasterized once at a fixed size, so the stroke
    # scales with the group exactly as the geometry does.
    mark =
      tag("g",
        transform: "translate(#{@margin}, #{translate_y}) scale(#{scale})",
        fill: "none",
        stroke: @muted,
        "stroke-width": BrandMark.stroke_width(),
        "stroke-linecap": "round",
        content: Enum.map(BrandMark.paths(), &tag("path", d: &1))
      )

    wordmark =
      tag("text",
        x: @width - @margin,
        y: @footer_y,
        "text-anchor": "end",
        "font-family": @font,
        "font-size": 27,
        fill: @muted,
        content: "openagents.com"
      )

    [mark, wordmark]
  end

  ## Emitter ------------------------------------------------------------------

  # One element builder so every attribute value passes through a single
  # quoting rule; nothing string-concatenates half-escaped fragments.
  defp tag(name, attrs) when is_binary(name) and is_list(attrs) do
    {content, attributes} = Keyword.pop(attrs, :content)

    rendered =
      Enum.map(attributes, fn {key, value} ->
        ~s( #{key}=") <> escape_attr_value(attr_string(value)) <> ~s(")
      end)

    open = "<" <> name <> Enum.join(rendered)

    case content do
      nil -> [open <> "/>"]
      parts when is_list(parts) -> [[open <> ">"] ++ parts ++ ["</" <> name <> ">"]]
      part when is_binary(part) -> [[open <> ">" <> part <> "</" <> name <> ">"]]
    end
  end

  defp attr_string(value) when is_integer(value), do: Integer.to_string(value)
  defp attr_string(value) when is_float(value), do: Float.to_string(value)
  defp attr_string(:middle), do: "middle"
  defp attr_string(:end), do: "end"
  defp attr_string(value) when is_binary(value), do: value

  defp escape_attr_value(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
