defmodule OpenAgentsWeb.UI do
  @moduledoc """
  OpenAgents interface primitives.

  Every component here wraps a vendored Basecoat class and exposes OpenAgents
  vocabulary rather than Basecoat's. Product surfaces build interface only from
  these components; they do not author component-level CSS classes. See
  `assets/css/openagents.css` and
  `docs/decisions/0005-use-basecoat-and-one-component-system.md`.

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

  `:link` renders OpenAgents inline underlined action rather than a boxed button
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
    include:
      ~w(disabled form name value popovertarget popovertargetaction download href navigate patch rel target)

  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <.link
      :if={@rest[:href] || @rest[:navigate] || @rest[:patch]}
      class={["btn", @class]}
      data-variant={@variant}
      data-size={@size != :default && @size}
      data-tone={@tone != :default && @tone}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    <button
      :if={!(@rest[:href] || @rest[:navigate] || @rest[:patch])}
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

  @doc "A form-aware input or an unwrapped single-line text control."
  attr :id, :any, default: nil
  attr :name, :any, default: nil
  attr :label, :string, default: nil
  attr :value, :any, default: nil

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    default: nil,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, default: nil
  attr :prompt, :string, default: nil
  attr :options, :list, default: []
  attr :multiple, :boolean, default: false
  attr :class, :any, default: nil
  attr :error_class, :any, default: nil

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error/1))
    |> assign(
      :name,
      assigns.name || if(assigns.multiple, do: field.name <> "[]", else: field.name)
    )
    |> assign(:value, if(is_nil(assigns.value), do: field.value, else: assigns.value))
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <.field class="mb-2">
      <input
        type="hidden"
        name={@name}
        value="false"
        disabled={@rest[:disabled]}
        form={@rest[:form]}
      />
      <.label for={@id} class="inline-flex items-center gap-2">
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class={@class || "size-4 shrink-0 accent-primary"}
          {@rest}
        />
        {@label}
      </.label>
      <.error :for={message <- @errors}>{message}</.error>
    </.field>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <.field class="mb-2">
      <.label :if={@label} for={@id}>{@label}</.label>
      <select
        id={@id}
        name={@name}
        class={[@class || "input w-full", "aria-invalid:border-destructive", @error_class]}
        aria-invalid={@errors != [] && "true"}
        multiple={@multiple}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <.error :for={message <- @errors}>{message}</.error>
    </.field>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <.field class="mb-2">
      <.label :if={@label} for={@id}>{@label}</.label>
      <.textarea
        id={@id}
        name={@name}
        value={Phoenix.HTML.Form.normalize_value("textarea", @value)}
        class={[@class || "w-full", "aria-invalid:border-destructive", @error_class]}
        aria-invalid={@errors != [] && "true"}
        {@rest}
      />
      <.error :for={message <- @errors}>{message}</.error>
    </.field>
    """
  end

  def input(%{label: nil, errors: []} = assigns) do
    ~H"""
    <input
      type={@type}
      id={@id}
      name={@name}
      value={Phoenix.HTML.Form.normalize_value(@type, @value)}
      class={["input", @class]}
      {@rest}
    />
    """
  end

  def input(assigns) do
    ~H"""
    <.field class="mb-2">
      <.label :if={@label} for={@id}>{@label}</.label>
      <input
        type={@type}
        id={@id}
        name={@name}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[@class || "input w-full", "aria-invalid:border-destructive", @error_class]}
        aria-invalid={@errors != [] && "true"}
        {@rest}
      />
      <.error :for={message <- @errors}>{message}</.error>
    </.field>
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

  @doc "A page heading with optional supporting text and actions."
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">{render_slot(@inner_block)}</h1>
        <p :if={@subtitle != []} class="text-sm text-muted-foreground">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc "A responsive table for regular lists or LiveView streams."
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil
  attr :row_item, :any, default: &Function.identity/1

  slot :col, required: true do
    attr :label, :string
  end

  slot :action

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="table-container">
      <table class="table text-sm">
        <thead>
          <tr>
            <th :for={column <- @col} class="px-3 py-2 text-left text-muted-foreground">
              {column[:label]}
            </th>
            <th :if={@action != []} class="px-3 py-2"><span class="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
          <tr :for={row <- @rows} id={@row_id && @row_id.(row)} class="hover:bg-muted/40">
            <%!-- No row-level click. A `phx-click` on a `td` is not reachable
            by keyboard and announces nothing, so a table built that way is
            usable only with a mouse. Put a real control in a cell instead. --%>
            <td :for={column <- @col} class="px-3 py-2">
              {render_slot(column, @row_item.(row))}
            </td>
            <td :if={@action != []} class="w-0 px-3 py-2 font-semibold">
              <div class="flex gap-4">
                <%= for action <- @action do %>
                  {render_slot(action, @row_item.(row))}
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc "A title and description list."
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="divide-y divide-border">
      <li :for={item <- @item} class="flex items-start gap-4 py-3">
        <div class="min-w-0 grow">
          <div class="font-semibold">{item.title}</div>
          <div class="text-muted-foreground">{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex items-center gap-2 text-sm text-destructive">
      <.icon name="warning" class="size-5" />
      {render_slot(@inner_block)}
    </p>
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

  OpenAgents states status as text; the badge carries the reserved semantic color
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

  Carries OpenAgents own `.menu` class rather than Basecoat's `.popover`. In
  Basecoat, `.popover` is the *anchor* (`position: relative`) and the floating
  panel is `[data-popover]`, positioned by its JavaScript. Putting `.popover` on
  the panel gave it author-origin `display: inline-flex`, which outranks the
  user agent's `[popover]:not(:popover-open) { display: none }` and leaves the
  menu permanently open and in flow. OpenAgents styles the native element directly.
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

  Basecoat has no audio component and OpenAgents does not ship a custom transport, so
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
  A trail of ancestor links ending in the current page.

  The last item is the current page: it renders as `aria-current="page"` and is
  not a link, because linking a page to itself is a dead control that still
  looks live. Separators carry `aria-hidden` so assistive technology reads the
  trail as a list of places rather than a stream of glyphs.
  """
  attr :class, :any, default: nil
  attr :label, :string, default: "Breadcrumb"
  attr :rest, :global

  slot :item, required: true do
    attr :navigate, :string
    attr :patch, :string
    attr :href, :string
  end

  def breadcrumb(assigns) do
    assigns = assign(assigns, :last_index, length(assigns.item) - 1)

    ~H"""
    <nav class={["breadcrumb", @class]} aria-label={@label} {@rest}>
      <ol>
        <li :for={{item, index} <- Enum.with_index(@item)}>
          <span :if={index > 0} class="breadcrumb__separator" aria-hidden="true">/</span>
          <.link
            :if={index < @last_index}
            navigate={item[:navigate]}
            patch={item[:patch]}
            href={item[:href]}
            class="breadcrumb__link"
          >
            {render_slot(item)}
          </.link>
          <span :if={index == @last_index} aria-current="page" class="breadcrumb__current">
            {render_slot(item)}
          </span>
        </li>
      </ol>
    </nav>
    """
  end

  @doc """
  The GitHub sign-in control.

  A real form POST, not a link: signing in starts an OAuth round-trip, and a
  control labelled "log in" that navigates somewhere else instead is lying
  about what it does.

  The round-trip leaves the page, so there is a window where the button looks
  idle and clickable while a redirect is already in flight. Submitting swaps
  the mark for a spinner and disables the control, which both reports that
  something is happening and stops a second submission creating a second OAuth
  attempt.

  The pending state is applied by a hook, but it is also expressed for
  `:disabled` alone, so a browser that re-enables the button on back-navigation
  or runs no script still shows the right thing.
  """
  attr :id, :string, required: true
  attr :label, :string, default: "Log in with GitHub"
  attr :variant, :atom, default: :primary
  attr :size, :atom, default: :md

  attr :action, :string,
    default: "/auth/github?github_tools=enabled",
    doc: "where the sign-in posts; the caller owns the route"

  attr :class, :any, default: nil
  attr :rest, :global

  def github_login(assigns) do
    ~H"""
    <.form
      for={%{}}
      as={:auth}
      id={"#{@id}-form"}
      action={@action}
      method="post"
      class="login-form"
      phx-hook=".LoginPending"
      {@rest}
    >
      <.button id={@id} type="submit" variant={@variant} size={@size} class={["login-button", @class]}>
        <.icon name="brand-github" class="login-button__mark" />
        <.icon name="circle-dashed" class="login-button__spinner" />
        {@label}
      </.button>
    </.form>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".LoginPending">
      export default {
        mounted() {
          this.button = this.el.querySelector("button[type=submit]")
          this.onSubmit = () => {
            if (!this.button) return
            this.button.dataset.pending = "true"
            // Disabled after the event, not during it: disabling a submit
            // button inside its own submit handler cancels the submission in
            // some browsers.
            window.setTimeout(() => { this.button.disabled = true }, 0)
          }
          this.el.addEventListener("submit", this.onSubmit)
        },
        destroyed() {
          this.el.removeEventListener("submit", this.onSubmit)
        },
      }
    </script>
    """
  end

  @doc """
  A control that copies text to the clipboard and reports that it did.

  The confirmation is the point. A copy button that changes nothing on click
  leaves the reader unsure whether it worked, so this flips `data-copied` and
  swaps the glyph for a tick, then returns. The state lives on the element
  rather than in the LiveView because it is presentational and per-visitor.
  """
  attr :id, :string, required: true
  attr :text, :string, required: true, doc: "the text placed on the clipboard"
  attr :label, :string, default: "Copy"
  attr :copied_label, :string, default: "Copied"
  attr :class, :any, default: nil
  attr :rest, :global

  def copy_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      class={["btn copy-button", @class]}
      data-variant="secondary"
      data-size="sm"
      data-copied="false"
      data-copy-text={@text}
      data-copied-label={@copied_label}
      aria-label={@label}
      phx-hook=".CopyToClipboard"
      {@rest}
    >
      <.icon name="copy" class="copy-button__idle" />
      <.icon name="check" class="copy-button__done" />
      <span class="copy-button__label">{@label}</span>
    </button>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyToClipboard">
      export default {
        mounted() {
          this.el.addEventListener("click", async () => {
            try {
              await navigator.clipboard.writeText(this.el.dataset.copyText)
            } catch (_error) {
              return
            }
            const label = this.el.querySelector(".copy-button__label")
            const original = label && label.textContent
            this.el.dataset.copied = "true"
            if (label) label.textContent = this.el.dataset.copiedLabel
            clearTimeout(this.resetTimer)
            this.resetTimer = setTimeout(() => {
              this.el.dataset.copied = "false"
              if (label) label.textContent = original
            }, 1600)
          })
        },
        destroyed() {
          clearTimeout(this.resetTimer)
        }
      }
    </script>
    """
  end

  @doc """
  One glyph from the governed two-tier icon set.

  Renders inline SVG at `1em` in `currentColor`, so a glyph takes the size and
  color of the text around it. Apps SDK UI glyphs come from `priv/icons`.
  `hero-*` names are the documented fallback when that set has no suitable
  concept. Adding a preferred glyph is a re-vendor, never inline SVG in a
  surface. See `docs/ICONS.md`.

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

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span
      class={[@name, "icon", @class]}
      role={@label && "img"}
      aria-label={@label}
      aria-hidden={is_nil(@label) && "true"}
      data-icon={@name}
      {@rest}
    />
    """
  end

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
      data-icon={@name}
      {@rest}
    >{Phoenix.HTML.raw(@inner)}</svg>
    """
  end

  defp translate_error({message, options}) do
    if count = options[:count] do
      Gettext.dngettext(OpenAgentsWeb.Gettext, "errors", message, message, count, options)
    else
      Gettext.dgettext(OpenAgentsWeb.Gettext, "errors", message, options)
    end
  end
end
