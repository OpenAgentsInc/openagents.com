# Porting Circle's issue surfaces

*2026-08-20*

`OpenAgentsWeb.UI.Circle` is adapted from [Circle][circle], MIT-licensed,
© 2025 lndev-ui. This document records what was taken, what was not, and why —
so a later reader can tell which decisions are inherited and which are ours.
**The work list at the bottom is the tracker for this effort**: update it in the
same change that lands the work, not afterwards.

## What Circle is

Circle is a Linear-shaped issue, project, and team tracker: Next.js App Router,
TypeScript, Tailwind, shadcn/ui, Zustand for state, `nuqs` for URL state,
`motion/react` for layout animation, and `react-dnd` for the board. It ships no
backend — every surface reads a `mock-data` module — which makes it unusually
good source material, because the data shapes are stated plainly instead of
being inferred from an API.

This assessment uses revision `c60371c`, the tip of the local Circle checkout,
whose newest commit adds the ⌘K command palette. The licence is `LICENSE.md` at
the repository root: MIT, requiring the copyright notice be retained. Since this
is adaptation rather than copying, attribution lives in the module doc, in the
stylesheet section header, and here.

## What "porting" means here

Almost none of the code survives. Every component in `components/common/issues`
is a client component reading a Zustand store, and the interesting ones are
wrapped in Radix context menus, popovers, and dialogs. None of that moves to
HEEx.

What carried over is the **information design**, which is the expensive part and
transfers intact:

- what an issue row holds and in what order — that priority, identifier, and
  status form a fixed-width scan column on the leading edge, and that everything
  discretionary collects on the trailing edge where width can drop it;
- that the status glyph is a **filled arc**, not a coloured dot, so a list says
  how far along each piece of work is;
- that priority is one shape read at four levels, with urgent deliberately
  outside the ramp;
- that a group header carries a wash mixed from its own status, which is the
  only thing that marks a boundary once the header has scrolled past its rows;
- that a filter reads as subject / operator / value, with each segment its own
  control;
- that a card is not a row turned sideways.

## Deliberate departures

### Tokens, not a second palette

Circle assigns a hand-picked hex value to each of thirteen statuses
(`#facc15`, `#5e6ad2`, `#26b5ce`, …) and to each of eleven labels. Those
colours are Linear's. Adopting them would put a second colour system beside the
one every other surface uses, and the tracker would stop looking like the
product it is part of.

Colour here is assigned per status **category** — six of them — off the same
token ladder `OpenAgentsWeb.UI.status_indicator/1` already uses:

| Category | Token | Why |
| --- | --- | --- |
| `:triage` | `--warning` | awaiting a decision |
| `:backlog` | `--text-dim` | resting, not yet real |
| `:unstarted` | `--text-muted` | resting, real |
| `:started` | `--info` | activity, as everywhere else in the product |
| `:completed` | `--success` | done |
| `:canceled` | `--text-dim` | resting, closed |

Six colours say less than thirteen. That is the cost, and it is stated in the
component docs rather than hidden: `In progress`, `In review`, and `Blocked` are
all one blue here, and only the word tells them apart. In exchange the same
component is correct in both themes with no second set of declarations, and a
status glyph never disagrees with the status dot in the sidebar beside it.

Labels take the same treatment through a `tone` attribute over the same six
values. Because six tones cannot distinguish eleven labels, the label's **word**
is not optional in this port — the dot is a grouping hint, not the identity.

### No JavaScript, except where the keyboard needs it

Rows, cards, groups, boards, filters, headers, and every project, team, and
member row are server-rendered and carry no script.

The command palette is the one exception, and it is a real one: `⌘K` is a
document-level binding, incremental filtering means hiding rows as characters
arrive, and arrow-key selection has to survive both. The palette carries one
colocated hook doing exactly those things, following the pattern already
established by `copy_button/1` and `github_login/1`. It is built on native
`<dialog>`, so the browser supplies the focus trap, the backdrop, `Escape`, and
inertness of the page behind — the parts hand-built palettes usually get wrong.
Every command is a real `<button>` and does its job without the hook.

### No drag-and-drop

The source's board is `react-dnd`: a drag layer, a custom preview, per-column
drop targets, and a full-column overlay reading "Drop to update status". About
250 lines across two files, and the behaviour it buys is a status change.

`issue_board/1` and `issue_group/1` port the **layout** — columns side by side,
each scrolling on its own so a long backlog does not push the other headers off
the top. Changing an issue's status stays a control, which also means it works
on a touch screen and from a keyboard, neither of which the source's board does.

### State is the caller's

Circle keeps grouping, ordering, filters, search, display properties, and drag
results in eight Zustand stores, and every component reads them directly. That
is why `IssueLine` cannot be rendered anywhere the store is not.

None of these components own state. They take what to draw and emit
`Phoenix.LiveView.JS` commands the caller supplies. That is what makes the same
`issue_row/1` usable in a list, in a search result, and in a group, which is
three call sites in the source with three different wrappers.

## Icons

Every glyph resolves to the vendored Apps SDK set through
`OpenAgentsWeb.UI.icon/1`. **Nothing was vendored for this port.** The mapping
for the status shapes:

| Circle | Ours | Note |
| --- | --- | --- |
| triage disc with opposing arrows | `compare-arrows` | the same picture |
| dashed gear (backlog, idea) | `circle-dashed` | see below |
| empty ring (todo) | `empty-circle` | |
| ring with filled arc (in progress) | *drawn in CSS* | see below |
| filled tick (done, shipped) | `check-circle-filled` | |
| filled cross (cancelled) | `x-circle-filled` | |
| filled slash-equal (duplicate) | `x-circle-filled` | folded into cancelled |

