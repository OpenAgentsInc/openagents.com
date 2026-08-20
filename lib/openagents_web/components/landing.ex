defmodule OpenAgentsWeb.UI.Landing do
  @moduledoc """
  Marketing-page composition: the pieces a landing page is built from.

  Adapted from Launch UI (MIT, © 2024 Mikolaj Dobrucki), which is a React and
  Tailwind component set. Nothing is copied: the source expresses each piece as
  a `cva` variant map over utility classes with `class-variance-authority` and
  Radix primitives, and none of that survives the move to HEEx. What carried
  over is the composition — what a hero contains, how a feature grid divides,
  where a glow sits relative to the content it lifts — and the visual decisions
  behind it. See `docs/2026-08-20-launch-ui-adaptation.md`.

  Two departures from the source are deliberate:

    * **Tokens, not a second palette.** Launch UI paints with `brand`,
      `brand-foreground` and layered `glass-*` gradients. Those would introduce
      a second colour system beside the one the application already uses, and a
      landing page that does not look like the product it advertises is worse
      than a plainer one that does. Every value here resolves to an existing
      token.

    * **No JavaScript.** The accordion is `<details>` rather than a Radix
      disclosure, and the mobile navigation is a native popover. Marketing
      pages are the first thing a visitor loads and the most likely to be read
      on a slow connection, so nothing here should wait on a bundle.

  Motion is opt-in and respects `prefers-reduced-motion`; the appear animations
  are decorative, and the page is complete without them.
  """

  use Phoenix.Component

  alias OpenAgentsWeb.UI

  @doc """
  A page band: horizontal padding, generous vertical rhythm, a closing rule.

  Landing sections are separated by a hairline rather than by colour, so the
  page reads as one surface divided into parts rather than as a stack of
  differently coloured panels.
  """
  attr :class, :any, default: nil
  attr :rule, :boolean, default: true, doc: "draw the closing hairline"
  attr :rest, :global
  slot :inner_block, required: true

  def section(assigns) do
    ~H"""
    <section class={["landing-section", !@rule && "landing-section--flush", @class]} {@rest}>
      <div class="landing-section__inner">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  @doc """
  A soft radial lift behind content.

  Two stacked ellipses rather than one: a wide faint wash and a narrower,
  denser core. A single gradient reads as a flat smudge, and the pair is what
  makes it look like light rather than paint. Decorative, so it is hidden from
  assistive technology and never carries meaning.
  """
  attr :variant, :atom, values: [:top, :above, :bottom, :below, :center], default: :top
  attr :class, :any, default: nil
  attr :rest, :global

  def glow(assigns) do
    ~H"""
    <div class={["glow", "glow--#{@variant}", @class]} aria-hidden="true" {@rest}>
      <span class="glow__wash"></span>
      <span class="glow__core"></span>
    </div>
    """
  end

  @doc """
  A radial bloom drawn behind whatever it wraps.

  Where `glow/1` is a band positioned against a section, this attaches to one
  element and blooms from it, for lighting a single figure rather than a whole
  region.
  """
  attr :tone, :atom, values: [:default, :bright], default: :default
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def beam(assigns) do
    ~H"""
    <div class={["beam", "beam--#{@tone}", @class]} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  A framed screenshot.

  The frame is a second, wider border in a lighter fill, which is what reads as
  a device edge without drawing a literal laptop. `type` picks the corner
  radius: a phone's is large enough to change the shape, a window's is not.
  """
  attr :type, :atom, values: [:window, :phone], default: :window
  attr :size, :atom, values: [:small, :large], default: :small
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def mockup(assigns) do
    ~H"""
    <div class={["mockup-frame", "mockup-frame--#{@size}", @class]} {@rest}>
      <div class={["mockup", "mockup--#{@type}"]}>{render_slot(@inner_block)}</div>
    </div>
    """
  end

  @doc """
  The opening band: an optional eyebrow, a headline, a line of prose, actions,
  and an optional framed figure lifted by a glow.

  The figure is a slot rather than an image attribute, so a page can put a live
  surface in the frame instead of a screenshot of one.
  """
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :class, :any, default: nil
  slot :eyebrow
  slot :actions
  slot :figure

  def hero(assigns) do
    ~H"""
    <.section class={["hero", @class]} rule={false}>
      <div class="hero__lede">
        <div :if={@eyebrow != []} class="hero__eyebrow appear">{render_slot(@eyebrow)}</div>
        <h1 class="hero__title appear">{@title}</h1>
        <p :if={@description} class="hero__description appear appear--delay-1">
          {@description}
        </p>
        <div :if={@actions != []} class="hero__actions appear appear--delay-2">
          {render_slot(@actions)}
        </div>
      </div>

      <div :if={@figure != []} class="hero__figure">
        <.glow variant={:top} class="appear-zoom appear--delay-4" />
        <div class="hero__figure-inner appear appear--delay-3">{render_slot(@figure)}</div>
      </div>
    </.section>
    """
  end

  @doc """
  A grid of short capability statements.

  Four columns on a wide screen, two on a narrow one, and each cell is an icon
  and a title on one line above a sentence. The cells carry no borders or fills
  — a grid of boxes competes with itself for attention, and the alignment is
  already doing the work of separating them.
  """
  attr :title, :string, default: nil
  attr :class, :any, default: nil

  slot :item, doc: "one capability" do
    attr :title, :string, required: true
    attr :icon, :string
  end

  def feature_grid(assigns) do
    ~H"""
    <.section class={["features", @class]}>
      <h2 :if={@title} class="landing-heading">{@title}</h2>
      <div class="feature-grid">
        <article :for={item <- @item} class="feature">
          <h3 class="feature__title">
            <UI.icon :if={item[:icon]} name={item.icon} class="feature__icon" />
            {item.title}
          </h3>
          <p class="feature__description">{render_slot(item)}</p>
        </article>
      </div>
    </.section>
    """
  end

  @doc """
  A row of figures.

  The number is the largest thing in the cell and the words around it are
  small, because a statistic that has to be read to be understood is not doing
  the job a statistic is for. A `suffix` stays a separate element so `24` and
  `k` can be sized differently without splitting the value in the caller.
  """
  attr :class, :any, default: nil

  slot :stat, doc: "one figure" do
    attr :label, :string
    attr :value, :string, required: true
    attr :suffix, :string
  end

  def stats(assigns) do
    ~H"""
    <.section class={["stats", @class]}>
      <div class="stat-row">
        <div :for={stat <- @stat} class="stat">
          <p :if={stat[:label]} class="stat__label">{stat.label}</p>
          <p class="stat__value">
            {stat.value}<span :if={stat[:suffix]} class="stat__suffix">{stat.suffix}</span>
          </p>
          <p class="stat__description">{render_slot(stat)}</p>
        </div>
      </div>
    </.section>
    """
  end

  @doc """
  One column of a pricing table.

  `featured` raises a column above its neighbours with a brighter top rule and
  a lift. The price is a slot rather than a number so a caller can write "Free",
  "Usage-based", or a struck-through original beside a current one without this
  component having an opinion about currency.
  """
  attr :name, :string, required: true
  attr :description, :string, default: nil
  attr :price, :string, required: true
  attr :price_note, :string, default: nil
  attr :featured, :boolean, default: false
  attr :class, :any, default: nil
  slot :action
  slot :feature, doc: "one included capability"

  def pricing_column(assigns) do
    ~H"""
    <div class={["pricing-column", @featured && "pricing-column--featured", @class]}>
      <hr class="pricing-column__rule" />
      <header class="pricing-column__header">
        <h3 class="pricing-column__name">{@name}</h3>
        <p :if={@description} class="pricing-column__description">{@description}</p>
      </header>

      <p class="pricing-column__price">
        {@price}<span :if={@price_note} class="pricing-column__note">{@price_note}</span>
      </p>

      <div :if={@action != []} class="pricing-column__action">{render_slot(@action)}</div>

      <ul :if={@feature != []} class="pricing-column__features">
        <li :for={feature <- @feature}>
          <UI.icon name="check-circle" /> {render_slot(feature)}
        </li>
      </ul>
    </div>
    """
  end

  @doc """
  Questions and answers on native `<details>`.

  No JavaScript and no ARIA to keep in sync: the disclosure state lives in the
  element, so it works before any bundle has loaded and keyboard behaviour is
  the browser's. The caret rotates rather than swapping glyphs.
  """
  attr :title, :string, default: nil
  attr :class, :any, default: nil

  slot :item, doc: "one question" do
    attr :question, :string, required: true
    attr :open, :boolean
  end

  def faq(assigns) do
    ~H"""
    <.section class={["faq", @class]}>
      <h2 :if={@title} class="landing-heading">{@title}</h2>
      <div class="faq-list">
        <details :for={item <- @item} class="faq-item" open={item[:open] || false}>
          <summary class="faq-item__question">
            {item.question}
            <UI.icon name="chevron-right" class="faq-item__caret" />
          </summary>
          <div class="faq-item__answer">{render_slot(item)}</div>
        </details>
      </div>
    </.section>
    """
  end

  @doc """
  The closing ask.

  A glow sits under this one rather than behind it, and rises slightly on
  hover: the section is the last thing on the page, so the light reads as
  something below the fold rather than something behind the text.
  """
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :class, :any, default: nil
  slot :actions

  def cta(assigns) do
    ~H"""
    <.section class={["cta", @class]}>
      <h2 class="landing-heading cta__title">{@title}</h2>
      <p :if={@description} class="cta__description">{@description}</p>
      <div :if={@actions != []} class="cta__actions">{render_slot(@actions)}</div>
      <.glow variant={:below} class="cta__glow" />
    </.section>
    """
  end

  @doc """
  A row of names, for the "used by" band.

  Rendered at a single muted weight regardless of what each logo is, so one
  contributor's heavier mark does not dominate the row.
  """
  attr :title, :string, default: nil
  attr :class, :any, default: nil
  slot :logo, doc: "one name or mark"

  def logo_wall(assigns) do
    ~H"""
    <.section class={["logos", @class]}>
      <p :if={@title} class="logos__title">{@title}</p>
      <div class="logo-wall">
        <div :for={logo <- @logo} class="logo-wall__item">{render_slot(logo)}</div>
      </div>
    </.section>
    """
  end

  @doc """
  The page footer: a mark, a line about it, and columns of links.
  """
  attr :name, :string, default: "OpenAgents"
  attr :tagline, :string, default: nil
  attr :note, :string, default: nil
  attr :class, :any, default: nil

  slot :column, doc: "one column of links" do
    attr :title, :string, required: true
  end

  def landing_footer(assigns) do
    ~H"""
    <footer class={["landing-footer", @class]}>
      <div class="landing-footer__inner">
        <div class="landing-footer__identity">
          <p class="landing-footer__name">{@name}</p>
          <p :if={@tagline} class="landing-footer__tagline">{@tagline}</p>
        </div>

        <nav :for={column <- @column} class="landing-footer__column" aria-label={column.title}>
          <p class="landing-footer__column-title">{column.title}</p>
          {render_slot(column)}
        </nav>
      </div>
      <p :if={@note} class="landing-footer__note">{@note}</p>
    </footer>
    """
  end

  @doc """
  Faint vertical rules marking the content column's edges.

  Fixed behind the page and pointer-transparent. Purely decorative: it gives a
  long marketing page a spine to read against, and removing it changes nothing
  about the content.
  """
  attr :class, :any, default: nil

  def layout_lines(assigns) do
    ~H"""
    <div class={["layout-lines", @class]} aria-hidden="true">
      <div class="layout-lines__column"></div>
    </div>
    """
  end
end
