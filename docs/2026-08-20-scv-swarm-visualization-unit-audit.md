# SCV swarm visualization: porting Unit's visual language to Elixir

Date: 2026-08-20

Status: Proposed — audit and design, no implementation

Subject: how to render a live swarm of SCVs (15+ concurrently) in the visual
language of [Unit](https://github.com/samuelmtimbo/unit), implemented natively
in Elixir, Phoenix, HEEx, and LiveView rather than ported as TypeScript.

Reference read: `github.com/samuelmtimbo/unit` at revision `ea1b4d7e`, MIT
licensed (UNIT IO, Inc, 2021). 1,639 TypeScript files. Every line reference
below is to that revision; paths are repository-relative.

---

## 0. The claim

Unit's visual language is a good fit for the SCV swarm, and the reason is
structural rather than aesthetic.

Unit renders **MIMO finite state machines connected by typed links**. Its
README states that formally: "units are Multi Input Multi Output (MIMO) Finite
State Machines (FSM). A program in Unit is represented as a Graph."

An SCV is exactly that shape. `docs/scv-planning.md` defines an SCV as a durable
FSM with five states (`disabled`, `idle`, `running`, `paused`, `circuit_open`),
typed inputs (`scv_work_items`, themselves a state machine across `discovered`
→ `admitted` → `running` → `completed`/`deferred`/`refused`/`failed`), and typed
outputs (candidates handed to the Forge deployment pipeline). `scv_steps` is
specified to "store every provider and tool boundary in order" — an ordered
dataflow trace.

So a swarm view is not a metaphor laid over unrelated data. It is a faithful
rendering of the data model the SCV plan already specifies. That is the
difference between a visualization that stays true as the system evolves and a
dashboard that drifts into decoration.

**What we should take is the vocabulary, not the codebase.** §3 argues we
should deliberately *not* port Unit's force simulation, which is its single
largest visual subsystem.

## 1. Unit's visual language, distilled

Extracted from the source rather than the docs. The whole language is small,
which is what makes it portable.

### 1.1 Node shape carries type

`Editor/Component.ts:7468`:

```ts
borderRadius: is_component ? '0' : '50%'
```

**Units are circles. Components are squares.** One property, and the graph
becomes readable at a glance — you can see which nodes are live processes and
which are composed surfaces without reading a label. The `Shape` type is
exactly two values (`client/util/geometry/index.ts:575`):

```ts
export type Shape = 'circle' | 'rect'
```

### 1.2 Links attach to surfaces, not centers

This is the detail that makes Unit graphs look designed rather than generated.
A link is a straight segment between two points computed on the node
*boundaries* (`Editor/Component.ts:14188`):

```ts
const { x: x0, y: y0 } = pointInNode(source, u, padding_source)
const { x: x1, y: y1 } = pointInNode(target, nu, padding_target)
const path_d = `M ${x0} ${y0} L ${x1} ${y1}`
```

Naive graph renderers draw center-to-center and hide the overlap behind opaque
nodes. Unit computes the surface intersection, so link length encodes real
separation and the arrowhead sits flush against the node.

The geometry module supplies the primitives: `pointInNode`, `surfaceDistance`,
`centerToSurfaceDistance`, `unitVector`, `describeArc`, `describeCircle`,
`describeRect`, `describeArrowPolygon`, `catmullRomSpline`.

### 1.3 Arrowheads conform to the surface they touch

`Editor/Component.ts:856`:

```ts
export const describeArrowShape = (shape: Shape, r: number): string => {
  if (shape === 'circle') return describeArrowSemicircle(r)
  else return ARROW_FLAT
}
```

A link into a circle terminates in an arc that hugs the circumference; a link
into a rect terminates in a flat bar. The marker alphabet is four strings
(`Editor/Component.ts:925`):

```ts
export const ARROW_NONE   = ''
export const ARROW_MEMORY = 'M-6,4 L0,1 L-6,-2'
export const ARROW_NORMAL = 'M-0.25,2.25 L2,1 L-0.25,-0.25'
export const ARROW_FLAT   = 'M0,8 L0,-5.5'
```

Four path strings and one conditional carry the entire edge-termination
vocabulary. That is the level of economy worth copying.

### 1.4 Link labels ride the link

`Editor/Component.ts:14194` sets the same `d` on three overlaid paths: the
visible stroke, a wider invisible `link_base_area` for hit-testing, and
`link_base_text` used as a `textPath` anchor. When a link runs right-to-left the
component swaps in the inverted path so the label never renders upside down, and
flips the markers with `transform: scaleX(-1)`.

Three paths per link, one geometry calculation. The hit area being a separate
wider path is why Unit graphs are pleasant to click at any zoom.

### 1.5 Distance is typed

`src/constant/LINK_DISTANCE.ts` — link length is a semantic property, not a
layout constant:

```ts
export const LINK_DISTANCE          = 24
export const LINK_DISTANCE_TYPE     = LINK_DISTANCE / 2      // 12
export const LINK_DISTANCE_DATA     = LINK_DISTANCE / 2      // 12
export const LINK_DISTANCE_ERR      = LINK_DISTANCE * 7 / 8  // 21
export const LINK_DISTANCE_EXPOSED  = LINK_DISTANCE * 2 / 3  // 16
```

Type relationships sit closer than dataflow; errors sit closer than normal
links. Proximity encodes kind.

### 1.6 Layers, not z-index soup

Ten named layers (`Editor/Component.ts`): `LAYER_NORMAL`, `LAYER_COLLAPSE`,
`LAYER_SEARCH`, `LAYER_IGNORED`, `LAYER_EXPOSED`, `LAYER_DATA_LINKED`,
`LAYER_DATA`, `LAYER_ERR`, `LAYER_TYPE`, with
`LAYER_OPACITY_MULTIPLIER = 0.1`. Depth is a small enum and opacity is derived
from it, so nothing competes for arbitrary stacking values.

### 1.7 The palette is greyscale-first

`client/theme.ts` is a twelve-rung greyscale ramp (`COLOR_GRAYSCALE_BASE00`
`#FCFCFC` through `BASE11` `#080808`) plus a handful of named accents, each with
a paired darker "link" variant:

```ts
COLOR_RED   = '#ff6666'   COLOR_LINK_RED   = '#ff4d4d'
COLOR_GREEN = '#00aa11'   COLOR_LINK_GREEN = '#0b8e14'
COLOR_BLUE  = '#0066ff'   COLOR_LINK_BLUE  = '#1d62c9'
```

**This is directly compatible with the palette this repo just adopted.**
`assets/css/app.css` now carries Linear's neutral ramp (`#08090a` → `#f7f8f8`)
with a single indigo accent. Unit's structure — a long neutral ramp plus sparse
semantic accents, with links a shade darker than fills — maps onto our existing
tokens without introducing a third palette, which `UI-003` forbids
(`INVARIANTS.md:1520`: "not introduce a third palette").

The port should use `--ink-*`, `--text-*`, `--line-*`, `--wash-*` and the
existing `--success` / `--warning` / `--danger` / `--accent`, never Unit's hex
literals.

## 2. Mapping SCV state onto the language

| SCV concept | Visual |
| --- | --- |
| One SCV | Circle node. It is a live FSM, so it takes the circle. |
| Work item | Rect node. Composed, inert data, not a running process. |
| Candidate / Forge handoff | Rect node terminating the chain. |
| SCV status | Ring treatment: `idle` hairline, `running` accent ring, `paused` dashed, `circuit_open` danger ring, `disabled` faint. |
| Run phase | Node fill wash, stepped through `--wash-hover` → `--wash-selected`. |
| `scv_steps` | Pulse travelling along the outbound link, one per boundary. |
| Tool call vs provider call | Link kind, hence link distance (§1.5) and marker (§1.3). |
| Error / `error_event_count` | `LAYER_ERR` equivalent: danger stroke, shorter link distance so failures visibly cluster. |
| Token / cost / CPU usage | Node radius, bounded. Cheap runs stay small; expensive ones are visibly large. |
| Repository scope | Spatial grouping — one cluster per repository. |

The 15-agent view the request asks for is then: fifteen circles, each with a
short outbound chain to its current work item and candidate, sized by spend,
ringed by status, pulsing on each step. Clicking a circle drills into that
SCV's run.

## 3. Do not port the force simulation

`client/simulation.ts` is 355 self-contained lines implementing a Runge-Kutta
integrated force layout (RK1 through RK4, selectable via a `stability` option),
with no d3 dependency. It is genuinely nice code and it would port to Elixir
cleanly.

**We should still not use it, and this is the main design opinion in this
document.**

Unit needs a force simulation because its graphs are user-authored and
arbitrary: an author drops units anywhere and the simulation finds a readable
arrangement. Our graph is not arbitrary. The SCV pipeline has a known shape —
work item → SCV → run → candidate → Forge — which is a staged DAG with a fixed
number of stages.

For a known DAG, a force simulation is strictly worse:

- **It moves when nothing meaningful changed.** An operator watching 15 agents
  needs to notice *state* changes. A layout that drifts on every tick trains
  them to ignore motion, which is the one channel that should mean something.
- **Position stops being an identifier.** With a stable layout, "the third one
  down is stuck again" is a real observation. With a simulation, node identity
  has to be re-read from labels every time.
- **It costs continuously.** A simulation must tick to converge. A staged layout
  is computed once per topology change.

Use a deterministic staged layout: column per pipeline stage, stable vertical
ordering within a column (by SCV id, never by a mutable field like score, or
rows will swap under the operator's cursor). Keep Unit's *geometry* — surface
anchoring, conforming arrowheads, typed distances — which is what actually makes
it look like Unit.

Keep the simulation in mind for one later case: a free "swarm" view where
clustering by repository or failure mode is the point and exact position is not.
If we build that, port `simulation.ts` then, with measurements.

## 4. Elixir and Phoenix implementation

### 4.1 Render SVG server-side in HEEx

The geometry is arithmetic. Elixir does arithmetic. There is no reason for a
client-side graph library.

```elixir
defmodule OpenAgentsWeb.UI.Graph do
  @moduledoc """
  SVG graph primitives in Unit's visual language: circular unit nodes,
  rectangular data nodes, and links anchored to node surfaces with
  shape-conforming terminations.

  Ported from Unit (https://github.com/samuelmtimbo/unit), MIT licensed,
  UNIT IO Inc. Geometry reimplemented in Elixir; no Unit code is vendored.
  """

  @pin_radius 5
  @link_distance 24

  @doc "The point where a link meets a node's surface, per Unit's pointInNode."
  def surface_point(%{shape: :circle, x: x, y: y, r: r}, {ux, uy}, padding) do
    {x + ux * (r + padding), y + uy * (r + padding)}
  end

  def surface_point(%{shape: :rect} = node, {ux, uy}, padding) do
    # rect surface intersection along the unit vector
  end

  def unit_vector({x0, y0}, {x1, y1}) do
    dx = x1 - x0
    dy = y1 - y0
    case :math.sqrt(dx * dx + dy * dy) do
      0.0 -> {0.0, 0.0}
      d -> {dx / d, dy / d}
    end
  end
end
```

Nodes and links become function components rendering `<circle>`, `<rect>`,
`<path>`. State changes are ordinary LiveView assigns; Phoenix sends attribute
diffs, and CSS transitions animate them. For fifteen nodes this is far less data
over the wire than a JS graph library's state sync.

### 4.2 Animate in CSS, not in a render loop

Ring colour, fill wash, and radius are attributes. Give them a transition in the
style pack and every state change animates for free. Step pulses are a
`<circle>` on a `<path>` with SMIL `<animateMotion>`, or a CSS
`offset-path` animation — no JS, no timer.

This matters for a 15-agent view: a render loop for 15 animated nodes is a
render loop you pay for even when nothing is happening. Declarative animation
costs nothing while idle.

### 4.3 Reach for a colocated hook only for pan and zoom

Pan and zoom are pointer-rate interactions and must not round-trip. That is a
small colocated hook mutating one `viewBox` attribute — the pattern already used
in `chat_live.ex` (`phx-hook=".SidebarShell"`, `phx-hook=".TranscriptScroll"`).
Unit's `ZOOM_INTENSITY = 0.05` is a good starting constant.

Everything else — selection, drill-down, filtering — is a LiveView event.

### 4.4 The invariant constraints this must satisfy

- **`UI-003`** (`INVARIANTS.md:1499`): product surfaces render only through the
  sanctioned component library, with no third palette. So graph primitives go in
  the governed component module (`OpenAgentsWeb.UI` in
  `lib/openagents_web/components/ui.ex`, or a `UI.Graph` submodule beside it), styled from existing tokens.
- **The component catalog is enforced by test.** `ComponentCatalogTest` walks
  `__components__/0` for every documented module and fails when a public
  function component has no catalog entry. Every new graph primitive needs a
  `ComponentCatalog` entry and a `component_demo/1` clause, or the suite fails.
  That is a feature — the catalog stays honest — but it is work to budget.
- **No hosted CI** (`RELEASE-004`). Tests run on owned infrastructure.
- **Basecoat components are imported individually**; never
  `basecoat.css`/`basecoat-base.css`/`basecoat-components.css`.

### 4.5 Licensing

Unit is MIT (UNIT IO, Inc, 2021), which is compatible with this repo's AGPL-3.0.
The workspace contract says reference repos are read-only and "do not vendor or
copy large chunks of external code into our repos by default."

So: **reimplement the geometry in Elixir, attribute Unit in the module docs, do
not vendor TypeScript.** The values worth carrying verbatim are constants
(`PIN_RADIUS = 5`, `LINK_DISTANCE = 24` and its typed variants,
`ZOOM_INTENSITY = 0.05`) and the four arrow path strings, all of which are facts
about a visual language rather than substantial code.

## 5. What exists today

Honest current state, verified at `d247a8a`:

**The SCV runtime exists in embryo — 647 lines total:**

| module | lines |
| --- | --- |
| `lib/openagents/scv/worker.ex` | 213 |
| `lib/openagents/scv/open_code_events.ex` | 164 |
| `lib/openagents/scv/run.ex` | 146 |
| `lib/openagents/scv/environment.ex` | 42 |
| `lib/openagents/scv/resource_sampler.ex` | 33 |
| `lib/openagents/scv.ex` | 21 |
| `lib/openagents/scv/driver.ex`, `runner.ex` | 28 |

**There is no SCV web surface at all.** Nothing under `lib/openagents_web/`
references SCV. This proposal is the first.

**The durable tables are specified but unbuilt.** `docs/scv-planning.md`
specifies `scvs`, `scv_work_items`, `scv_runs`, `scv_steps`, and
`scv_worker_images`. None exist as migrations. `SCV.Run` is a plain struct, not
an Ecto schema.

**So bind to what is real today**, and widen later:

- `OpenAgents.SCV.OpenCodeEvents.summary/1` already returns `event_count`,
  `event_types`, `tool_calls`, `tool_outcomes`, `usage`, `error_event_count`,
  and `session_ids`. That is enough to drive node fill, radius, error state, and
  a step counter for a single run **now**.
- `OpenAgents.SCV.ResourceSampler.sample/1` supplies resource figures for radius.
- A multi-SCV view needs the `scvs` and `scv_runs` tables. Until they exist,
  a swarm view can only show runs the node itself is supervising — real, but not
  the fleet-wide picture the 15-agent view implies.

This ordering matters. Building the visualization against the planned schema
before the schema exists would produce a component that renders fixtures and
nothing else.

## 6. Suggested sequence

1. **`UI.Graph` geometry module + tests.** Pure functions: `unit_vector/2`,
   `surface_point/3` for circle and rect, `arrow_path/2`, `describe_arc/5`.
   Property-tested — a link must terminate on the boundary for every angle, and
   that is exactly the kind of thing property tests are good at.
2. **Static node and link components**, catalogued per §4.4, demoed with
   fixtures.
3. **Single-run view** bound to `OpenCodeEvents.summary/1` and
   `ResourceSampler.sample/1` — real data, one SCV, no new schema required.
4. **`scvs` / `scv_runs` schema** per the SCV plan, whenever that work is
   scheduled on its own merits.
5. **Swarm view** over that schema: N circles, staged layout, status rings.
6. **Pan/zoom hook**, only once the static view is worth navigating.
7. **Drill-down**: click an SCV → its run → its steps.

Steps 1–3 deliver something real without depending on unbuilt schema. Step 5 is
the deliverable the request describes, and it is gated on step 4, which is a
separate decision.

## 7. Risks and open questions

- **Fifteen is not the hard case; a hundred is.** A staged layout degrades
  gracefully to a scrollable column set; a force simulation degrades to a hairball.
  Another argument for §3, but the swarm view should still declare its bound.
- **Step pulses could become noise.** If every provider and tool boundary emits a
  visible pulse, a busy SCV is a strobe. Rate-limit at the projection, not in
  CSS — one pulse per N steps with a count, in the spirit of `LAYER_OPACITY_MULTIPLIER`.
- **`scv_steps` volume.** The plan says steps store "every provider and tool
  boundary in order." Fifteen concurrent SCVs will produce a high-rate stream. The
  swarm view must subscribe to a bounded projection, never the raw step table —
  the same rule `UI-002` already applies to tool activity.
- **Unit's language is monochrome-leaning by design.** It survives on shape,
  proximity, and opacity, using colour sparingly. That suits our palette but means
  status must be legible without colour — hence ring *style* (hairline, dashed,
  heavy) carrying status alongside hue, which also makes it colour-blind safe.
- **Naming.** Unit calls its nodes "units". We already use "unit" for other
  things and `SCV` is a fixed term per the SCV plan ("Use SCV consistently in
  code, documentation, configuration, and the interface. Do not introduce another
  name for this subsystem."). Call the primitives `graph_node` / `graph_link`,
  never `unit`.