Two of these need explaining.

**The dashed gear has no equivalent** and none was vendored. It is Linear's mark
for "this is not real work yet", and `circle-dashed` carries the same reading
with a shape already in the set. Vendoring a glyph for one status would put a
Linear-specific mark in a general icon set.

**The arc is not an icon.** Its fill is a number — the fraction of a project's
issues that are finished — so it cannot come from a fixed set. It is drawn in
CSS as a `conic-gradient` inside a ring, which is a handful of declarations, no
SVG, and correct at any percentage. The priority bars are drawn the same way for
the same reason: they are one shape read at four levels, not four pictures, and
lighting them from a `data-level` attribute keeps the ordering in one place.

Neither is inline SVG in a template, which `docs/ICONS.md` rules out. Both are
CSS-drawn indicators of the kind `status_indicator/1` already establishes.

## What we are not porting

Stated so nobody re-litigates it later:

- **`components/data-table-filter`** — about 2,000 lines implementing a typed
  filter engine (columns, operators, faceted value counts, i18n, URL
  serialisation) over TanStack Table. That is a query builder, and it belongs on
  the server here. `filter_chip/1` and `filter_bar/1` port the **row it
  renders**, which is the part a reader sees.
- **The insights panel.** A 420-pixel side panel of charts computed from the
  visible issues. Worth revisiting when there is a real corpus to compute from;
  charting invented numbers demonstrates nothing.
- **`motion/react` layout animation.** The source animates a row into a card
  when the view switches between list and board, via shared `layoutId`. It is
  genuinely nice and it needs a JavaScript animation library plus DOM
  measurement. Not for a first port.
- **Context menus.** Right-click on a row opens a twelve-item Radix menu. Every
  action in it also exists in the command palette, which is reachable from a
  keyboard.
- **The create-issue modal, cycles, initiatives, inbox, reviews, and the agent
  surface.** Out of scope: they are product decisions, not components, and this
  application has not made them.
- **`components/ui/*`** — shadcn/ui primitives. Button, badge, avatar, input,
  table, and the rest already exist in `OpenAgentsWeb.UI`, and adding a second
  set is precisely what `AGENTS.md` forbids.

## What this port does not yet do

- **Nothing renders these on a real page.** The existing issue LiveViews at
  `/:owner/:repo/issues` still compose generic controls directly. Wiring them up
  is a separate change against a real schema, and it should be done deliberately
  rather than as a side effect of adding components. Until it happens, the
  component library is the only place these appear.
- **Grouping, filtering, and display options are not implemented.** The
  components render a grouped view; deciding what the groups are is the caller's
  job and nothing here does it yet.
- **The board is display-only,** as above.
- **The demos hold invented data.** Six issues, eight people, four projects.
  They span every status category, every priority, assigned and unassigned,
  because a demo that shows one happy row hides the cases the component exists
  to keep legible.

## Work list

Status is one of **done**, **next**, or **planned**.

### 1. Indicators — **done**

`issue_status/1`, `issue_priority/1`, `issue_label/1`, `assignee/1`,
`assignee_stack/1`. The vocabulary everything else is built from. Catalogued at
`/components/issue-status`, `/components/issue-priority`,
`/components/issue-label`, `/components/assignee`,
`/components/assignee-stack`.

### 2. Rows and collections — **done**

`issue_row/1`, `issue_card/1`, `issue_group/1`, `issue_board/1`. Catalogued at
`/components/issue-row`, `/components/issue-card`, `/components/issue-group`,
`/components/issue-board`.

### 3. Headers and filters — **done**

`view_tabs/1`, `issue_toolbar/1`, `filter_chip/1`, `filter_bar/1`. Catalogued at
`/components/view-tabs`, `/components/issue-toolbar`, `/components/filter-chip`,
`/components/filter-bar`.

### 4. Command palette — **done**

`command_palette/1`, `command_group/1`, `command_item/1`. Catalogued at
`/components/command-palette`, `/components/command-group`,
`/components/command-item`.

### 5. Project, team, and member rows — **done**

`project_row/1`, `team_row/1`, `member_row/1`. Catalogued at
`/components/project-row`, `/components/team-row`, `/components/member-row`.

### 6. Compose the issue LiveViews from these — **next**

`OpenAgentsWeb.IssueIndexLive` should render `issue_row/1` and `issue_group/1`
against real issues, the way `OpenAgentsWeb.HomeLive` is built from catalogued
landing components. That is what stops the library and the product drifting
apart: changing a component changes the page, and the library demonstrates the
same thing a user sees.

This needs a decision first. The application's issues have `state` (open,
closed) where these components have six categories, and no priority column at
all. Either the schema grows to carry what the components render, or the
components render less. Guessing at that in a component port would have been
the wrong place to decide it.

### 7. Grouping and filtering on the server — **planned**

Group by status, assignee, priority, or project; filter by the same. Both are
server concerns — a query and a `GROUP BY` — and the components already accept
the result. The filter chips need somewhere to send their changes, which is the
same decision as item 6.

### 8. Display options — **planned**

Circle's `DisplayOptions` popover switches list and board, picks the grouping
and ordering, and toggles nine per-property visibility flags. The toggles are
worth having and they need somewhere to persist; a native popover over
`OpenAgentsWeb.UI.menu/1` plus a per-user preference would do it without script.

[circle]: https://github.com/ln-dev7/circle
