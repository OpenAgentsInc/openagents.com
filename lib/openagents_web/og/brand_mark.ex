defmodule OpenAgentsWeb.OG.BrandMark do
  @moduledoc """
  The OpenAgents mark, as geometry rather than as a file.

  The product's mark is the power glyph in `priv/static/favicon.ico` — the same
  image the application shell renders beside the wordmark. The card templates
  cannot read a file at render time and must emit no remote reference, so the
  glyph lives here as path data.

  `priv/static/images/logo.svg` carries the same two paths for the pages that
  reference a file rather than this module; both were derived from the same
  measurements, and a change to one belongs in the other.

  It is a redrawing, not a trace: the ring's centre, radius, stroke, and the
  arc's gap were measured off the icon's 256-pixel variant and divided down to
  a 48-unit box, so the vector matches the raster it came from at any size a
  card is scaled to. That is why the numbers below are not round.

  Both paths are strokes, not fills. A stroked ring is one arc and one line; the
  same shape as a fill would be four paths and a subtraction, and it would lose
  the round caps that give the glyph its weight.
  """

  # Measured from the 256px favicon: ring centre (126, 132), outer radius 70,
  # stroke 16, bar from y=61 to y=116 on the centre line, and an arc gap of
  # ±26° about the top. Divided by 149 (the glyph's own height) and multiplied
  # by 48.
  @size 48
  @stroke 5.15
  @ring_radius 20.0

  # The gap sits at the top, so the arc runs from 26° clockwise round to 334°,
  # measuring from twelve o'clock. Endpoints: 24 ± 20·sin 26°, 25.45 − 20·cos 26°.
  @ring "M32.77 7.47A#{@ring_radius} #{@ring_radius} 0 1 1 15.23 7.47"
  @bar "M24 2.58V20.29"

  @doc "The ring's arc, as SVG path data on a 48×48 canvas."
  def ring, do: @ring

  @doc "The bar above the ring, as SVG path data on the same canvas."
  def bar, do: @bar

  @doc "Both paths of the mark, in drawing order."
  def paths, do: [@ring, @bar]

  @doc "Stroke width the paths are drawn with, in canvas units."
  def stroke_width, do: @stroke

  @doc "Width of the mark's viewBox."
  def width, do: @size

  @doc "Height of the mark's viewBox."
  def height, do: @size
end
