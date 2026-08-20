defmodule OpenAgentsWeb.UI.Graph do
  @moduledoc """
  SVG graph primitives for rendering live SCV work as a dataflow graph.

  The visual language is ported from [Unit](https://github.com/samuelmtimbo/unit)
  (MIT, UNIT IO Inc). The geometry is reimplemented in Elixir; no Unit code is
  vendored. The design rationale and the source citations for each rule live in
  `docs/2026-08-20-scv-swarm-visualization-unit-audit.md`.

  Four rules carry the whole language:

    1. **Shape carries kind.** A circle is a live finite state machine — an SCV.
       A rect is inert composed data — a work item, a candidate. You can read
       what a node *is* without reading its label.
    2. **Links meet surfaces, not centers.** A link terminates on the node
       boundary, so its drawn length is the real separation between two nodes
       rather than a segment hidden under an opaque fill.
    3. **Terminations conform to the surface they touch.** An arrow into a
       circle is an arc struck on that circle's circumference; an arrow into a
       rect is a flat bar.
    4. **Proximity encodes kind.** Link distance is a property of the link's
       type, not a global layout constant, so related things sit closer.

  Colour comes only from the sanctioned palette tokens (`UI-003`); no hex
  literal from Unit's theme appears here. Status is expressed by ring *style*
  as well as hue so the taxonomy stays legible without colour.
  """

  use Phoenix.Component

  # Unit's constants, carried verbatim as facts about the visual language.
  # src/constant/PIN_RADIUS.ts and src/constant/LINK_DISTANCE.ts.
  @pin_radius 5
  @link_distance 24

  @doc "Base link distance in user units. Typed variants derive from it."
  def link_distance, do: @link_distance

  @doc "Pin radius in user units."
  def pin_radius, do: @pin_radius

  @doc """
  Link distance for a link kind.

  Type and data relationships sit at half distance; errors sit slightly closer
  than a normal link so failures visibly cluster; exposed links sit at
  two-thirds. Same ratios as Unit's `LINK_DISTANCE.ts`.
  """
  def link_distance(:type), do: @link_distance / 2
  def link_distance(:data), do: @link_distance / 2
  def link_distance(:error), do: @link_distance * 7 / 8
  def link_distance(:exposed), do: @link_distance * 2 / 3
  def link_distance(_normal), do: @link_distance

  @doc """
  The unit vector from one point to another.

  Returns `{0.0, 0.0}` for coincident points rather than dividing by zero — two
  nodes at the same position have no meaningful direction between them.
  """
  def unit_vector({x0, y0}, {x1, y1}) do
    dx = x1 - x0
    dy = y1 - y0

    d = :math.sqrt(dx * dx + dy * dy)

    # `== 0` rather than a `0.0` pattern: it covers both signed zeros without
    # asserting which one sqrt produced.
    if d == 0, do: {0.0, 0.0}, else: {dx / d, dy / d}
  end

  @doc """
  The point where a link leaves a node's surface, travelling along `vector`.

  This is Unit's `pointInNode`. For a circle it is the centre pushed out by the
  radius; for a rect it is the intersection with whichever edge the vector
  actually crosses, found by scaling the vector to the nearer axis bound.
  """
  def surface_point(node, vector, padding \\ 0)

  def surface_point(%{shape: :circle, x: x, y: y, r: r}, {ux, uy}, padding) do
    {x + ux * (r + padding), y + uy * (r + padding)}
  end

  def surface_point(%{shape: :rect, x: x, y: y, width: w, height: h}, {ux, uy}, padding) do
    hw = w / 2 + padding
    hh = h / 2 + padding

    # Scale the unit vector until it first crosses a bound. The smaller ratio is
    # the edge it actually leaves through.
    tx = if ux == 0, do: :infinity, else: abs(hw / ux)
    ty = if uy == 0, do: :infinity, else: abs(hh / uy)
    t = min(tx, ty)

    case t do
      :infinity -> {x, y}
      t -> {x + ux * t, y + uy * t}
    end
  end

  @doc """
  An SVG arc path, used for circle-conforming arrow terminations.

  Angles are in degrees, measured as Unit measures them.
  """
  def describe_arc(cx, cy, r, start_angle, end_angle) do
    {sx, sy} = polar_to_cartesian(cx, cy, r, end_angle)
    {ex, ey} = polar_to_cartesian(cx, cy, r, start_angle)
    large_arc = if end_angle - start_angle <= 180, do: "0", else: "1"

    "M #{f(sx)} #{f(sy)} A #{f(r)} #{f(r)} 0 #{large_arc} 0 #{f(ex)} #{f(ey)}"
  end

  defp polar_to_cartesian(cx, cy, r, angle_degrees) do
    rad = (angle_degrees - 90) * :math.pi() / 180.0
    {cx + r * :math.cos(rad), cy + r * :math.sin(rad)}
  end

  defp f(n) when is_float(n), do: Float.round(n, 2)
  defp f(n), do: n

  @statuses ~w(idle running paused circuit_open disabled)a
  @item_statuses ~w(discovered admitted running completed deferred refused failed)a
  @link_kinds ~w(normal type data error exposed)a

  @doc "Every SCV status this component renders, in lifecycle order."
  def statuses, do: @statuses

  @doc "Every work-item status this component renders, in lifecycle order."
  def item_statuses, do: @item_statuses

  @doc "Every link kind this component renders."
  def link_kinds, do: @link_kinds

  @doc """
  One node in the graph.

  A `:circle` is a live SCV; a `:rect` is a work item or candidate. `status`
  drives the ring treatment and is validated against the SCV or work-item
  lifecycle depending on shape, so an impossible state cannot be rendered.
  """
  attr :id, :string, required: true
  attr :shape, :atom, values: [:circle, :rect], default: :circle
  attr :x, :float, required: true
  attr :y, :float, required: true
  attr :r, :float, default: 22.0, doc: "radius for a circle node"
  attr :width, :float, default: 44.0, doc: "width for a rect node"
  attr :height, :float, default: 32.0, doc: "height for a rect node"
  attr :status, :atom, default: :idle
  attr :label, :string, default: nil
  attr :selected, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global

  def graph_node(assigns) do
    ~H"""
    <g
      class={["graph-node", @selected && "graph-node--selected", @class]}
      data-status={@status}
      data-shape={@shape}
      role="img"
      aria-label={@label || @id}
      {@rest}
    >
      <circle :if={@shape == :circle} class="graph-node__body" cx={@x} cy={@y} r={@r} />
      <rect
        :if={@shape == :rect}
        class="graph-node__body"
        x={@x - @width / 2}
        y={@y - @height / 2}
        width={@width}
        height={@height}
        rx="2"
      />
      <text :if={@label} class="graph-node__label" x={@x} y={@y + label_offset(@shape, @r, @height)}>
        {@label}
      </text>
    </g>
    """
  end

  defp label_offset(:circle, r, _h), do: r + 12
  defp label_offset(:rect, _r, h), do: h / 2 + 12

  @doc """
  A link between two nodes, anchored to both surfaces.

  Renders three coincident paths, as Unit does: the visible stroke, a wider
  transparent hit area, and a text anchor. The hit area is why a one-pixel link
  is still clickable.
  """
  attr :id, :string, required: true
  attr :source, :map, required: true, doc: "node map with shape, x, y and r or width/height"
  attr :target, :map, required: true
  attr :kind, :atom, values: @link_kinds, default: :normal
  attr :active, :boolean, default: false, doc: "a step is currently traversing this link"
  attr :label, :string, default: nil
  attr :prefix, :string, default: "graph", doc: "marker namespace; must match graph_defs/1"
  attr :class, :any, default: nil

  def graph_link(assigns) do
    u = unit_vector({assigns.source.x, assigns.source.y}, {assigns.target.x, assigns.target.y})
    {nux, nuy} = u
    {x0, y0} = surface_point(assigns.source, u, 1)
    {x1, y1} = surface_point(assigns.target, {-nux, -nuy}, 1)

    assigns =
      assigns
      |> assign(:d, "M #{f(x0)} #{f(y0)} L #{f(x1)} #{f(y1)}")
      |> assign(:marker, "#{assigns.prefix}-#{marker_id(assigns.target)}")

    ~H"""
    <g class={["graph-link", @active && "graph-link--active", @class]} data-kind={@kind}>
      <path class="graph-link__hit" d={@d} />
      <path class="graph-link__base" d={@d} marker-end={"url(##{@marker})"} />
      <path :if={@label} id={"#{@id}-text"} class="graph-link__text-path" d={@d} />
      <text :if={@label} class="graph-link__label">
        <textPath href={"##{@id}-text"} startOffset="50%">{@label}</textPath>
      </text>
      <circle :if={@active} class="graph-link__pulse" r={pin_radius() / 2}>
        <animateMotion dur="1.1s" repeatCount="indefinite" path={@d} />
      </circle>
    </g>
    """
  end

  defp marker_id(%{shape: :circle}), do: "arrow-semicircle"
  defp marker_id(_rect), do: "arrow-flat"

  @doc """
  The marker and filter definitions every graph surface needs.

  SVG marker references resolve document-wide, not per `<svg>`, so one instance
  per page is normally enough. `prefix` exists so two independent graph surfaces
  on the same page can each own their markers rather than colliding — the
  failure mode a component with hardcoded ids always eventually hits.
  """
  attr :prefix, :string, default: "graph", doc: "marker namespace; must match graph_link/1"

  def graph_defs(assigns) do
    assigns = assign(assigns, :semicircle, describe_arc(6.0, 6.0, 5.0, 210, 330))

    ~H"""
    <defs>
      <marker
        id={"#{@prefix}-arrow-semicircle"}
        viewBox="0 0 12 12"
        refX="11"
        refY="6"
        markerWidth="7"
        markerHeight="7"
        orient="auto-start-reverse"
      >
        <path class="graph-arrow" d={@semicircle} />
      </marker>
      <marker
        id={"#{@prefix}-arrow-flat"}
        viewBox="0 0 12 12"
        refX="11"
        refY="6"
        markerWidth="7"
        markerHeight="7"
        orient="auto-start-reverse"
      >
        <path class="graph-arrow" d="M 11 1 L 11 11" />
      </marker>
    </defs>
    """
  end

  @doc """
  The host element for a graph.

  Callers should not hand-write the root element: it carries the marker
  definitions, the viewBox, and the accessible name, and getting any of those
  wrong is silent. `graph_surface/1` is also why no other module needs inline
  vector markup.
  """
  attr :id, :string, default: nil
  attr :view_box, :string, required: true
  attr :label, :string, required: true
  attr :prefix, :string, default: "graph"
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def graph_surface(assigns) do
    ~H"""
    <svg
      id={@id}
      class={["graph-surface", @class]}
      viewBox={@view_box}
      role="img"
      aria-label={@label}
    >
      <.graph_defs prefix={@prefix} />
      {render_slot(@inner_block)}
    </svg>
    """
  end

  @doc """
  SCVs beside what each one is currently saying.

  The swarm answers "how is the fleet", this answers "what is it doing". A
  status ring tells you an SCV is running; it cannot tell you it has been
  rewriting the same test for four minutes. The stream can.

  Each row is one SCV: its node, its identity, and the tail of its output. Rows
  keep a fixed height so a chatty agent cannot push the others off screen —
  fifteen rows that stay put are readable, fifteen that reflow are not. The
  stream is a bounded tail, never the whole transcript: `scv_steps` is specified
  to record every provider and tool boundary, and rendering all of it would make
  a busy fleet unreadable and expensive at once.

  Each entry is a map with `:id`, `:status`, and optionally `:label`,
  `:weight`, `:tool` (the tool boundary currently open) and `:text` (the tail).
  """
  attr :id, :string, default: "scv-streams"
  attr :scvs, :list, required: true
  attr :selected_id, :string, default: nil
  attr :class, :any, default: nil

  def scv_streams(assigns) do
    ~H"""
    <ul id={@id} class={["scv-streams", @class]} role="list">
      <li
        :for={scv <- @scvs}
        class="scv-stream"
        data-status={scv.status}
        data-selected={scv.id == @selected_id}
      >
        <.graph_surface
          view_box="0 0 44 44"
          label={"#{Map.get(scv, :label, scv.id)}, #{scv.status}"}
          prefix={"#{@id}-#{scv.id}"}
          class="scv-stream__glyph"
        >
          <.graph_node
            id={"#{@id}-#{scv.id}-node"}
            x={22.0}
            y={22.0}
            r={13.0 + Map.get(scv, :weight, 0.0) * 5.0}
            status={scv.status}
          />
        </.graph_surface>

        <div class="scv-stream__body">
          <div class="scv-stream__meta">
            <span class="scv-stream__id">{Map.get(scv, :label, scv.id)}</span>
            <span :if={scv[:tool]} class="scv-stream__tool">{scv[:tool]}</span>
            <span class="scv-stream__status">{scv.status}</span>
          </div>
          <p class="scv-stream__text">
            {scv[:text]}<span
              :if={scv.status == :running}
              class="scv-stream__caret"
              aria-hidden="true"
            ></span>
          </p>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  A swarm of SCVs in a deterministic staged layout.

  Position is stable and derived from the index, never from a mutable field
  like score — an operator watching fifteen agents needs "the third one down"
  to keep meaning the same agent. The audit argues at length for why this is a
  staged layout rather than Unit's force simulation.

  Each entry is a map with `:id`, `:status`, and optionally `:label`, `:weight`
  (0.0–1.0, scales the radius by spend) and `:item_status`.
  """
  attr :id, :string, default: "scv-swarm"
  attr :scvs, :list, required: true
  attr :columns, :integer, default: 5
  attr :selected_id, :string, default: nil
  attr :class, :any, default: nil

  def scv_swarm(assigns) do
    assigns = assign(assigns, :placed, place(assigns.scvs, assigns.columns))

    ~H"""
    <svg
      id={@id}
      class={["graph-surface", @class]}
      viewBox={"0 0 #{@columns * 96} #{ceil(length(@scvs) / @columns) * 96}"}
      role="group"
      aria-label={"#{length(@scvs)} SCVs"}
    >
      <.graph_defs />
      <.graph_link
        :for={p <- @placed}
        :if={p.item}
        id={"#{p.scv.id}-link"}
        source={p.node}
        target={p.item}
        kind={link_kind_for(p.scv)}
        active={p.scv.status == :running}
      />
      <.graph_node
        :for={p <- @placed}
        :if={p.item}
        id={"#{p.scv.id}-item"}
        shape={:rect}
        x={p.item.x}
        y={p.item.y}
        width={p.item.width}
        height={p.item.height}
        status={Map.get(p.scv, :item_status, :discovered)}
      />
      <.graph_node
        :for={p <- @placed}
        id={p.scv.id}
        shape={:circle}
        x={p.node.x}
        y={p.node.y}
        r={p.node.r}
        status={p.scv.status}
        label={Map.get(p.scv, :label)}
        selected={p.scv.id == @selected_id}
        phx-click="select_scv"
        phx-value-id={p.scv.id}
      />
    </svg>
    """
  end

  defp link_kind_for(%{status: :circuit_open}), do: :error
  defp link_kind_for(_), do: :normal

  # Deterministic placement: column-major grid, ordered by the caller's order.
  defp place(scvs, columns) do
    scvs
    |> Enum.with_index()
    |> Enum.map(fn {scv, i} ->
      cx = rem(i, columns) * 96 + 34.0
      cy = div(i, columns) * 96 + 34.0
      weight = Map.get(scv, :weight, 0.0)

      node = %{shape: :circle, x: cx, y: cy, r: 14.0 + weight * 10.0}

      item =
        if scv.status in [:running, :paused] do
          %{shape: :rect, x: cx + 46.0, y: cy, width: 22.0, height: 16.0}
        end

      %{scv: scv, node: node, item: item}
    end)
  end
end
