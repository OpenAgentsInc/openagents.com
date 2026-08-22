defmodule OpenAgentsWeb.AI.Conversation do
  @moduledoc """
  The transcript surface: the scroller, the messages inside it, and the small
  chrome that sits beside them.

  Ported from Vercel's AI Elements (MIT, © 2025 Vercel), specifically
  `conversation.tsx`, `message.tsx`, `shimmer.tsx`, `suggestion.tsx`,
  `toolbar.tsx`, `controls.tsx`, and `persona.tsx` at `6a9d5b1`. The Tailwind
  classes are the point of the port and are carried across verbatim wherever
  they resolve against this product's tokens; the React machinery underneath
  them is not. Every substitution is named in the doc of the component that
  makes it, so a later reader can tell a deliberate swap from a typo.

  ## What became what

  Compound React components become sibling function components — `message/1`
  and `message_content/1` rather than one component with a slot per position —
  because the caller decides the order of avatar, content, and actions, and a
  slot per position would only rename that freedom while costing the ability to
  drop a part entirely.

  `conversation_scroll_button/1` is the exception, and is both: it stays a
  public component so it can be placed and tested on its own, and
  `conversation/1` renders one by default. The button is positioned against the
  conversation's own box, so it has to sit *outside* the scrolling viewport;
  leaving that placement to the caller would put it inside and let it scroll
  away, which is the one thing the control exists to prevent.

  ## No React

  `use-stick-to-bottom` becomes one colocated hook. It listens for scroll,
  watches the content box for growth, pins the viewport to the bottom while the
  reader is already there, and toggles the `hidden` utility on the scroll
  button. It never writes DOM content, so `phx-update="ignore"` is deliberately
  absent: setting it would freeze the transcript the hook exists to follow.

  Rive drives `Persona` in the source — a WebGL2 canvas playing a remote `.riv`
  state machine. Neither the runtime nor the asset is available here, so
  `persona/1` is a name, an avatar, and a state marker instead.

  ## Markdown

  Where AI Elements renders `<Streamdown>`, `message_content/1` calls
  `OpenAgents.Markdown.to_html/2`, passing `streaming: true` while the caller
  says text is still arriving, so the same guards that protect the chat
  transcript protect this one.
  """

  use Phoenix.Component

  alias OpenAgents.Markdown
  alias OpenAgentsWeb.UI

  @doc """
  The transcript scroller.

  Two boxes, as in the source: the outer one is the positioning context and
  clips (`overflow-y-hidden`), the inner one scrolls. That split is what lets
  `conversation_scroll_button/1` hold still at the bottom edge while the
  transcript moves behind it.

  `role="log"` is kept from the source, so assistive technology announces
  arriving turns rather than re-reading the whole thread.
  """
  attr :id, :string, required: true
  attr :class, :any, default: nil

  attr :scroll_button, :boolean,
    default: true,
    doc: "render the built-in scroll-to-bottom control outside the scrolling viewport"

  attr :scroll_button_label, :string, default: "Scroll to the newest message"
  attr :rest, :global
  slot :inner_block, required: true

  def conversation(assigns) do
    ~H"""
    <div
      id={@id}
      class={["relative flex-1 overflow-y-hidden", @class]}
      role="log"
      phx-hook=".StickToBottom"
      {@rest}
    >
      <div id={"#{@id}-viewport"} class="h-full overflow-y-auto" data-conversation-viewport="true">
        {render_slot(@inner_block)}
      </div>
      <.conversation_scroll_button
        :if={@scroll_button}
        id={"#{@id}-scroll-button"}
        label={@scroll_button_label}
      />
      <script :type={Phoenix.LiveView.ColocatedHook} name=".StickToBottom">
        const THRESHOLD = 24

        export default {
          mounted() {
            this.viewport = this.el.querySelector("[data-conversation-viewport]")
            if (!this.viewport) return

            this.button = this.el.querySelector("[data-conversation-scroll-button]")
            this.pinned = true

            this.onScroll = () => {
              this.pinned = this.atBottom()
              this.sync()
            }
            this.viewport.addEventListener("scroll", this.onScroll, { passive: true })

            if (this.button) {
              this.onClick = () => {
                this.pinned = true
                this.stick("smooth")
              }
              this.button.addEventListener("click", this.onClick)
            }

            if (window.ResizeObserver) {
              this.observer = new ResizeObserver(() => this.stick("smooth"))
              for (const child of this.viewport.children) {
                this.observer.observe(child)
              }
            }

            this.stick("auto")
          },

          updated() {
            this.stick("smooth")
          },

          destroyed() {
            if (this.viewport && this.onScroll) {
              this.viewport.removeEventListener("scroll", this.onScroll)
            }
            if (this.button && this.onClick) {
              this.button.removeEventListener("click", this.onClick)
            }
            if (this.observer) {
              this.observer.disconnect()
            }
          },

          atBottom() {
            const { scrollHeight, scrollTop, clientHeight } = this.viewport
            return scrollHeight - scrollTop - clientHeight <= THRESHOLD
          },

          stick(behavior) {
            if (this.pinned) {
              this.viewport.scrollTo({ top: this.viewport.scrollHeight, behavior })
            }
            this.sync()
          },

          sync() {
            const atBottom = this.atBottom()
            this.el.dataset.atBottom = String(atBottom)
            if (this.button) {
              this.button.classList.toggle("hidden", atBottom)
            }
          }
        }
      </script>
    </div>
    """
  end

  @doc "The column of turns inside `conversation/1`."
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def conversation_content(assigns) do
    ~H"""
    <div id={@id} class={["flex flex-col gap-8 p-4", @class]} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  What stands in for a transcript that has not started.

  The source takes either `children` or the title, description, and icon triple.
  Both branches survive: give the slot content and it replaces the default
  heading entirely.
  """
  attr :id, :string, default: nil
  attr :title, :string, default: "No messages yet"
  attr :description, :string, default: "Start a conversation to see messages here"
  attr :icon, :string, default: nil, doc: "a name for `OpenAgentsWeb.UI.icon/1`"
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block

  def conversation_empty_state(assigns) do
    assigns = assign(assigns, :custom?, assigns.inner_block != [])

    ~H"""
    <div
      id={@id}
      class={["flex size-full flex-col items-center justify-center gap-3 p-8 text-center", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
      <div :if={!@custom? && @icon} class="text-muted-foreground">
        <UI.icon name={@icon} class="size-6" />
      </div>
      <div :if={!@custom?} class="space-y-1">
        <h3 class="font-medium text-sm">{@title}</h3>
        <p :if={@description} class="text-muted-foreground text-sm">{@description}</p>
      </div>
    </div>
    """
  end

  @doc """
  The control that returns the reader to the newest turn.

  Hidden until the colocated hook in `conversation/1` reports that the viewport
  has moved off the bottom. It starts hidden because a freshly rendered
  transcript is already pinned there.

  Two substitutions. It drops `dark:bg-background dark:hover:bg-muted`, which in
  AI Elements repaints an outline button for a dark page: this product's
  `outline` variant already resolves against whichever of the two palettes is
  active, and Tailwind's `dark:` variant follows the operating-system preference
  rather than this product's `data-theme`, so keeping the pair would paint the
  wrong surface exactly when a reader had overridden that preference. It also
  spells `size="icon"` as `size-9 p-0`, because `OpenAgentsWeb.UI.button/1`
  deliberately exposes no icon size.
  """
  attr :id, :string, required: true
  attr :label, :string, default: "Scroll to the newest message"
  attr :class, :any, default: nil
  attr :rest, :global

  def conversation_scroll_button(assigns) do
    ~H"""
    <UI.button
      id={@id}
      variant={:outline}
      class={[
        "hidden absolute bottom-4 left-[50%] size-9 translate-x-[-50%] rounded-full p-0",
        @class
      ]}
      aria-label={@label}
      data-conversation-scroll-button="true"
      {@rest}
    >
      <UI.icon name="arrow-down" class="size-4" />
    </UI.button>
    """
  end

  @doc """
  One turn.

  `from` lands as the `is-user` or `is-assistant` marker class the source uses,
  which is what every `group-[.is-user]:` rule inside `message_content/1` reads.
  The branch navigation around it is not ported: it is React state with no
  markup of its own beyond two chevron buttons.
  """
  attr :id, :string, default: nil
  attr :from, :string, values: ~w(user assistant system), required: true
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def message(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "group flex w-full max-w-[95%] flex-col gap-2",
        if(@from == "user", do: "is-user ml-auto justify-end", else: "is-assistant"),
        @class
      ]}
      data-from={@from}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  The body of one turn.

  Given `text`, it renders Markdown through `OpenAgents.Markdown.to_html/2` and
  wraps it in the class the source puts on `MessageResponse`, so the first and
  last blocks add no margin inside the bubble. Pass `streaming` while the turn
  is still arriving. Given a slot instead, it renders that; both may be present,
  and the Markdown comes first.

  The source's `is-user:dark` is dropped. It is a project-local Tailwind variant
  that flips a user bubble to the dark palette by adding shadcn's `.dark` class,
  and this product selects its palette with `data-theme` on the root element
  rather than with a class on an arbitrary box.
  """
  attr :id, :string, default: nil
  attr :text, :string, default: nil
  attr :streaming, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block

  def message_content(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "flex w-fit min-w-0 max-w-full flex-col gap-2 overflow-hidden text-sm",
        "group-[.is-user]:ml-auto group-[.is-user]:rounded-lg group-[.is-user]:bg-secondary",
        "group-[.is-user]:px-4 group-[.is-user]:py-3 group-[.is-user]:text-foreground",
        "group-[.is-assistant]:text-foreground",
        @class
      ]}
      {@rest}
    >
      <div
        :if={@text}
        class="message-markdown size-full [&>*:first-child]:mt-0 [&>*:last-child]:mb-0"
      >
        {Markdown.to_html(@text, streaming: @streaming)}
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  The face beside a turn.

  Recovered from the source's earlier `Message` (AI Elements `d5f1159^`), the
  last revision that carried an avatar. Built on `OpenAgentsWeb.UI.avatar/1`
  rather than a second avatar implementation; the `size-8 ring-1 ring-border`
  treatment is the source's, and `size-8` outranks the primitive's own geometry
  because Tailwind utilities land in a later cascade layer than Basecoat
  components.
  """
  attr :id, :string, default: nil
  attr :src, :string, default: nil
  attr :name, :string, default: nil
  attr :alt, :string, default: ""
  attr :class, :any, default: nil
  attr :rest, :global

  def message_avatar(assigns) do
    assigns = assign(assigns, :fallback, String.slice(assigns.name || "ME", 0, 2))

    ~H"""
    <UI.avatar
      id={@id}
      src={@src}
      alt={@alt}
      fallback={@fallback}
      class={["size-8 ring-1 ring-border", @class]}
      {@rest}
    />
    """
  end

  @doc "The row of controls under a turn."
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def message_actions(assigns) do
    ~H"""
    <div id={@id} class={["flex items-center gap-1", @class]} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  One control under a turn.

  The source wraps the button in a Radix tooltip. There is no tooltip primitive
  in `OpenAgentsWeb.UI`, and adding one would mean adding CSS, so the hint
  reaches a pointer through the native `title` attribute and assistive
  technology through the source's own `sr-only` span. `size="icon-sm"` becomes
  `size={:xs}`, because `OpenAgentsWeb.UI.button/1` exposes no icon size.
  """
  attr :id, :string, default: nil
  attr :tooltip, :string, default: nil
  attr :label, :string, default: nil

  attr :variant, :atom,
    values: [:primary, :secondary, :outline, :ghost, :destructive],
    default: :ghost

  attr :size, :atom, values: [:default, :xs, :sm, :lg], default: :xs
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def message_action(assigns) do
    assigns = assign(assigns, :name, assigns.label || assigns.tooltip)

    ~H"""
    <UI.button
      id={@id}
      variant={@variant}
      size={@size}
      class={@class}
      title={@tooltip}
      aria-label={@name}
      {@rest}
    >
      {render_slot(@inner_block)}
      <span :if={@name} class="sr-only">{@name}</span>
    </UI.button>
    """
  end

  @doc """
  Text that reads as still arriving.

  The source animates `background-position` across a 250%-wide gradient with
  `motion/react`. The gradient machinery is kept exactly — clipped to the
  glyphs, muted base, bright band — and the sweep comes from the `shimmer-sweep`
  keyframes in `assets/css/openagents.css`, which the `data-shimmer` marker
  below selects. An animation outranks the `[background-position:50%_center]`
  utility that sets the resting position, so the band moves rather than sitting
  still. `motion-reduce:animate-none` stops it, and the stylesheet states the
  same guard, so a reader who asked for less motion gets a still band from
  whichever rule lands first.

  The highlight also moves from `--color-background` to `--color-foreground`.
  AI Elements is a light-first surface where the page ground is the brightest
  value available; on this product's dark default the same token is nearly
  black, so the band would darken the text instead of lighting it.

  `spread` is scaled by the length of the text, as in the source, so a long line
  gets a proportionally wider band.
  """
  attr :id, :string, default: nil
  attr :text, :string, required: true
  attr :tag, :string, default: "p"
  attr :spread, :integer, default: 2
  attr :class, :any, default: nil
  attr :rest, :global

  def shimmer(assigns) do
    assigns = assign(assigns, :dynamic_spread, String.length(assigns.text) * assigns.spread)

    ~H"""
    <.dynamic_tag
      tag_name={@tag}
      id={@id}
      class={[
        "relative inline-block bg-[length:250%_100%,auto] bg-clip-text text-transparent",
        "[--bg:linear-gradient(90deg,#0000_calc(50%-var(--spread)),var(--color-foreground),#0000_calc(50%+var(--spread)))]",
        "[background-repeat:no-repeat,padding-box] [background-position:50%_center]",
        "[background-image:var(--bg),linear-gradient(var(--color-muted-foreground),var(--color-muted-foreground))]",
        "motion-reduce:animate-none",
        @class
      ]}
      style={"--spread: #{@dynamic_spread}px"}
      data-shimmer="true"
      {@rest}
    >
      {@text}
    </.dynamic_tag>
    """
  end

  @doc """
  A horizontal rail of openers.

  The source's Radix `ScrollArea` is a plain overflow container here. It exists
  to carry a scrollbar the source then hides with `<ScrollBar className="hidden">`,
  which native `overflow-x-auto` already does wherever overlay scrollbars are
  the platform default. As in the source, `class` lands on the inner row rather
  than on the scroller, so a caller can change the gap without breaking the
  clip.
  """
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def suggestions(assigns) do
    ~H"""
    <div id={@id} class="w-full overflow-x-auto whitespace-nowrap" {@rest}>
      <div class={["flex w-max flex-nowrap items-center gap-2", @class]}>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  One opener.

  The source hands the suggestion text back through `onClick`. Here the caller
  attaches `phx-click` and `phx-value-*` through the global passthrough, which
  is the same contract without a closure. The text also lands on `value`, so a
  form submission carries it without a second attribute.
  """
  attr :id, :string, default: nil
  attr :suggestion, :string, required: true
  attr :variant, :atom, values: [:primary, :secondary, :outline, :ghost], default: :outline
  attr :size, :atom, values: [:default, :xs, :sm, :lg], default: :sm
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block

  def suggestion(assigns) do
    ~H"""
    <UI.button
      id={@id}
      variant={@variant}
      size={@size}
      class={["cursor-pointer rounded-full px-4", @class]}
      value={@suggestion}
      {@rest}
    >
      <%= if @inner_block == [] do %>
        {@suggestion}
      <% else %>
        {render_slot(@inner_block)}
      <% end %>
    </UI.button>
    """
  end

  @doc """
  The small floating bar of controls that belongs to one object.

  In the source this is `@xyflow/react`'s `NodeToolbar`, which positions itself
  below the node it names. There is no React Flow canvas here, so what survives
  is the bar; the caller decides where it sits.

  `border` becomes `border border-border`. Tailwind v4 resolves a bare `border`
  to `currentcolor`, and this product does not carry shadcn's global
  `* { border-color: var(--border) }` rule, so the unqualified class would draw
  the edge in the text colour.
  """
  attr :id, :string, default: nil
  attr :label, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def toolbar(assigns) do
    ~H"""
    <div
      id={@id}
      class={["flex items-center gap-1 rounded-sm border border-border bg-background p-1.5", @class]}
      role={@label && "toolbar"}
      aria-label={@label}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  The canvas control cluster.

  `@xyflow/react`'s `Controls` supplies the zoom and fit buttons in the source,
  so the wrapper is all that is portable and the buttons come from the slot. The
  child rules carry the intent and stay: whatever buttons land inside read as
  one segmented cluster rather than as separate controls.

  `border` becomes `border border-border` for the reason given on `toolbar/1`.
  """
  attr :id, :string, default: nil
  attr :label, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def controls(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "gap-px overflow-hidden rounded-md border border-border bg-card p-1 shadow-none!",
        "[&>button]:rounded-md [&>button]:border-none! [&>button]:bg-transparent!",
        "[&>button]:hover:bg-secondary!",
        @class
      ]}
      role={@label && "group"}
      aria-label={@label}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @persona_states %{
    "idle" => {"idle", "Idle"},
    "listening" => {"listening", "Listening"},
    "thinking" => {"running", "Thinking"},
    "speaking" => {"speaking", "Speaking"},
    "asleep" => {"ended", "Asleep"}
  }

  @doc """
  Who is on the other side of the conversation, and what they are doing.

  The source is a Rive WebGL2 canvas playing one of six remote `.riv` files,
  switched by a state machine and recoloured from the page theme. None of that
  travels: the runtime is a React package, the assets sit on a third-party
  origin, and a WebGL context per persona is a cost this surface has not earned.
  What is portable is the contract — a fixed set of states, one presence marker,
  `size-16 shrink-0` for the mark — so this is a name, an avatar, and a state.

  Two of the five states have no marker of their own in
  `OpenAgentsWeb.UI.status_indicator/1`, so they join the nearest existing
  meaning rather than introduce a colour: `thinking` reads as `running`
  (activity, blue) and `asleep` as `ended` (a resting fact, grey).

  The marker is decorative because the word beside it says the same thing, which
  is the rule `status_indicator/1` documents.
  """
  attr :id, :string, default: nil
  attr :name, :string, required: true
  attr :state, :string, values: ~w(idle listening thinking speaking asleep), default: "idle"
  attr :status_label, :string, default: nil
  attr :src, :string, default: nil
  attr :fallback, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  def persona(assigns) do
    {marker, default_label} = Map.fetch!(@persona_states, assigns.state)

    assigns =
      assigns
      |> assign(:marker, marker)
      |> assign(:label, assigns.status_label || default_label)
      |> assign(:initials, assigns.fallback || String.slice(assigns.name, 0, 2))

    ~H"""
    <div id={@id} class={["flex items-center gap-3", @class]} data-state={@state} {@rest}>
      <UI.avatar src={@src} alt="" fallback={@initials} class="size-16 shrink-0" />
      <div class="flex flex-col gap-1">
        <span class="font-medium text-sm">{@name}</span>
        <span class="flex items-center gap-2 text-muted-foreground text-sm">
          <UI.status_indicator state={@marker} label={@label} decorative />
          {@label}
        </span>
      </div>
    </div>
    """
  end
end
