defmodule OpenAgentsWeb.SarahUI do
  @moduledoc """
  Sarah's interface primitives.

  Every component here wraps a vendored Basecoat class and exposes Sarah's
  vocabulary rather than Basecoat's. Product surfaces build interface only from
  these components; they do not author component-level CSS classes. See
  `DESIGN.md`, `assets/css/style-sarah.css`, and
  `docs/decisions/0003-basecoat-component-library.md`.

  Basecoat expresses variants as data attributes (`data-variant`, `data-size`),
  so each `attr` maps straight onto the DOM with no class-merging utility.
  `attr` values are constrained, which makes an unknown variant a compile error
  rather than an unstyled control.

  Two rules from `DESIGN.md` are enforced by these signatures rather than by
  review:

    * There is no icon-only control, so `button/1` exposes no icon size.
    * Semantic color reinforces a text label and never replaces one, so
      `status_indicator/1` requires a label.

  No component accepts provider identifiers or private recall content. Tool
  activity reaches `event_header/1` only as the bounded, already-scrubbed
  durable projection that `INVARIANTS.md` UI-002 sanctions — derived in
  `OpenAgentsWeb.ToolActivity`, byte-capped before it touches a template.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  A boxed control.

  `:link` renders Sarah's inline underlined action rather than a boxed button
  and ignores `size`; pair it with `tone={:danger}` for a destructive inline
  action.

  `:chip` is the compact keycap treatment: a quiet raised surface with a
  hairline border, for a secondary control that should read as an object in the
  chrome rather than as a link.

  `:notched` is a port of Arwes' octagon button: two opposite corners cut away,
  a bright edge, and a glow that follows the cut shape. Arwes draws that outline
  as an SVG behind the content; here it is a `clip-path` polygon, which needs no
  runtime. Reserved for a page's single primary action — it is loud, and the
  product only has room for one.

  Given `href`, it renders an `<a>` with the same visual treatment — like
  `text_button/1` — so a download or plain GET destination can wear any boxed
  variant without hand-written markup.
  """
  attr :variant, :atom,
    values: [:primary, :secondary, :outline, :ghost, :destructive, :chip, :notched, :link],
    default: :primary

  attr :size, :atom, values: [:default, :xs, :sm, :lg], default: :default
  attr :tone, :atom, values: [:default, :danger], default: :default
  attr :type, :string, default: "button"
  attr :class, :any, default: nil

  attr :rest, :global,
    include: ~w(disabled form name value popovertarget popovertargetaction download href)

  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <.link
      :if={@rest[:href]}
      class={["btn", @class]}
      data-variant={@variant}
      data-size={@size != :default && @size}
      data-tone={@tone != :default && @tone}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    <button
      :if={!@rest[:href]}
      type={@type}
      class={["btn", @class]}
      data-variant={@variant}
      data-size={@size != :default && @size}
      data-tone={@tone != :default && @tone}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc """
  An inline underlined action. Shorthand for `button/1` with `variant={:link}`.

  Renders an `<a>` when given `navigate`, `patch`, or `href`, so export and
  download links carry the same affordance as in-page actions.
  """
  attr :tone, :atom, values: [:default, :danger], default: :default
  attr :type, :string, default: "button"
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled form name value href download navigate patch)
  slot :inner_block, required: true

  def text_button(assigns) do
    ~H"""
    <.link
      :if={@rest[:href] || @rest[:navigate] || @rest[:patch]}
      class={["btn", @class]}
      data-variant="link"
      data-tone={@tone != :default && @tone}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    <button
      :if={!(@rest[:href] || @rest[:navigate] || @rest[:patch])}
      type={@type}
      class={["btn", @class]}
      data-variant="link"
      data-tone={@tone != :default && @tone}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc "A single-line text control."
  attr :id, :string, default: nil
  attr :name, :string, default: nil
  attr :value, :string, default: nil
  attr :type, :string, default: "text"
  attr :class, :any, default: nil

  attr :rest, :global,
    include: ~w(autocomplete disabled maxlength minlength pattern placeholder readonly required)

  def input(assigns) do
    ~H"""
    <input type={@type} id={@id} name={@name} value={@value} class={["input", @class]} {@rest} />
    """
  end

  @doc "A multiline text control."
  attr :id, :string, default: nil
  attr :name, :string, default: nil
  attr :value, :string, default: nil
  attr :class, :any, default: nil

  attr :rest, :global,
    include: ~w(autocomplete disabled maxlength placeholder readonly required rows)

  def textarea(assigns) do
    ~H"""
    <textarea id={@id} name={@name} class={["textarea", @class]} {@rest}>{@value}</textarea>
    """
  end

  @doc "A label bound to a control."
  attr :for, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def label(assigns) do
    ~H"""
    <label for={@for} class={["label", @class]} {@rest}>{render_slot(@inner_block)}</label>
    """
  end

  @doc "A labelled control group."
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def field(assigns) do
    ~H"""
    <div class={["field", @class]} {@rest}>{render_slot(@inner_block)}</div>
    """
  end

  @doc """
  An inline notice.

  Always renders in flow. `DESIGN.md` forbids toast-only errors, so there is no
  floating or auto-dismissing variant.

    * `:row` — a full-bleed rule inside the app shell (composer error, memory status)
    * `:notice` — a bordered box carrying prose (authentication error)
    * `:box` — a bordered box with a label column (flash notices)
  """
  attr :id, :string, default: nil
  attr :variant, :atom, values: [:info, :success, :warning, :danger], default: :info
  attr :appearance, :atom, values: [:box, :row, :notice], default: :box
  attr :label, :string, default: nil
  attr :class, :any, default: nil
  # Declared rather than left to `:global` so an explicit role replaces the
  # variant default instead of rendering the attribute twice.
  attr :role, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true
  slot :action

  def alert(assigns) do
    ~H"""
    <div
      id={@id}
      class={["alert", @class]}
      data-variant={@variant}
      data-appearance={@appearance != :box && @appearance}
      role={@role || alert_role(@variant)}
      {@rest}
    >
      <strong :if={@label} data-title>{@label}</strong>
      <section>{render_slot(@inner_block)}</section>
      <span :if={@action != []}>{render_slot(@action)}</span>
    </div>
    """
  end

  defp alert_role(:danger), do: "alert"
  defp alert_role(_variant), do: "status"

  @doc """
  A short typographic status label.

  Sarah states status as text; the badge carries the reserved semantic color
  and never stands in for the words.
  """
  attr :variant, :atom,
    values: [:default, :info, :success, :warning, :danger, :dim],
    default: :default

  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span class={["badge", @class]} data-variant={@variant != :default && @variant} {@rest}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  A softened content panel.

  Room around it, one hairline border, and a restrained lift. Still not a
  bubble and never a heavy floating box.

  (Careful with wording here. Tailwind scans this file for class candidates and
  harvests bare tokens out of prose, so naming a utility in a comment emits that
  utility into the shipped bundle. Describe geometry rather than naming a class.)
  """
  attr :id, :string, default: nil
  attr :variant, :atom, values: [:default, :danger], default: :default
  attr :frame, :atom, values: [:none, :corners], default: :none
  attr :state, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <article
      id={@id}
      class={["card", @class]}
      data-variant={@variant != :default && @variant}
      data-frame={@frame != :none && @frame}
      data-state={@state}
      {@rest}
    >
      {render_slot(@inner_block)}
    </article>
    """
  end

  @doc """
  An identity avatar.

  Takes a validated image URL or falls back to an initial. Avatars are the only
  circular geometry in the product.
  """
  attr :src, :string, default: nil
  attr :alt, :string, default: ""
  attr :size, :atom, values: [:default, :sm, :lg], default: :default
  attr :tone, :atom, values: [:default, :accent], default: :default
  attr :fallback, :string, default: nil
  attr :label, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  def avatar(assigns) do
    ~H"""
    <span
      class={["avatar", @class]}
      data-size={@size != :default && @size}
      data-tone={@tone != :default && @tone}
      role={@label && "img"}
      aria-label={@label}
      {@rest}
    >
      <img
        :if={@src}
        src={@src}
        alt={@alt}
        loading="lazy"
        decoding="async"
        referrerpolicy="no-referrer"
      />
      <span :if={!@src}>{@fallback}</span>
    </span>
    """
  end

  @doc """
  One row of bounded activity.

  Accepts only a public label, a lifecycle status, and an optional terminal
  executor disclosure. Tool activity in the transcript renders through
  `event_header/1` now; this stays the compact status-row primitive.
  """
  attr :id, :string, default: nil
  attr :status, :string, required: true
  attr :label, :string, required: true
  attr :detail, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  def item(assigns) do
    ~H"""
    <div id={@id} class={["item", @class]} data-status={@status} {@rest}>
      <.status_indicator state={@status} label={@label} decorative />
      <section>{@label}</section>
      <aside :if={@detail}>{@detail}</aside>
    </div>
    """
  end

  @doc """
  One durable event as a disclosure row.

  The collapsed row is a chevron disclosure button, a lit status dot, a quiet
  bounded one-line title saying what actually ran, an optional short status
  note in text (so color never carries the outcome alone), optional outcome
  chips, and a hover-revealed timestamp. The expansion slot carries the bounded
  durable details — arguments, result/error, executor identity and disclosure,
  timestamps.

  Expansion is pure client state: the button toggles `aria-expanded` on itself
  and `data-expanded` on the row, and the stylesheet shows the details region.
  A stream re-insert collapses the row again, which is the honest default.

  Accepts only the bounded, already-scrubbed durable projection that
  `INVARIANTS.md` UI-002 sanctions — never a provider identifier or private
  recall content.
  """
  attr :id, :string, required: true
  attr :status, :string, required: true
  attr :title, :string, required: true
  attr :title_attribute, :string, default: nil
  attr :status_note, :string, default: nil
  attr :timestamp, :any, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :chips
  slot :inner_block, required: true

  def event_header(assigns) do
    ~H"""
    <div id={@id} class={["event-header", @class]} data-status={@status} data-expanded="false" {@rest}>
      <button
        type="button"
        class="event-header__row"
        aria-expanded="false"
        aria-controls={"#{@id}-details"}
        phx-click={
          JS.toggle_attribute({"data-expanded", "true", "false"}, to: "##{@id}")
          |> JS.toggle_attribute({"aria-expanded", "true", "false"})
        }
      >
        <.icon name="chevron-right-md" class="event-header__chevron" />
        <.status_indicator state={@status} label={@status} decorative />
        <span class="event-header__title" title={@title_attribute || @title}>{@title}</span>
        <span :if={@status_note} class="event-header__note">{@status_note}</span>
        <span :if={@chips != []} class="event-header__chips">{render_slot(@chips)}</span>
        <time
          :if={@timestamp}
          class="event-header__time"
          datetime={DateTime.to_iso8601(@timestamp)}
        >
          {Calendar.strftime(@timestamp, "%H:%M")}
        </time>
      </button>
      <div id={"#{@id}-details"} class="event-header__details">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc "An empty state explaining what would appear here and how."
  attr :id, :string, default: nil
  attr :title, :string, required: true
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def empty(assigns) do
    ~H"""
    <div id={@id} class={["empty", @class]} {@rest}>
      <header>
        <h2>{@title}</h2>
        <p>{render_slot(@inner_block)}</p>
      </header>
    </div>
    """
  end

  @doc "A key name stated as text."
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def kbd(assigns) do
    ~H"""
    <kbd class={["kbd", @class]} {@rest}>{render_slot(@inner_block)}</kbd>
    """
  end

  @doc """
  A bounded disclosure anchored to a trigger.

  Uses the native `popover` API. Basecoat's JavaScript dropdown is deliberately
  not adopted: this control must work without custom client-side JavaScript.
  Render the matching trigger with `button/1` and
  `popovertarget={id} popovertargetaction="toggle"`.

  Carries Sarah's own `.menu` class rather than Basecoat's `.popover`. In
  Basecoat, `.popover` is the *anchor* (`position: relative`) and the floating
  panel is `[data-popover]`, positioned by its JavaScript. Putting `.popover` on
  the panel gave it author-origin `display: inline-flex`, which outranks the
  user agent's `[popover]:not(:popover-open) { display: none }` and leaves the
  menu permanently open and in flow. Sarah styles the native element directly.
  """
  attr :id, :string, required: true
  attr :label, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def menu(assigns) do
    ~H"""
    <div id={@id} class={["menu", @class]} popover="auto" role="menu" aria-label={@label} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  A decorative corner frame around a region.

  A port of Arwes' `corners` frame: eight strokes, two at each corner, at a
  fixed length that does not scale with the region. Arwes evaluates percentage
  expressions against a measured element and draws into an SVG; the same
  geometry is eight background gradients here, which needs no measurement and
  no JavaScript.

  Decorative only. It carries no state and no meaning, so it is hidden from
  assistive technology by the fact that it renders nothing readable.
  """
  attr :variant, :atom, values: [:corners], default: :corners
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def frame(assigns) do
    ~H"""
    <div class={["frame", @class]} data-variant={@variant} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  A lit semantic state marker.

  `DESIGN.md`: color reinforces state but never replaces the words, so a label
  is required. Pass `decorative` when an adjacent element already states the
  same label in text, which hides the marker from assistive technology instead
  of announcing it twice.
  """
  attr :state, :string, required: true
  attr :label, :string, required: true
  attr :decorative, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global

  def status_indicator(assigns) do
    ~H"""
    <span
      class={["status-indicator", @class]}
      data-state={@state}
      role={!@decorative && "img"}
      aria-label={!@decorative && @label}
      aria-hidden={@decorative && "true"}
      {@rest}
    />
    """
  end

  @doc """
  A native audio player for one stored recording.

  Basecoat has no audio component and Sarah does not ship a custom transport, so
  this wraps the browser's own `<audio controls>` rather than rebuilding play,
  pause, and volume in JavaScript. Native controls are already keyboard operable
  and already announced, which a hand-rolled transport would have to re-earn.

  `label` is required because a page of recordings is a page of near-identical
  players; without a name, every one of them announces as "audio". `preload` is
  metadata-only so opening the panel does not pull megabytes of audio for calls
  the operator never plays.
  """
  attr :id, :string, default: nil
  attr :src, :string, required: true
  attr :label, :string, required: true
  attr :class, :any, default: nil
  attr :rest, :global

  def audio_player(assigns) do
    ~H"""
    <audio
      id={@id}
      class={["audio-player", @class]}
      src={@src}
      controls
      preload="metadata"
      aria-label={@label}
      {@rest}
    />
    """
  end

  @doc """
  One glyph from the vendored Apps SDK UI set.

  Renders inline SVG at `1em` in `currentColor`, so a glyph takes the size and
  color of the text around it. Icons come only from `priv/icons`; adding one is
  a re-vendor, never inline SVG in a surface. See `docs/ICONS.md`.

  Decorative by default. Most glyphs sit beside a word that already names the
  control, and announcing both is noise, so an icon with no `label` is hidden
  from assistive technology.

  When a control is icon-only, the accessible name belongs on the control, not
  on the glyph:

      <.button aria-label="Send"><.icon name="arrow-up" /></.button>

  Pass `label` only when the glyph itself is the whole message and nothing
  adjacent says it.
  """
  attr :name, :string, required: true
  attr :label, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  def icon(assigns) do
    {view_box, inner} = OpenAgentsWeb.Icons.fetch!(assigns.name)

    assigns = assign(assigns, view_box: view_box, inner: inner)

    ~H"""
    <svg
      class={["icon", @class]}
      viewBox={@view_box}
      width="1em"
      height="1em"
      fill="currentColor"
      role={@label && "img"}
      aria-label={@label}
      aria-hidden={is_nil(@label) && "true"}
      focusable="false"
      {@rest}
    >{Phoenix.HTML.raw(@inner)}</svg>
    """
  end
end
