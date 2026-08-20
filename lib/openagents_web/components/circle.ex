defmodule OpenAgentsWeb.UI.Circle do
  @moduledoc """
  Issue, project, and team surfaces: the shapes a tracker is built from.

  Adapted from Circle (MIT, © 2025 lndev-ui), a Linear-shaped issue tracker
  built with Next.js, Tailwind, shadcn/ui, Zustand, `motion/react`, and
  `react-dnd`. Nothing is copied. Every source component is a client component
  reading a Zustand store, and the interesting ones are wrapped in Radix
  primitives; none of that survives the move to HEEx. What carried over is the
  **information design**: what an issue row holds and in what order, that the
  status glyph is a filled arc rather than a coloured dot, that a group header
  is tinted by its own status at a fraction of its strength, that a filter
  reads as subject / operator / value with the value removable on its own. See
  `docs/2026-08-20-circle-ui-port.md`.

  Three departures from the source are deliberate:

    * **Tokens, not a second palette.** Circle assigns a hand-picked hex value
      to each of thirteen statuses and eleven labels. Those colours belong to
      Linear, not to this product, and adopting them would put a second colour
      system beside the one every other surface uses. Colour here is assigned
      per status *category* — six of them — off the same token ladder as
      `OpenAgentsWeb.UI.status_indicator/1`, so activity is `--info`,
      completion is `--success`, and anything asking for attention is
      `--warning`. Six colours say less than thirteen; they also stay true in
      both themes and never disagree with the rest of the interface.

    * **No JavaScript except where the keyboard needs it.** Rows, groups,
      boards, filters, and headers are server-rendered and static. The command
      palette is the exception: a `⌘K` binding and incremental filtering
      cannot be expressed in markup, so it carries one colocated hook.

    * **State is the caller's.** The source keeps grouping, filters, search,
      and drag results in client stores. These components take what to draw and
      emit `Phoenix.LiveView.JS` commands the caller supplies; none of them own
      state. That is what makes the same row usable in a list, in a board, and
      in a search result.

  Every component takes plain maps and atoms rather than structs, so a surface
  can render from an Ecto schema, a map from an API, or a literal in a test
  without a conversion layer.
  """

  use Phoenix.Component

  alias OpenAgentsWeb.UI
  alias Phoenix.LiveView.JS

  @categories [:triage, :backlog, :unstarted, :started, :completed, :canceled]
  @priorities [:none, :low, :medium, :high, :urgent]
  @tones [:neutral, :primary, :info, :success, :warning, :danger]
  @presences [:none, :online, :away, :offline]

  @doc """
  The state of one issue, as a glyph and optionally a word.

  The source draws six shapes: a triage disc, a dashed gear for backlog, an
  empty ring, a ring with a filled arc, a filled tick, and a filled cross. Five
  of those already exist in the vendored icon set. The sixth — the arc — is the
  only one that reads a number, so it is drawn in CSS from `progress` rather
  than picked from a fixed set of fractions. A ring that is a quarter full is
  the one thing in a Linear list that says how far along the work is, and an
  icon set cannot carry it.

  Colour comes from the category, never from the individual status: `:started`
  is `--info` because it is activity, `:completed` is `--success`, `:triage` is
  `--warning` because it is asking for a decision, and the two resting states
  are grey. This is the same vocabulary `status_indicator/1` uses.

  The glyph announces itself unless `show_label` puts the word beside it, in
  which case announcing both says the state twice.
  """
  attr :category, :atom, values: @categories, required: true
  attr :label, :string, required: true, doc: "the status's own name, such as `In review`"

  attr :progress, :integer,
    default: nil,
    doc: "0-100, drawn as a filled arc; only meaningful for `:started`"

  attr :show_label, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global

  def issue_status(assigns) do
    assigns = assign(assigns, :arc, clamp(assigns.progress))

    ~H"""
    <span class={["issue-status", @class]} data-category={@category} {@rest}>
      <span
        :if={@category == :started}
        class="issue-status__arc"
        style={"--issue-arc: #{@arc}"}
        role={if(!@show_label, do: "img")}
        aria-label={if(!@show_label, do: @label)}
        aria-hidden={if(@show_label, do: "true")}
      />
      <UI.icon
        :if={@category != :started}
        name={category_icon(@category)}
        label={if(!@show_label, do: @label)}
        class="issue-status__glyph"
      />
      <span :if={@show_label} class="issue-status__label">{@label}</span>
    </span>
    """
  end

  @doc """
  How urgent one issue is, as four ascending bars or an alarm.

  The bar chart is the source's own idea and it is a good one: the level reads
  from how much of the shape is lit, so the ordering survives greyscale and a
  reader who cannot separate the tints. Urgent breaks the pattern on purpose —
  it is not one more step up the same ramp, and drawing it as one invites the
  eye to skip it.

  Drawn in CSS rather than vendored as five glyphs, because the bars are one
  shape read at five levels rather than five different pictures.
  """
  attr :level, :atom, values: @priorities, required: true
  attr :label, :string, default: nil, doc: "overrides the level's own name"
  attr :show_label, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global

  def issue_priority(assigns) do
    assigns = assign_new(assigns, :name, fn -> assigns.label || priority_name(assigns.level) end)

    ~H"""
    <span class={["issue-priority", @class]} data-level={@level} {@rest}>
      <UI.icon
        :if={@level == :urgent}
        name="triangle-exclamation-filled-error-warning"
        label={if(!@show_label, do: @name)}
        class="issue-priority__alarm"
      />
      <span
        :if={@level != :urgent}
        class="issue-priority__bars"
        role={if(!@show_label, do: "img")}
        aria-label={if(!@show_label, do: @name)}
        aria-hidden={if(@show_label, do: "true")}
      >
        <span class="issue-priority__bar" /><span class="issue-priority__bar" /><span class="issue-priority__bar" />
      </span>
      <span :if={@show_label} class="issue-priority__label">{@name}</span>
    </span>
    """
  end

  @doc """
  One label on an issue: a dot and a word in a pill.

  The source colours the dot from a per-label hex value chosen when the label
  was created. That model does not survive the tokens rule, so `tone` picks one
  of six values off the ladder instead. Six tones cannot distinguish eleven
  labels by colour alone, which is why the word is never optional here — the
  dot is a grouping hint, not the identity.
  """
  attr :name, :string, required: true
  attr :tone, :atom, values: @tones, default: :neutral
  attr :class, :any, default: nil
  attr :rest, :global

  def issue_label(assigns) do
    ~H"""
    <span class={["issue-label", @class]} data-tone={@tone} {@rest}>
      <span class="issue-label__dot" aria-hidden="true" />{@name}
    </span>
    """
  end

  @doc """
  Who an issue belongs to, or that it belongs to nobody.

  Unassigned is drawn rather than left blank. A blank cell in a list of faces
  reads as a rendering failure, and "nobody has picked this up" is one of the
  more actionable facts a triage view carries.

  `presence` adds the small corner dot. It is decorative here: the row already
  names the person, and a second announcement of "online" on every row of a
  list is noise.
  """
  attr :name, :string, default: nil, doc: "`nil` renders the unassigned state"
  attr :src, :string, default: nil
  attr :presence, :atom, values: @presences, default: :none
  attr :size, :atom, values: [:sm, :default, :lg], default: :default
  attr :show_name, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global

  def assignee(assigns) do
    ~H"""
    <span class={["assignee", @class]} data-size={@size} {@rest}>
      <span class="assignee__figure">
        <UI.avatar
          :if={@name}
          src={@src}
          fallback={String.first(@name)}
          size={@size}
          label={if(!@show_name, do: @name)}
        />
        <span :if={!@name} class="assignee__empty" role="img" aria-label="Unassigned">
          <UI.icon name="user" />
        </span>
        <span :if={@name && @presence != :none} class="assignee__presence" data-presence={@presence} />
      </span>
      <span :if={@show_name} class="assignee__name">{@name || "Unassigned"}</span>
    </span>
    """
  end

  @doc """
  Several people as overlapping faces, with a count for the ones that do not fit.

  The count is the point. Six faces and a `+14` says the size of a team; six
  faces alone says the team has six people, which would be wrong.
  """
  attr :people, :list, required: true, doc: "`[%{name: String.t(), src: String.t() | nil}]`"
  attr :limit, :integer, default: 5
  attr :class, :any, default: nil
  attr :rest, :global

  def assignee_stack(assigns) do
    assigns =
      assigns
      |> assign(:shown, Enum.take(assigns.people, assigns.limit))
      |> assign(:overflow, max(length(assigns.people) - assigns.limit, 0))

    ~H"""
    <span class={["assignee-stack", @class]} {@rest}>
      <span class="assignee-stack__faces">
        <UI.avatar
          :for={person <- @shown}
          src={person[:src]}
          fallback={String.first(person[:name])}
          size={:sm}
          label={person[:name]}
        />
      </span>
      <span :if={@overflow > 0} class="assignee-stack__count">+{@overflow}</span>
    </span>
    """
  end

  @doc """
  One issue as a row: the shape a tracker is mostly made of.

  Order is load-bearing and inherited from the source. Priority, identifier,
  and status lead because they are the three things a person scans a list for;
  the title takes the remaining width and truncates; everything discretionary —
  labels, project, dates, assignee — collects at the trailing edge where it can
  be dropped by width without disturbing the scan column.

  Only the title is a link. The source makes the row a drag handle and the
  title a link inside it, which means a click lands on one of two different
  things depending on where in a 44-pixel row it falls. One target is easier to
  hit and easier to explain.
  """
  attr :identifier, :string, required: true, doc: "the short key, such as `OA-142`"
  attr :title, :string, required: true
  attr :navigate, :any, default: nil, doc: "where the title goes; a plain title without it"
  attr :status_category, :atom, values: @categories, required: true
  attr :status_label, :string, required: true
  attr :progress, :integer, default: nil
  attr :priority, :atom, values: @priorities, default: :none
  attr :labels, :list, default: [], doc: "`[%{name: String.t(), tone: atom()}]`"
  attr :project, :string, default: nil
  attr :due, :string, default: nil, doc: "already formatted; overdue is the caller's judgement"
  attr :created, :string, default: nil
  attr :assignee, :map, default: nil, doc: "`%{name:, src:, presence:}`; `nil` is unassigned"
  attr :selected, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global

  def issue_row(assigns) do
    ~H"""
    <div class={["issue-row", @class]} data-selected={@selected} {@rest}>
      <span class="issue-row__scan">
        <.issue_priority level={@priority} />
        <span class="issue-row__identifier">{@identifier}</span>
        <.issue_status
          category={@status_category}
          label={@status_label}
          progress={@progress}
        />
      </span>

      <.link :if={@navigate} navigate={@navigate} class="issue-row__title">{@title}</.link>
      <span :if={!@navigate} class="issue-row__title">{@title}</span>

      <span class="issue-row__trailing">
        <span :if={@labels != [] or @project} class="issue-row__chips">
          <.issue_label :for={label <- @labels} name={label[:name]} tone={label[:tone] || :neutral} />
          <span :if={@project} class="issue-label" data-tone="neutral">
            <UI.icon name="cube" class="issue-label__glyph" />{@project}
          </span>
        </span>
        <span :if={@due} class="issue-row__due">Due {@due}</span>
        <span :if={@created} class="issue-row__date">{@created}</span>
        <.assignee
          name={@assignee && @assignee[:name]}
          src={@assignee && @assignee[:src]}
          presence={(@assignee && @assignee[:presence]) || :none}
        />
      </span>
    </div>
    """
  end

  @doc """
  The same issue as a card, for a board column.

  A card is not a row turned sideways: it has width and no neighbours, so the
  title gets two lines instead of one and the labels get their own band instead
  of competing with the trailing edge. The scan column becomes a header line,
  and the assignee drops to the foot where it reads as ownership of the whole
  card rather than one more attribute.
  """
  attr :identifier, :string, required: true
  attr :title, :string, required: true
  attr :navigate, :any, default: nil
  attr :status_category, :atom, values: @categories, required: true
  attr :status_label, :string, required: true
  attr :progress, :integer, default: nil
  attr :priority, :atom, values: @priorities, default: :none
  attr :labels, :list, default: []
  attr :project, :string, default: nil
  attr :created, :string, default: nil
  attr :assignee, :map, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  def issue_card(assigns) do
    ~H"""
    <article class={["issue-card", @class]} {@rest}>
      <header class="issue-card__head">
        <span class="issue-card__scan">
          <.issue_priority level={@priority} />
          <span class="issue-row__identifier">{@identifier}</span>
        </span>
        <.issue_status
          category={@status_category}
          label={@status_label}
          progress={@progress}
        />
      </header>

      <.link :if={@navigate} navigate={@navigate} class="issue-card__title">{@title}</.link>
      <p :if={!@navigate} class="issue-card__title">{@title}</p>

      <div :if={@labels != [] or @project} class="issue-card__chips">
        <.issue_label :for={label <- @labels} name={label[:name]} tone={label[:tone] || :neutral} />
        <span :if={@project} class="issue-label" data-tone="neutral">
          <UI.icon name="cube" class="issue-label__glyph" />{@project}
        </span>
      </div>

      <footer class="issue-card__foot">
        <span class="issue-row__date">{@created}</span>
        <.assignee
          name={@assignee && @assignee[:name]}
          src={@assignee && @assignee[:src]}
          presence={(@assignee && @assignee[:presence]) || :none}
        />
      </footer>
    </article>
    """
  end

  @doc """
  A named run of issues under a sticky, tinted header.

  The tint is the source's idea and it earns its place: a list grouped by
  status has no other way to say where one group ends and the next begins once
  the header has scrolled past its own rows. It is mixed from the category
  colour at a low percentage, so it is a wash rather than a fill, and the
  header is still legible over it.

  `layout` picks the two arrangements the same group takes: a full-width band
  in a list, or a fixed-width column in a board. The header, count, and actions
  are identical in both, which is why they are one component.
  """
  attr :label, :string, required: true
  attr :count, :integer, required: true
  attr :category, :atom, values: @categories ++ [:none], default: :none, doc: "drives the tint"
  attr :layout, :atom, values: [:list, :board], default: :list
  attr :class, :any, default: nil
  attr :rest, :global
  slot :glyph, doc: "the marker beside the name; a status, a priority, or a face"
  slot :actions, doc: "controls at the trailing edge of the header"
  slot :inner_block, required: true

  def issue_group(assigns) do
    ~H"""
    <section class={["issue-group", @class]} data-layout={@layout} data-category={@category} {@rest}>
      <header class="issue-group__head">
        <span class="issue-group__name">
          {render_slot(@glyph)}
          <span class="issue-group__label">{@label}</span>
          <span class="issue-group__count">{@count}</span>
        </span>
        <span :if={@actions != []} class="issue-group__actions">{render_slot(@actions)}</span>
      </header>
      <div class="issue-group__body">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  @doc """
  Board columns side by side, scrolling horizontally.

  Each column scrolls on its own so a long backlog does not push the other
  columns' headers off the top. The source achieves this with a drag-and-drop
  provider wrapped around the same layout; the layout is the part worth having.
  """
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def issue_board(assigns) do
    ~H"""
    <div class={["issue-board", @class]} {@rest}>{render_slot(@inner_block)}</div>
    """
  end

  @doc """
  One applied filter, read as subject, operator, value.

  Splitting the chip into three segments is what makes a filter editable
  without a modal: each segment is its own control, so changing `is` to
  `is not` does not mean removing the filter and building it again. The
  segments here are static text unless the caller supplies commands; the
  division is the part that matters, and it is what the source's
  `data-table-filter` spends most of its code on.
  """
  attr :subject, :string, required: true
  attr :operator, :string, required: true
  attr :value, :string, required: true
  attr :icon, :string, default: nil, doc: "a glyph for the subject"
  attr :on_remove, JS, default: nil, doc: "dropped from the applied set when clicked"
  attr :class, :any, default: nil
  attr :rest, :global

  def filter_chip(assigns) do
    ~H"""
    <span class={["filter-chip", @class]} {@rest}>
      <span class="filter-chip__subject">
        <UI.icon :if={@icon} name={@icon} />{@subject}
      </span>
      <span class="filter-chip__operator">{@operator}</span>
      <span class="filter-chip__value">{@value}</span>
      <button
        :if={@on_remove}
        type="button"
        class="filter-chip__remove"
        phx-click={@on_remove}
        aria-label={"Remove the #{@subject} filter"}
      >
        <UI.icon name="x" />
      </button>
    </span>
    """
  end

  @doc """
  The row of applied filters, with somewhere to add one and a way to drop them all.

  It appears only when a filter is applied — the source hides it otherwise and
  keeps the entry point in the toolbar, which is right: an empty filter bar is
  a permanent reminder of a feature nobody is using. Rendering nothing when
  there are no chips is the caller's decision, so this component does not
  guess.
  """
  attr :on_clear, JS, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :add, doc: "the control that opens the subject picker"
  slot :inner_block, required: true, doc: "the applied chips"

  def filter_bar(assigns) do
    ~H"""
    <div class={["filter-bar", @class]} {@rest}>
      <div class="filter-bar__chips">
        {render_slot(@add)}
        {render_slot(@inner_block)}
      </div>
      <button :if={@on_clear} type="button" class="filter-bar__clear" phx-click={@on_clear}>
        Clear
      </button>
    </div>
    """
  end

  @doc """
  The saved views of one collection, as pills.

  Pills rather than underlined tabs because these switch a filter rather than a
  page: the content below keeps its shape, and an underline promises a bigger
  change than actually happens. The selected pill carries `aria-current`, so
  the state is not colour alone.
  """
  attr :label, :string, default: "Views", doc: "names the group for assistive technology"
  attr :class, :any, default: nil
  attr :rest, :global

  slot :tab, required: true do
    attr :label, :string, required: true
    attr :navigate, :any, required: true
    attr :selected, :boolean
  end

  def view_tabs(assigns) do
    ~H"""
    <nav class={["view-tabs", @class]} aria-label={@label} {@rest}>
      <.link
        :for={tab <- @tab}
        navigate={tab.navigate}
        class="view-tabs__tab"
        aria-current={tab[:selected] && "page"}
      >
        {tab.label}
      </.link>
    </nav>
    """
  end

  @doc """
  The bar above a collection: what you are looking at, and what you can do to it.

  The source splits this into two stacked rows — navigation above, options
  below — and the split is worth keeping when both are full. This renders one
  row with a leading and a trailing slot; stack two of them for the source's
  arrangement. Making it one component rather than two means a surface with
  only options does not inherit an empty navigation strip.
  """
  attr :class, :any, default: nil
  attr :rest, :global
  slot :leading, doc: "tabs, a count, or a title"
  slot :actions, doc: "filter, display, and view controls"

  def issue_toolbar(assigns) do
    ~H"""
    <div class={["issue-toolbar", @class]} {@rest}>
      <div class="issue-toolbar__leading">{render_slot(@leading)}</div>
      <div class="issue-toolbar__actions">{render_slot(@actions)}</div>
    </div>
    """
  end

  @doc """
  The `⌘K` surface: a search field over grouped commands.

  This is the one component here that needs script. `⌘K` is a document-level
  binding, incremental filtering means hiding rows as characters arrive, and
  arrow-key selection has to survive both — none of which markup can express.
  The hook does exactly those four things and nothing else; every command is a
  real `<button>` that works without it.

  Built on `<dialog>` rather than a positioned panel, so the browser supplies
  the modal semantics, the focus trap, the backdrop, and `Escape`. Anything
  with `data-command-target` matching this palette's id opens it, which is how
  a surface offers a visible way in beside the shortcut.

  `context` is the source's best idea in this surface: when the palette is
  opened from an issue, it says which issue, so `Change status…` is unambiguous
  before you pick anything.
  """
  attr :id, :string, required: true
  attr :placeholder, :string, default: "Type a command or search"
  attr :context, :string, default: nil, doc: "what the commands act on, if anything"
  attr :empty, :string, default: "No results found."
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true, doc: "`command_group/1` elements"

  def command_palette(assigns) do
    ~H"""
    <dialog id={@id} class={["command-palette", @class]} phx-hook=".CommandPalette" {@rest}>
      <div class="command-palette__panel">
        <p :if={@context} class="command-palette__context">{@context}</p>
        <div class="command-palette__search">
          <UI.icon name="search" class="command-palette__glyph" />
          <input
            type="text"
            class="command-palette__input"
            placeholder={@placeholder}
            aria-label={@placeholder}
            autocomplete="off"
            data-command-input
          />
        </div>
        <div class="command-palette__list">
          {render_slot(@inner_block)}
          <p class="command-palette__empty" data-command-empty hidden>{@empty}</p>
        </div>
      </div>
    </dialog>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".CommandPalette">
      export default {
        mounted() {
          const input = this.el.querySelector("[data-command-input]")
          const empty = this.el.querySelector("[data-command-empty]")
          const items = () => Array.from(this.el.querySelectorAll("[data-command-item]"))
          const visible = () => items().filter((item) => !item.hidden)

          const select = (item) => {
            items().forEach((other) => other.removeAttribute("data-active"))
            if (!item) return
            item.setAttribute("data-active", "")
            item.scrollIntoView({block: "nearest"})
          }

          const filter = () => {
            const query = input.value.trim().toLowerCase()
            items().forEach((item) => {
              item.hidden = query !== "" && !item.dataset.commandLabel.includes(query)
            })
            this.el.querySelectorAll("[data-command-group]").forEach((group) => {
              group.hidden = group.querySelectorAll("[data-command-item]:not([hidden])").length === 0
            })
            const shown = visible()
            if (empty) empty.hidden = shown.length !== 0
            select(shown[0])
          }

          const open = () => {
            if (this.el.open) return
            input.value = ""
            filter()
            this.el.showModal()
            input.focus()
          }

          this.onKeyDown = (event) => {
            if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
              event.preventDefault()
              this.el.open ? this.el.close() : open()
            }
          }

          this.onClick = (event) => {
            const trigger = event.target.closest(`[data-command-target="${this.el.id}"]`)
            if (trigger) open()
          }

          // Arrow keys move a selection the browser has no concept of, so the
          // active row is tracked here and Enter forwards to its own click
          // handler rather than duplicating what the row does.
          this.onPaletteKey = (event) => {
            const shown = visible()
            if (shown.length === 0) return
            const at = shown.findIndex((item) => item.hasAttribute("data-active"))
            if (event.key === "ArrowDown") {
              event.preventDefault()
              select(shown[(at + 1) % shown.length])
            } else if (event.key === "ArrowUp") {
              event.preventDefault()
              select(shown[(at - 1 + shown.length) % shown.length])
            } else if (event.key === "Enter" && at >= 0) {
              event.preventDefault()
              shown[at].click()
            }
          }

          input.addEventListener("input", filter)
          this.el.addEventListener("keydown", this.onPaletteKey)
          window.addEventListener("keydown", this.onKeyDown)
          document.addEventListener("click", this.onClick)
          filter()
        },
        destroyed() {
          window.removeEventListener("keydown", this.onKeyDown)
          document.removeEventListener("click", this.onClick)
        }
      }
    </script>
    """
  end

  @doc """
  A titled run of commands inside the palette.

  Headings are what keep a palette of forty commands readable, and they are
  also what makes filtering legible: a group with nothing left in it hides
  itself rather than leaving a heading over a gap.
  """
  attr :heading, :string, required: true
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def command_group(assigns) do
    ~H"""
    <div class={["command-group", @class]} data-command-group {@rest}>
      <p class="command-group__heading">{@heading}</p>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  One command: a glyph, a name, and the keys that reach it directly.

  The shortcut chips are documentation, not bindings — the palette does not
  install them. Showing them anyway is how a person stops needing the palette,
  which is the point of having one.

  `label` doubles as the filter key, so a command matches on the words a person
  would actually type.
  """
  attr :label, :string, required: true
  attr :icon, :string, default: nil
  attr :keys, :list, default: [], doc: "shortcut keys shown at the trailing edge"
  attr :on_select, JS, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  def command_item(assigns) do
    ~H"""
    <button
      type="button"
      class={["command-item", @class]}
      data-command-item
      data-command-label={String.downcase(@label)}
      phx-click={@on_select}
      {@rest}
    >
      <UI.icon :if={@icon} name={@icon} class="command-item__glyph" />
      <span class="command-item__label">{@label}</span>
      <span :if={@keys != []} class="command-item__keys">
        <UI.kbd :for={key <- @keys}>{key}</UI.kbd>
      </span>
    </button>
    """
  end

  @doc """
  One project as a row: name on the left, everything measurable on the right.

  Projects are read across rather than down — the question is which project is
  behind, not what any one of them is called — so the trailing fields sit in
  fixed columns that line up between rows. They drop by width from the least
  load-bearing inwards, which is why progress is the last to go.

  Health is a word, not a colour: `at risk` and `off track` are different
  claims, and a reader should not have to learn which shade of amber means
  which.
  """
  attr :name, :string, required: true
  attr :navigate, :any, default: nil
  attr :icon, :string, default: "cube"
  attr :health, :atom, values: [:on_track, :at_risk, :off_track, :unknown], default: :unknown
  attr :priority, :atom, values: @priorities, default: :none
  attr :lead, :map, default: nil, doc: "`%{name:, src:}`; `nil` renders unassigned"
  attr :target, :string, default: nil, doc: "already formatted target date"
  attr :issues, :integer, default: nil
  attr :status_category, :atom, values: @categories, required: true
  attr :status_label, :string, required: true
  attr :percent, :integer, default: nil
  attr :labels, :list, default: []
  attr :class, :any, default: nil
  attr :rest, :global

  def project_row(assigns) do
    ~H"""
    <div class={["project-row", @class]} {@rest}>
      <span class="project-row__name">
        <span class="project-row__icon"><UI.icon name={@icon} /></span>
        <.link :if={@navigate} navigate={@navigate} class="project-row__link">{@name}</.link>
        <span :if={!@navigate} class="project-row__link">{@name}</span>
        <.issue_label :for={label <- @labels} name={label[:name]} tone={label[:tone] || :neutral} />
      </span>

      <span :if={@health != :unknown} class="project-row__health" data-health={@health}>
        {health_name(@health)}
      </span>
      <span class="project-row__priority"><.issue_priority level={@priority} /></span>
      <span class="project-row__lead">
        <.assignee name={@lead && @lead[:name]} src={@lead && @lead[:src]} size={:sm} />
      </span>
      <span :if={@target} class="project-row__target">{@target}</span>
      <span :if={@issues} class="project-row__issues">{@issues}</span>
      <span class="project-row__status">
        <.issue_status
          category={@status_category}
          label={@status_label}
          progress={@percent}
        />
        <span :if={@percent} class="project-row__percent">{@percent}%</span>
      </span>
    </div>
    """
  end

  @doc """
  One team as a row: identity, membership, and what it owns.

  The identifier is shown beside the name rather than instead of it because it
  is the prefix on every issue key the team produces — `OA-142` is only
  findable if somebody can connect `OA` to a team.
  """
  attr :name, :string, required: true
  attr :identifier, :string, required: true
  attr :glyph, :string, default: nil, doc: "a short mark, typically one character"
  attr :navigate, :any, default: nil
  attr :joined, :boolean, default: false
  attr :members, :list, default: []
  attr :projects, :integer, default: nil
  attr :cycles, :integer, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  def team_row(assigns) do
    ~H"""
    <div class={["team-row", @class]} {@rest}>
      <span class="team-row__name">
        <span class="team-row__glyph" aria-hidden="true">{@glyph || String.first(@identifier)}</span>
        <.link :if={@navigate} navigate={@navigate} class="team-row__link">{@name}</.link>
        <span :if={!@navigate} class="team-row__link">{@name}</span>
        <span class="team-row__identifier">{@identifier}</span>
      </span>

      <span class="team-row__membership">
        <span :if={@joined} class="team-row__joined"><UI.icon name="check" />Joined</span>
      </span>
      <span class="team-row__members">
        <.assignee_stack :if={@members != []} people={@members} limit={6} />
      </span>
      <span :if={@cycles} class="team-row__metric"><UI.icon name="loop" />{@cycles}</span>
      <span :if={@projects} class="team-row__metric"><UI.icon name="cube" />{@projects}</span>
    </div>
    """
  end

  @doc """
  One person as a row: who they are, what they may do, and where they belong.

  Two lines of identity rather than one. A display name is what a colleague
  recognises and a handle is what appears in a mention, and a directory that
  shows only one of them fails whichever question is being asked.
  """
  attr :name, :string, required: true
  attr :handle, :string, required: true
  attr :src, :string, default: nil
  attr :role, :string, default: nil
  attr :role_tone, :atom, values: [:neutral, :accent], default: :neutral
  attr :joined, :string, default: nil, doc: "already formatted joining date"
  attr :teams, :list, default: [], doc: "team identifiers"
  attr :presence, :atom, values: @presences, default: :none
  attr :navigate, :any, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  def member_row(assigns) do
    assigns =
      assigns
      |> assign(:shown_teams, Enum.take(assigns.teams, 2))
      |> assign(:extra_teams, max(length(assigns.teams) - 2, 0))

    ~H"""
    <div class={["member-row", @class]} {@rest}>
      <span class="member-row__identity">
        <.assignee name={@name} src={@src} presence={@presence} size={:lg} />
        <span class="member-row__names">
          <.link :if={@navigate} navigate={@navigate} class="member-row__name">{@name}</.link>
          <span :if={!@navigate} class="member-row__name">{@name}</span>
          <span class="member-row__handle">{@handle}</span>
        </span>
      </span>

      <span :if={@role} class="member-row__role" data-tone={@role_tone}>{@role}</span>
      <span :if={@joined} class="member-row__joined">{@joined}</span>
      <span :if={@teams != []} class="member-row__teams">
        <UI.icon name="group" />{Enum.join(@shown_teams, ", ")}
        <span :if={@extra_teams > 0}>
          +{@extra_teams}
        </span>
      </span>
    </div>
    """
  end

  # ── the fixed vocabularies ─────────────────────────────────────────────────

  # Five of the source's six status shapes exist in the vendored set. Triage is
  # opposing arrows in a disc, which `compare-arrows` says exactly; the dashed
  # gear it uses for backlog has no equivalent and `circle-dashed` carries the
  # same "not yet real" reading without vendoring a glyph for one state.
  defp category_icon(:triage), do: "compare-arrows"
  defp category_icon(:backlog), do: "circle-dashed"
  defp category_icon(:unstarted), do: "empty-circle"
  defp category_icon(:completed), do: "check-circle-filled"
  defp category_icon(:canceled), do: "x-circle-filled"

  defp priority_name(:none), do: "No priority"
  defp priority_name(:low), do: "Low priority"
  defp priority_name(:medium), do: "Medium priority"
  defp priority_name(:high), do: "High priority"
  defp priority_name(:urgent), do: "Urgent"

  # `:unknown` has no word because the row renders no health cell for it. A
  # project nobody has reported on should leave a gap in the column, not claim
  # "no update" as though that were a fourth health state.
  defp health_name(:on_track), do: "On track"
  defp health_name(:at_risk), do: "At risk"
  defp health_name(:off_track), do: "Off track"

  # A progress value arrives from a count of finished issues over a count of
  # issues, so it can be anything; the arc has to be drawable regardless.
  defp clamp(nil), do: 0
  defp clamp(value) when is_integer(value), do: value |> max(0) |> min(100)
  defp clamp(_), do: 0
end
