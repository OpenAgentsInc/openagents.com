defmodule OpenAgentsWeb.AI.Evidence do
  @moduledoc """
  Evidence and artifacts: what a model produced, and where it came from.

  Ported from Vercel's AI Elements (MIT), specifically `code-block.tsx`,
  `snippet.tsx`, `terminal.tsx`, `sources.tsx`, `inline-citation.tsx`,
  `context.tsx`, `artifact.tsx`, `confirmation.tsx`, `question.tsx`, and
  `image.tsx`. The Tailwind carried over as written; the React did not. Every
  source component is a client component built on Radix — hover cards,
  collapsibles, carousels, tooltips — and none of that survives the move to
  HEEx. What survives is the information design: what a code block's chrome
  holds, that a citation is a hostname chip that opens onto the sources behind
  it, that a token meter states a percentage twice (as a number and as an arc),
  and that a confirmation shows its decision after the fact rather than
  vanishing.

  ## Departures from the source, and why

    * **No syntax highlighting.** AI Elements tokenizes with Shiki in the
      browser and paints one `span` per token. Shiki is a JavaScript
      highlighter and a second rendering engine; `code_block/1` keeps the
      chrome, the line numbers, and the copy affordance, and renders the code
      as text. Highlighting, if it is ever wanted, belongs on the server.

    * **No ANSI parsing.** `terminal/1`'s source pipes output through
      `ansi-to-react`. Escape sequences arrive here as literal text. Strip them
      before passing `output`, or add a server-side parser later.

    * **No carousel.** `inline_citation/1`'s source paginates its sources with
      Embla. The sources are listed instead, which is the static fallback: the
      card is already scoped to one citation, so the count is small.

    * **Hover cards and collapsibles are CSS and markup.** `sources/1` is a
      `details`/`summary` pair. `inline_citation/1` and `context/1` reveal
      their card on hover and on focus within, so a keyboard reaches them.
      Neither needs a script.

    * **The context ring is a conic gradient, not a drawn arc.** The source
      draws two circles and animates `stroke-dashoffset`. Inline SVG is not
      allowed in a product surface here (`docs/ICONS.md`), so the ring is a
      masked `conic-gradient` in an inline style. It reads identically and
      costs no glyph.

    * **`context/1` clamps its bar and flags the overrun.** The source lets a
      progress bar past 100% render however the browser feels. A meter that
      silently pins at full hides the one state worth seeing, so an over-budget
      meter carries `data-over-budget="true"` and turns to the danger tone.

    * **Costs are attributes, not computed.** The source prices usage with
      `tokenlens`. There is no pricing table here, so a caller that knows the
      price passes it.

    * **`question/1` selects with real form controls.** The source toggles
      React state on buttons carrying `aria-checked`. Radio and checkbox inputs
      styled as chips give the same look with real keyboard behaviour, real
      form submission, and no client state. Its submit control cannot disable
      itself until a choice is made — that was React state — so the server
      validates instead.

  ## Utilities that had to change

  The Tailwind is the source's, class for class, with three exceptions. Two are
  name collisions: `assets/css/app.css` defines `--accent` as the brand indigo
  rather than shadcn's quiet hover surface, and `--primary` as the same indigo
  rather than the near-foreground ink, so `bg-accent` became `bg-muted` in
  `inline_citation/1` and `text-primary` became `text-foreground` in
  `sources/1`. The third is `not-prose` on `sources/1`, which escapes Tailwind
  Typography; that plugin is not installed here, so the class resolved to
  nothing and was dropped.

  ## Images and Markdown

  `image/1` renders its own `img` element from attributes. It has to:
  `OpenAgents.Markdown.to_html/2` sanitizes to an allowlist that has no `img`
  in it, so an image written into Markdown is dropped before it reaches the
  page. Model-generated images arrive as attributes and are rendered here.
  """

  use Phoenix.Component

  alias OpenAgentsWeb.UI

  @byte_units ~w(K M B)

  @doc """
  A block of code with chrome: a filename, a language, actions, and the code.

  The code is rendered as text. Line numbers, when asked for, come from a CSS
  counter incremented once per line, so no number is ever selected with the
  code it labels.

  The `pre` carries `phx-no-curly-interpolation`, which is what lets a snippet
  containing `{` and `}` survive HEEx unescaped.
  """
  attr :id, :string, required: true
  attr :code, :string, required: true
  attr :language, :string, default: nil, doc: "recorded on the container as `data-language`"
  attr :filename, :string, default: nil
  attr :show_line_numbers, :boolean, default: false
  attr :copy, :boolean, default: true, doc: "render the copy affordance in the header"
  attr :class, :any, default: nil
  attr :rest, :global

  slot :actions, doc: "controls at the trailing edge of the header"

  def code_block(assigns) do
    assigns = assign(assigns, :lines, String.split(assigns.code, "\n"))

    ~H"""
    <div
      id={@id}
      class={[
        "group relative w-full overflow-hidden rounded-md border bg-background text-foreground",
        @class
      ]}
      data-language={@language}
      {@rest}
    >
      <div
        :if={@filename || @language || @copy || @actions != []}
        class="flex items-center justify-between border-b bg-muted/80 px-3 py-2 text-muted-foreground text-xs"
      >
        <div class="flex items-center gap-2">
          <span :if={@filename} class="font-mono">{@filename}</span>
          <span :if={is_nil(@filename) && @language} class="font-mono">{@language}</span>
        </div>
        <div class="-my-1 -mr-1 flex items-center gap-2">
          {render_slot(@actions)}
          <UI.copy_button :if={@copy} id={@id <> "-copy"} text={@code} label="Copy" />
        </div>
      </div>
      <div class="relative overflow-auto">
        <pre class="m-0 p-4 text-sm" phx-no-curly-interpolation><code class={["font-mono text-sm", @show_line_numbers && "[counter-reset:line]"]}><span :for={line <- @lines} class={@show_line_numbers && line_number_classes() || "block"}><%= line %></span></code></pre>
      </div>
    </div>
    """
  end

  # The counter, its increment, and the gutter it prints into. Kept out of the
  # template because it is nine variants of one idea and reads as noise inline.
  defp line_number_classes do
    "block before:mr-4 before:inline-block before:w-8 before:[counter-increment:line] " <>
      "before:content-[counter(line)] before:select-none before:text-right " <>
      "before:font-mono before:text-muted-foreground/50"
  end

  @doc """
  One command, in a field you copy rather than retype.

  The input is read-only and holds the whole command, so selecting it selects
  the command and nothing else. The prefix — a shell sigil, a package manager —
  sits outside the field for the same reason: it is chrome, not text you want
  on the clipboard.

  The source composes this from shadcn's `InputGroup`. That component is not
  vendored here, so the group is assembled from the same utilities.
  """
  attr :id, :string, required: true
  attr :code, :string, required: true
  attr :prefix, :string, default: nil, doc: "a sigil shown before the command, such as `$`"
  attr :copy, :boolean, default: true
  attr :label, :string, default: "Command", doc: "the accessible name of the read-only field"
  attr :class, :any, default: nil
  attr :rest, :global

  def snippet(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "flex w-full items-center gap-1 rounded-md border bg-background py-1 pr-1 pl-2 font-mono text-sm",
        @class
      ]}
      {@rest}
    >
      <span :if={@prefix} class="pl-2 font-normal text-muted-foreground">{@prefix}</span>
      <%!-- A bare input rather than `UI.input/1`. The group is the control here
            and carries the border, radius, and fill; `.input` carries its own
            set, so composing them would draw a field inside a field. --%>
      <input
        id={@id <> "-input"}
        class="min-w-0 flex-1 border-0 bg-transparent px-2 py-1 text-foreground outline-none"
        readonly
        aria-label={@label}
        value={@code}
      />
      <UI.copy_button :if={@copy} id={@id <> "-copy"} text={@code} label="Copy" />
    </div>
    """
  end

  @doc """
  A terminal transcript: a dark well holding command output.

  Fixed dark in both themes, as in the source. A terminal that inverts with the
  page stops reading as a terminal, and the output inside it was written for a
  dark ground.

  `output` is rendered verbatim. ANSI escape sequences are not parsed — see the
  module documentation.
  """
  attr :id, :string, required: true
  attr :output, :string, default: ""
  attr :title, :string, default: "Terminal"
  attr :streaming, :boolean, default: false, doc: "show the caret and the running status"
  attr :status, :string, default: nil, doc: "shown beside the actions while streaming"
  attr :copy, :boolean, default: true
  attr :class, :any, default: nil
  attr :rest, :global

  slot :actions, doc: "controls beside the copy affordance"
  slot :inner_block, doc: "replaces the rendered output, for composing lines by hand"

  def terminal(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "flex flex-col overflow-hidden rounded-lg border bg-zinc-950 text-zinc-100",
        @class
      ]}
      {@rest}
    >
      <div class="flex items-center justify-between border-zinc-800 border-b px-4 py-2">
        <div class="flex items-center gap-2 text-sm text-zinc-400">
          <UI.icon name="terminal" class="size-4" />{@title}
        </div>
        <div class="flex items-center gap-1">
          <span :if={@streaming && @status} class="flex items-center gap-2 text-xs text-zinc-400">
            {@status}
          </span>
          <div class="flex items-center gap-1">
            {render_slot(@actions)}
            <UI.copy_button :if={@copy} id={@id <> "-copy"} text={@output} label="Copy" />
          </div>
        </div>
      </div>
      <div class="max-h-96 overflow-auto p-4 font-mono text-sm leading-relaxed">
        <%= if @inner_block == [] do %>
          <pre class="whitespace-pre-wrap break-words" phx-no-curly-interpolation><%= @output %><span :if={@streaming} class="ml-0.5 inline-block h-4 w-2 animate-pulse bg-zinc-100"></span></pre>
        <% else %>
          {render_slot(@inner_block)}
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  One line of a terminal transcript: a prompt sigil and the command after it.

  For composing a transcript by hand inside `terminal/1`'s inner block, where
  the commands and their output are separate values rather than one string.
  """
  attr :prompt, :string, default: "$"
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def terminal_line(assigns) do
    ~H"""
    <div class={["flex gap-2 whitespace-pre-wrap break-words", @class]} {@rest}>
      <span aria-hidden="true" class="select-none text-zinc-500">{@prompt}</span>
      <span class="min-w-0 flex-1">{render_slot(@inner_block)}</span>
    </div>
    """
  end

  @doc """
  The sources a message was drawn from, folded away until asked for.

  A `details`/`summary` pair rather than a collapsible built from script: the
  browser already knows how to open and close a disclosure, announce its state,
  and reach it from the keyboard.

  The source carries `not-prose` to escape Tailwind Typography. That plugin is
  not installed here, so the class would resolve to nothing and is dropped.
  """
  attr :id, :string, required: true
  attr :count, :integer, required: true
  attr :open, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global

  slot :trigger, doc: "replaces the default summary line"
  slot :inner_block, required: true, doc: "the sources, normally `source/1` calls"

  def sources(assigns) do
    ~H"""
    <%!-- `text-foreground`, not the source's `text-primary`: `--primary` here is
          the brand indigo (app.css), where shadcn's is the near-foreground ink.
          Left as written, the whole disclosure came out indigo. --%>
    <details id={@id} open={@open} class={["group mb-4 text-foreground text-xs", @class]} {@rest}>
      <summary class="flex cursor-pointer list-none items-center gap-2">
        <%= if @trigger == [] do %>
          <p class="font-medium">Used {@count} sources</p>
          <UI.icon name="chevron-down" class="h-4 w-4 transition-transform group-open:rotate-180" />
        <% else %>
          {render_slot(@trigger)}
        <% end %>
      </summary>
      <div class="mt-3 flex w-fit flex-col gap-2">
        {render_slot(@inner_block)}
      </div>
    </details>
    """
  end

  @doc "One source behind a message: a glyph and the title, linking out."
  attr :href, :string, required: true
  attr :title, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block

  def source(assigns) do
    ~H"""
    <a
      href={@href}
      class={["flex items-center gap-2", @class]}
      rel="noreferrer"
      target="_blank"
      {@rest}
    >
      <%= if @inner_block == [] do %>
        <UI.icon name="book" class="h-4 w-4" />
        <span class="block font-medium">{@title || @href}</span>
      <% else %>
        {render_slot(@inner_block)}
      <% end %>
    </a>
    """
  end

  @doc """
  A run of cited text, with the sources behind it one hover away.

  The chip names the first source by hostname and counts the rest, which is the
  useful summary: a reader scanning a paragraph wants to know *whose* claim it
  is before deciding to open anything.

  The card opens on hover and on focus within, so it is reachable without a
  pointer. The source paginates with a carousel; the sources are listed here
  instead.
  """
  attr :id, :string, required: true
  attr :class, :any, default: nil
  attr :rest, :global

  slot :inner_block, required: true, doc: "the cited text"

  slot :source, doc: "one source behind the citation" do
    attr :url, :string, required: true
    attr :title, :string
    attr :description, :string
  end

  def inline_citation(assigns) do
    ~H"""
    <span id={@id} class={["group relative inline items-center gap-1", @class]} {@rest}>
      <%!-- `bg-muted`, not the source's `bg-accent`: app.css redefines `--accent` as
           the brand indigo rather than shadcn's quiet hover surface, and a run of
           prose highlighted in indigo on hover reads as a selection, not a hint. --%>
      <span class="transition-colors group-hover:bg-muted">{render_slot(@inner_block)}</span>
      <%!-- A button wrapping the badge, not a badge that looks clickable. The
            card opens on hover and on focus within, and only a real control
            takes focus, so the keyboard reaches what the pointer does. --%>
      <button type="button" aria-describedby={@id <> "-card"} class="align-baseline">
        <UI.badge variant={:dim} class="ml-1 rounded-full">{citation_label(@source)}</UI.badge>
      </button>
      <span
        id={@id <> "-card"}
        role="note"
        class={[
          "invisible absolute top-full left-0 z-50 mt-1 w-80 rounded-md border bg-popover p-0",
          "text-popover-foreground opacity-0 shadow-md transition-opacity",
          "group-hover:visible group-hover:opacity-100",
          "group-focus-within:visible group-focus-within:opacity-100"
        ]}
      >
        <span class="flex items-center justify-end gap-2 rounded-t-md bg-secondary px-3 py-2 text-muted-foreground text-xs">
          {length(@source)} {(length(@source) == 1 && "source") || "sources"}
        </span>
        <span class="block divide-y">
          <span :for={source <- @source} class="block w-full space-y-2 p-4">
            <.inline_citation_source
              title={source[:title]}
              url={source[:url]}
              description={source[:description]}
            >
              <%!-- The slot's three attributes already say everything a source
                    has, so `<:source url=... title=... />` is the ordinary call
                    and carries no content. `render_slot/1` on an entry whose
                    `inner_block` is nil raises, so ask before rendering. --%>
              {source[:inner_block] && render_slot(source)}
            </.inline_citation_source>
          </span>
        </span>
      </span>
    </span>
    """
  end

  @doc "The title, address, and summary of one cited source."
  attr :title, :string, default: nil
  attr :url, :string, default: nil
  attr :description, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block

  def inline_citation_source(assigns) do
    ~H"""
    <span class={["block space-y-1", @class]} {@rest}>
      <span :if={@title} class="block truncate font-medium text-sm leading-tight">{@title}</span>
      <span :if={@url} class="block truncate break-all text-muted-foreground text-xs">{@url}</span>
      <span :if={@description} class="block text-muted-foreground text-sm leading-relaxed">
        {@description}
      </span>
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc "A quotation lifted from a cited source."
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def inline_citation_quote(assigns) do
    ~H"""
    <span
      class={["block border-muted border-l-2 pl-3 text-muted-foreground text-sm italic", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  How much of a model's context window a conversation has spent.

  The percentage is stated twice — as a number and as an arc — because the arc
  is the thing read at a glance and the number is the thing acted on. Hovering
  or focusing the control opens the breakdown: the split by kind, and what it
  cost.

  Past the window, the bar pins at full and the control carries
  `data-over-budget="true"`, so the one state worth seeing does not look
  identical to a full but legal context.
  """
  attr :id, :string, required: true
  attr :used_tokens, :integer, required: true
  attr :max_tokens, :integer, required: true
  attr :input_tokens, :integer, default: nil
  attr :output_tokens, :integer, default: nil
  attr :reasoning_tokens, :integer, default: nil
  attr :cached_tokens, :integer, default: nil
  attr :input_cost, :float, default: nil, doc: "US dollars, since there is no pricing table here"
  attr :output_cost, :float, default: nil
  attr :reasoning_cost, :float, default: nil
  attr :cached_cost, :float, default: nil
  attr :total_cost, :float, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  def context(assigns) do
    fraction = safe_fraction(assigns.used_tokens, assigns.max_tokens)

    assigns =
      assign(assigns,
        fraction: fraction,
        bar_percent: min(fraction * 100, 100.0),
        over_budget?: fraction > 1.0
      )

    ~H"""
    <div
      id={@id}
      class={["group relative inline-block", @class]}
      data-over-budget={to_string(@over_budget?)}
      {@rest}
    >
      <UI.button variant={:ghost} size={:sm} aria-describedby={@id <> "-detail"}>
        <span class={["font-medium", (@over_budget? && "text-danger") || "text-muted-foreground"]}>
          {percent_text(@fraction)}
        </span>
        <span
          role="img"
          aria-label="Model context usage"
          class="inline-block size-5 shrink-0 rounded-full"
          style={ring_style(@bar_percent)}
        ></span>
      </UI.button>
      <div
        id={@id <> "-detail"}
        role="note"
        class={[
          "invisible absolute top-full right-0 z-50 mt-1 min-w-60 divide-y overflow-hidden",
          "rounded-md border bg-popover text-popover-foreground opacity-0 shadow-md",
          "transition-opacity group-hover:visible group-hover:opacity-100",
          "group-focus-within:visible group-focus-within:opacity-100"
        ]}
      >
        <div class="w-full space-y-2 p-3">
          <div class="flex items-center justify-between gap-3 text-xs">
            <p>{percent_text(@fraction)}</p>
            <p class="font-mono text-muted-foreground">
              {compact_number(@used_tokens)} / {compact_number(@max_tokens)}
            </p>
          </div>
          <div
            class="h-2 w-full overflow-hidden rounded-full bg-muted"
            role="progressbar"
            aria-label="Context used"
            aria-valuemin="0"
            aria-valuemax="100"
            aria-valuenow={round(@bar_percent)}
          >
            <div
              class={["h-full rounded-full", (@over_budget? && "bg-danger") || "bg-primary"]}
              style={"width: #{@bar_percent}%"}
            >
            </div>
          </div>
        </div>
        <div
          :if={@input_tokens || @output_tokens || @reasoning_tokens || @cached_tokens}
          class="w-full space-y-1 p-3"
        >
          <.usage_row :if={@input_tokens} label="Input" tokens={@input_tokens} cost={@input_cost} />
          <.usage_row :if={@output_tokens} label="Output" tokens={@output_tokens} cost={@output_cost} />
          <.usage_row
            :if={@reasoning_tokens}
            label="Reasoning"
            tokens={@reasoning_tokens}
            cost={@reasoning_cost}
          />
          <.usage_row :if={@cached_tokens} label="Cache" tokens={@cached_tokens} cost={@cached_cost} />
        </div>
        <div
          :if={@total_cost}
          class="flex w-full items-center justify-between gap-3 bg-secondary p-3 text-xs"
        >
          <span class="text-muted-foreground">Total cost</span>
          <span>{currency(@total_cost)}</span>
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :tokens, :integer, required: true
  attr :cost, :float, default: nil

  defp usage_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between text-xs">
      <span class="text-muted-foreground">{@label}</span>
      <span>
        {compact_number(@tokens)}
        <span :if={@cost} class="ml-2 text-muted-foreground">
          • {currency(@cost)}
        </span>
      </span>
    </div>
    """
  end

  @doc """
  A named thing the model produced, in a frame with its own actions.

  The frame is the point: an artifact is a deliverable, not a paragraph, so it
  gets a header that names it and a body that scrolls on its own rather than
  extending the transcript.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  slot :actions, doc: "controls at the trailing edge of the header, normally `artifact_action/1`"
  slot :inner_block, required: true

  def artifact(assigns) do
    ~H"""
    <div
      id={@id}
      class={["flex flex-col overflow-hidden rounded-lg border bg-background shadow-sm", @class]}
      {@rest}
    >
      <div class="flex items-center justify-between border-b bg-muted/50 px-4 py-3">
        <div class="min-w-0">
          <p class="font-medium text-foreground text-sm">{@title}</p>
          <p :if={@description} class="text-muted-foreground text-sm">{@description}</p>
        </div>
        <div :if={@actions != []} class="flex items-center gap-1">
          {render_slot(@actions)}
        </div>
      </div>
      <div class="flex-1 overflow-auto p-4">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  One icon-only control in an artifact's header.

  The source wraps each of these in a Radix tooltip. There is no tooltip
  primitive here, so the hint is the native `title` and the accessible name is
  `label` — which the control needs regardless, tooltip or not.
  """
  attr :icon, :string, required: true, doc: "a name from the governed icon set"
  attr :label, :string, required: true, doc: "the accessible name of the control"
  attr :tooltip, :string, default: nil, doc: "hover hint; falls back to `label`"
  attr :class, :any, default: nil

  attr :rest, :global,
    include: ~w(disabled form name value href navigate patch phx-click phx-value-id)

  def artifact_action(assigns) do
    ~H"""
    <UI.button
      variant={:ghost}
      size={:sm}
      class={["size-8 p-0 text-muted-foreground hover:text-foreground", @class]}
      title={@tooltip || @label}
      aria-label={@label}
      {@rest}
    >
      <UI.icon name={@icon} class="size-4" />
    </UI.button>
    """
  end

  @doc """
  A tool asking permission, and the record of what was decided.

  The decided states are not a smaller version of the request: the controls go
  away and the outcome takes their place, so a transcript scrolled back through
  still says what was allowed.
  """
  attr :id, :string, required: true

  attr :state, :atom,
    values: [:requested, :approved, :denied],
    required: true,
    doc: "`:requested` shows the controls; the other two show the outcome"

  attr :title, :string, default: nil
  attr :reason, :string, default: nil, doc: "why the decision went the way it did"
  attr :class, :any, default: nil
  attr :rest, :global

  slot :inner_block, doc: "what is being asked for; replaces `title`"
  slot :actions, doc: "the approve and deny controls, normally `confirmation_action/1`"

  def confirmation(assigns) do
    ~H"""
    <UI.alert
      id={@id}
      variant={confirmation_variant(@state)}
      appearance={:notice}
      class={@class}
      data-state={@state}
      {@rest}
    >
      <%!-- One flex column inside the alert, not on it. `UI.alert/1` wraps its
            inner block in a section of its own, so a column declared on the
            alert would lay out the alert's parts rather than these. --%>
      <div class="flex flex-col gap-2">
        <span class="inline">
          <%= if @inner_block == [] do %>
            {@title}
          <% else %>
            {render_slot(@inner_block)}
          <% end %>
        </span>
        <span :if={@state != :requested} class="inline text-muted-foreground text-sm">
          {confirmation_outcome(@state)}<span :if={@reason}>: {@reason}</span>
        </span>
        <span
          :if={@state == :requested && @actions != []}
          class="flex items-center justify-end gap-2 self-end"
        >
          {render_slot(@actions)}
        </span>
      </div>
    </UI.alert>
    """
  end

  @doc "One control on a confirmation: approve, or deny."
  attr :variant, :atom,
    values: [:primary, :secondary, :outline, :ghost, :destructive, :chip, :notched, :link],
    default: :secondary

  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled form name value phx-click phx-value-id)
  slot :inner_block, required: true

  def confirmation_action(assigns) do
    ~H"""
    <UI.button variant={@variant} class={["h-8 px-3 text-sm", @class]} {@rest}>
      {render_slot(@inner_block)}
    </UI.button>
    """
  end

  @doc """
  A question back to the reader: a set of choices, and room to say something
  else.

  Both halves matter. A model that can only offer choices asks the wrong
  question sooner or later, and a model that only offers a text box makes the
  reader do the work it already did.

  Choices are radio inputs in single mode and checkboxes in multiple mode, so
  selection is the browser's job and the answer arrives as ordinary form
  parameters.
  """
  attr :id, :string, required: true
  attr :prompt, :string, required: true
  attr :description, :string, default: nil
  attr :name, :string, default: "question", doc: "the parameter the choices submit under"

  attr :selection_mode, :atom,
    values: [:single, :multiple],
    default: :single

  attr :selected, :list, default: [], doc: "the values that arrive already chosen"
  attr :text, :string, default: nil, doc: "the freeform response that arrives already written"
  attr :text_label, :string, default: "Anything else?"
  attr :placeholder, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :submit_label, :string, default: "Submit"
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(phx-submit phx-change phx-target method action)

  slot :option, doc: "one choice" do
    attr :value, :string, required: true
  end

  def question(assigns) do
    assigns =
      assign(assigns,
        input_type: (assigns.selection_mode == :single && "radio") || "checkbox",
        field_name: (assigns.selection_mode == :single && assigns.name) || assigns.name <> "[]"
      )

    ~H"""
    <form id={@id} class={["space-y-4 rounded-lg border bg-background p-4", @class]} {@rest}>
      <p class="font-medium text-sm">{@prompt}</p>
      <p :if={@description} class="text-muted-foreground text-sm">{@description}</p>
      <fieldset :if={@option != []} class="flex flex-wrap gap-2" disabled={@disabled}>
        <legend class="sr-only">{@prompt}</legend>
        <label
          :for={{option, index} <- Enum.with_index(@option)}
          for={"#{@id}-option-#{index}"}
          class={
            [
              "btn h-auto cursor-pointer whitespace-normal",
              "has-[:checked]:bg-primary has-[:checked]:text-primary-foreground",
              # The control the reader operates is the chip; the input inside it is
              # visually hidden, so the focus ring has to be drawn by the chip or
              # keyboard selection happens with nothing on screen moving.
              "has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2",
              "has-[:focus-visible]:outline-ring"
            ]
          }
          data-variant="outline"
          data-size="sm"
        >
          <input
            type={@input_type}
            id={"#{@id}-option-#{index}"}
            name={@field_name}
            value={option.value}
            checked={option.value in @selected}
            class="sr-only"
          />
          {render_slot(option)}
        </label>
      </fieldset>
      <div class="space-y-1">
        <UI.label for={@id <> "-text"}>{@text_label}</UI.label>
        <UI.textarea
          id={@id <> "-text"}
          name={@name <> "_text"}
          value={@text}
          class="min-h-20"
          placeholder={@placeholder}
          disabled={@disabled}
        />
      </div>
      <div class="flex items-center justify-end gap-2">
        <UI.button type="submit" disabled={@disabled}>{@submit_label}</UI.button>
      </div>
    </form>
    """
  end

  @doc """
  A generated image, in a frame that does not let it push the page around.

  Takes either a `src` or the `base64` and `media_type` a model returns, which
  become a data URI. `alt` is required: an image with no alternative text is
  the whole message to a reader who cannot see it, and a generated image is
  exactly the case where nothing nearby says what it shows.

  Markdown cannot carry this. `OpenAgents.Markdown.to_html/2` sanitizes to an
  allowlist with no `img` in it, so an image written into Markdown is dropped.
  """
  attr :id, :string, required: true
  attr :alt, :string, required: true
  attr :src, :string, default: nil
  attr :base64, :string, default: nil
  attr :media_type, :string, default: nil, doc: "an IANA media type, such as `image/png`"
  attr :class, :any, default: nil
  attr :rest, :global

  def image(assigns) do
    ~H"""
    <img
      id={@id}
      src={image_source(@src, @base64, @media_type)}
      alt={@alt}
      class={["h-auto max-w-full overflow-hidden rounded-md", @class]}
      {@rest}
    />
    """
  end

  # ── formatting ────────────────────────────────────────────────────────────

  defp image_source(nil, base64, media_type) when is_binary(base64) and is_binary(media_type),
    do: "data:#{media_type};base64,#{base64}"

  defp image_source(src, _base64, _media_type), do: src

  defp confirmation_variant(:requested), do: :warning
  defp confirmation_variant(:approved), do: :success
  defp confirmation_variant(:denied), do: :danger

  defp confirmation_outcome(:approved), do: "Approved"
  defp confirmation_outcome(:denied), do: "Denied"

  defp citation_label([]), do: "unknown"

  defp citation_label([first | rest]) do
    host = URI.parse(first[:url] || "").host || "unknown"
    if rest == [], do: host, else: "#{host} +#{length(rest)}"
  end

  defp safe_fraction(_used, max) when max in [nil, 0], do: 0.0
  defp safe_fraction(used, max), do: used / max

  # A masked conic gradient. Two stops draw the arc against a quarter-strength
  # track, and the radial mask cuts the middle out, which is what turns a pie
  # into a ring. `currentColor` keeps it in the colour of the text beside it,
  # exactly as the drawn version did.
  defp ring_style(percent) do
    "background: conic-gradient(currentColor #{percent}%, " <>
      "color-mix(in oklab, currentColor 25%, transparent) 0); " <>
      "mask: radial-gradient(closest-side, transparent 70%, black 72%); " <>
      "-webkit-mask: radial-gradient(closest-side, transparent 70%, black 72%);"
  end

  defp percent_text(fraction) do
    rounded = Float.round(fraction * 100, 1)

    if rounded == Float.round(rounded, 0) do
      "#{trunc(rounded)}%"
    else
      "#{rounded}%"
    end
  end

  defp currency(amount), do: "$#{:erlang.float_to_binary(amount / 1, decimals: 2)}"

  # `Intl.NumberFormat(..., {notation: "compact"})` in Elixir: two significant
  # digits below ten, whole numbers above it, and no trailing zero.
  defp compact_number(value) when value < 1000, do: Integer.to_string(value)

  defp compact_number(value), do: compact_number(value / 1000, @byte_units)

  defp compact_number(value, [unit]), do: "#{compact_mantissa(value)}#{unit}"

  defp compact_number(value, [unit | rest]) do
    if value < 1000,
      do: "#{compact_mantissa(value)}#{unit}",
      else: compact_number(value / 1000, rest)
  end

  defp compact_mantissa(value) when value < 10 do
    rounded = Float.round(value, 1)

    if rounded == Float.round(rounded, 0),
      do: Integer.to_string(trunc(rounded)),
      else: "#{rounded}"
  end

  defp compact_mantissa(value), do: Integer.to_string(round(value))
end
