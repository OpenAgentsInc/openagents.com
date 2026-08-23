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
    values: [:default, :info, :success, :warning, :danger, :done, :dim],
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
  The section bar under a repository's name: Code, Issues, Pull requests, and
  whatever else that repository publishes.

  Page navigation rather than a tab widget. Every entry changes the URL, so the
  selected one carries `aria-current="page"` and none of them carries a tab
  role -- a tab role promises panels that swap in place, and a reader who takes
  that promise and reaches for the arrow keys gets nothing.

  A count lives in its own element rather than inside the label, so "Issues"
  stays findable by that word alone and the number can be toned down, or
  dropped at a narrow width, without rewriting the string.
  """
  attr :label, :string, default: "Repository sections"
  attr :class, :any, default: nil
  attr :rest, :global

  slot :tab, required: true do
    attr :icon, :string
    attr :count, :integer
    attr :current, :boolean
    attr :navigate, :string
    attr :patch, :string
    attr :href, :string
  end

  def repo_tabs(assigns) do
    ~H"""
    <nav class={["repo-tabs", @class]} aria-label={@label} {@rest}>
      <.link
        :for={tab <- @tab}
        navigate={tab[:navigate]}
        patch={tab[:patch]}
        href={tab[:href]}
        aria-current={tab[:current] && "page"}
        class="repo-tabs__tab"
      >
        <.icon :if={tab[:icon]} name={tab.icon} />
        <span class="repo-tabs__label">{render_slot(tab)}</span>
        <span :if={tab[:count]} class="repo-tabs__count">{tab.count}</span>
      </.link>
    </nav>
    """
  end

  @doc """
  The map of one pull request stack: every layer in order, top of the stack
  first, ending at the trunk the whole stack targets.

  Layers arrive top-first because that is how a stack reads — the newest work
  sits on top and the trunk anchors the bottom, the way the branches actually
  chain. Each layer carries its pull request state as a glyph beside the
  title, so a reader sees at a glance which layers are merged, open, draft,
  or closed.

  The layer for the page the reader is on renders as text with
  `aria-current="page"` rather than as a link, for the same reason
  `breadcrumb/1` does: a page linking to itself is a dead control that still
  looks live. Every other layer is a link to its pull request.

  The trunk row is a destination too when `trunk_navigate` or `trunk_href` is
  given — the branch the stack lands on is a real place — and plain text when
  it is not, as in the catalog where there is nowhere to send the reader.
  """
  attr :id, :string, required: true
  attr :number, :integer, required: true, doc: "the stack number, scoped to the repository"
  attr :trunk, :string, required: true, doc: "the branch the whole stack targets"
  attr :trunk_navigate, :string, default: nil
  attr :trunk_href, :string, default: nil
  attr :add_navigate, :string, default: nil, doc: "where a new layer on top of the stack begins"
  attr :add_href, :string, default: nil
  attr :class, :any, default: nil

  attr :layers, :list,
    required: true,
    doc:
      "`[%{title, number, branch, state}]` from top of the stack to bottom, " <>
        "each optionally carrying `navigate` or `href` for its destination and " <>
        "`current: true` for the layer being viewed; `state` is `open`, " <>
        "`merged`, `closed`, or `draft`"

  attr :rest, :global

  slot :action, doc: "controls at the trailing edge of the header, such as unstack"

  def stack_map(assigns) do
    ~H"""
    <section id={@id} class={["stack-map", @class]} aria-label={"Stack ##{@number}"} {@rest}>
      <header class="stack-map__header">
        <span class="stack-map__title">Stack #{@number}</span>
        <span class="stack-map__count">{layer_count_label(length(@layers))}</span>
        <span :if={@action != []} class="stack-map__actions">{render_slot(@action)}</span>
      </header>
      <ol class="stack-map__layers">
        <li :if={@add_navigate || @add_href} class="stack-map__add">
          <.link navigate={@add_navigate} href={@add_href} class="stack-map__add-link">
            <.icon name="plus" class="stack-map__add-icon" /> Add to stack
          </.link>
        </li>
        <li
          :for={layer <- @layers}
          class="stack-map__layer"
          data-state={layer.state}
          aria-current={layer[:current] && "page"}
        >
          <.icon name={pull_request_state_icon(layer.state)} class="stack-map__state" />
          <.link
            :if={!layer[:current]}
            navigate={layer[:navigate]}
            href={layer[:href]}
            class="stack-map__layer-link"
          >
            {layer.title}
          </.link>
          <span :if={layer[:current]} class="stack-map__layer-link">{layer.title}</span>
          <span class="stack-map__layer-meta">
            <span class="stack-map__layer-number">#{layer.number}</span>
            <span class="stack-map__branch">{layer.branch}</span>
          </span>
        </li>
        <li class="stack-map__trunk">
          <.icon name="branch" class="stack-map__state" />
          <.link
            :if={@trunk_navigate || @trunk_href}
            navigate={@trunk_navigate}
            href={@trunk_href}
            class="stack-map__branch"
          >
            {@trunk}
          </.link>
          <span :if={!(@trunk_navigate || @trunk_href)} class="stack-map__branch">{@trunk}</span>
        </li>
      </ol>
    </section>
    """
  end

  defp layer_count_label(1), do: "1 layer"
  defp layer_count_label(count), do: "#{count} layers"

  defp pull_request_state_icon("merged"), do: "pull-request-merged"
  defp pull_request_state_icon("closed"), do: "pull-request-closed"
  defp pull_request_state_icon("draft"), do: "pull-request-draft"
  defp pull_request_state_icon(_open), do: "pull-request-open"

  @doc """
  A repository's file table: the ref bar, the latest commit, and the entries.

  Adapted from the GitHub-shaped clones catalogued in
  `docs/audits/2026-08-19-github-clone-harvest-candidates.md` -- `gh-next`
  (MIT, Fredkiss3/gh-next) for the Tailwind repo home's header and rail, and
  Gitea's `view_list.tmpl` for what a tree row must actually carry.

  Directories sort above files, which is what `Browse.tree/3` already returns
  and what makes a deep repository scannable: a reader looks for the folder
  first and only then for the file.

  The latest-commit bar sits above the table rather than inside it. It
  describes the tree as a whole, and a row that describes the whole table but
  looks like a row is the reason GitHub's own version of this reads oddly on
  first sight.

  Per-row commit messages are optional, because GitHub fills them by walking
  history once per path, which is one process per file. An entry that carries
  `message` and `updated` gets them; when no entry does, those two columns are
  not rendered at all rather than emitted empty, so the cheap tree keeps the
  markup it already had.
  """
  attr :owner, :string, required: true
  attr :repo, :string, required: true
  attr :ref, :string, required: true
  attr :path, :string, default: ""

  attr :entries, :list,
    required: true,
    doc:
      "`[%{name, kind, size}]` from `Browse.tree/3`, each optionally carrying " <>
        "`message` and `updated` from that path's last commit"

  attr :branches, :integer, default: nil
  attr :tags, :integer, default: nil
  attr :commits, :integer, default: nil, doc: "commits on this ref, shown beside the latest one"
  attr :class, :any, default: nil
  slot :commit, doc: "the latest commit, shown above the table"
  slot :actions, doc: "controls at the trailing edge of the ref bar"

  def file_table(assigns) do
    assigns =
      assign(assigns, :history?, Enum.any?(assigns.entries, &(&1[:message] || &1[:updated])))

    ~H"""
    <div class={["file-table", @class]}>
      <div class="file-table__bar">
        <span class="file-table__ref">
          <.icon name="branch" /> {@ref}
        </span>
        <span :if={@branches} class="file-table__count">
          <strong>{@branches}</strong> {plural(@branches, "Branch", "Branches")}
        </span>
        <span :if={@tags} class="file-table__count">
          <strong>{@tags}</strong> {plural(@tags, "Tag", "Tags")}
        </span>
        <span :if={@actions != []} class="file-table__actions">{render_slot(@actions)}</span>
      </div>

      <div :if={@commit != [] or @commits} class="file-table__commit">
        {render_slot(@commit)}
        <span :if={@commits} class="file-table__commits">
          <.icon name="history" />
          <strong>{@commits}</strong> {plural(@commits, "Commit", "Commits")}
        </span>
      </div>

      <table class="file-table__list">
        <caption class="visually-hidden">
          Files in {(@path == "" && "the repository root") || @path}
        </caption>
        <tbody>
          <tr :for={entry <- @entries} class="file-row" data-kind={entry.kind}>
            <td class="file-row__name">
              <.link navigate={entry_path(@owner, @repo, @ref, @path, entry)} class="file-row__link">
                <.icon name={if entry.kind == "tree", do: "folder", else: "file-document"} />
                {entry.name}
              </.link>
            </td>
            <td :if={@history?} class="file-row__message" title={entry[:message]}>
              {entry[:message]}
            </td>
            <td class="file-row__size">{size_label(entry)}</td>
            <td :if={@history?} class="file-row__age">{entry[:updated]}</td>
          </tr>
        </tbody>
      </table>

      <p :if={@entries == []} class="file-table__empty">Nothing at this path.</p>
    </div>
    """
  end

  # A directory goes to `tree`, a file to `blob`. GitHub's grammar, which the
  # harvest audit treats as the compatibility target rather than a style
  # choice: an existing link, bookmark, or `gh`-shaped tool should keep working.
  defp entry_path(owner, repo, ref, path, %{kind: kind, name: name}) do
    noun = if kind == "tree", do: "tree", else: "blob"
    joined = if path == "", do: name, else: path <> "/" <> name
    "/#{owner}/#{repo}/#{noun}/#{ref}/#{joined}"
  end

  # `UI` is not a gettext backend, and these two words are the only plurals it
  # needs.
  defp plural(1, singular, _plural), do: singular
  defp plural(_count, _singular, plural), do: plural

  defp size_label(%{kind: "tree"}), do: nil
  defp size_label(%{size: nil}), do: nil

  defp size_label(%{size: bytes}) when is_integer(bytes) do
    cond do
      bytes < 1_024 -> "#{bytes} B"
      bytes < 1_048_576 -> "#{Float.round(bytes / 1_024, 1)} KB"
      true -> "#{Float.round(bytes / 1_048_576, 1)} MB"
    end
  end

  defp size_label(_entry), do: nil

  @doc """
  The rail beside a repository: what it is, how it is licensed, what it is made of.

  Adapted from `gh-next`'s repo home. Every row is optional, and an absent one
  renders nothing rather than a placeholder -- a rail that says "no description"
  is louder than one that simply does not mention it.
  """
  attr :description, :string, default: nil
  attr :license, :string, default: nil

  attr :contributors, :integer,
    default: nil,
    doc: "the total, when more people committed than there are faces to show"

  attr :class, :any, default: nil

  slot :link, doc: "one related destination" do
    attr :icon, :string
    attr :navigate, :string
    attr :href, :string
  end

  slot :stat, doc: "one count" do
    attr :icon, :string
  end

  slot :contributor, doc: "one contributor, drawn as a face" do
    attr :name, :string, required: true
    attr :src, :string
  end

  slot :language, doc: "one language" do
    attr :percent, :float, required: true
  end

  def repo_about(assigns) do
    assigns =
      assign(
        assigns,
        :overflow,
        max((assigns.contributors || 0) - length(assigns.contributor), 0)
      )

    ~H"""
    <aside class={["repo-about", @class]} aria-label="About this repository">
      <h2 class="repo-about__title">About</h2>
      <p :if={@description} class="repo-about__description">{@description}</p>

      <ul :if={@link != [] or @license} class="repo-about__links">
        <li :if={@license}>
          <.icon name="scales" /> {@license}
        </li>
        <li :for={link <- @link}>
          <.link navigate={link[:navigate]} href={link[:href]}>
            <.icon :if={link[:icon]} name={link.icon} /> {render_slot(link)}
          </.link>
        </li>
      </ul>

      <ul :if={@stat != []} class="repo-about__stats">
        <li :for={stat <- @stat}>
          <.icon :if={stat[:icon]} name={stat.icon} /> {render_slot(stat)}
        </li>
      </ul>

      <div :if={@contributor != []} class="repo-about__contributors">
        <h3>
          Contributors <span class="repo-about__count">{@contributors || length(@contributor)}</span>
        </h3>
        <%!-- The count is the point. Six faces alone says the repository has
        six contributors, which is usually wrong. --%>
        <ul class="contributor-cluster">
          <li :for={person <- @contributor}>
            <.avatar
              src={person[:src]}
              fallback={String.first(person.name)}
              size={:sm}
              label={person.name}
            />
          </li>
          <li :if={@overflow > 0} class="contributor-cluster__count">+{@overflow}</li>
        </ul>
      </div>

      <div :if={@language != []} class="repo-about__languages">
        <h3>Languages</h3>
        <%!-- One bar, not a stack of bars: the proportions are the point, and
        they only read as proportions when they share a length. --%>
        <div class="language-bar" role="img" aria-label="Language breakdown">
          <span
            :for={{language, index} <- Enum.with_index(@language)}
            class="language-bar__segment"
            data-index={rem(index, 6)}
            style={"width: #{language.percent}%"}
          ></span>
        </div>
        <ul class="repo-about__language-list">
          <li :for={{language, index} <- Enum.with_index(@language)}>
            <span class="language-dot" data-index={rem(index, 6)} aria-hidden="true"></span>
            {render_slot(language)} <span class="repo-about__percent">{language.percent}%</span>
          </li>
        </ul>
      </div>
    </aside>
    """
  end

  @doc """
  A repository's home page, assembled.

  The pieces already exist on their own -- `breadcrumb/1` for the owner trail,
  `repo_tabs/1` for the sections, `file_table/1` for the tree, `repo_about/1`
  for the rail. This holds them in one frame so that a surface showing a
  repository does not reassemble that frame by hand and drift from the next
  surface that shows one.

  The rail is a second grid column above 1024px and falls below the tree under
  it. Provenance -- what this is, how it is licensed, who wrote it -- is what a
  reader wants beside the file list on a desktop and after it on a phone, and
  the source order is already the phone order.

  Composition is by slot rather than by attribute, so this owns the frame and
  nothing else: a caller that needs a tree with no rail, or a commit list where
  the tree usually goes, passes that instead without a flag being added here.
  """
  attr :owner, :string, required: true
  attr :repo, :string, required: true

  attr :owner_path, :string,
    default: nil,
    doc: """
    Where the owner's name leads. Absent means it leads nowhere and is drawn as
    plain text, because there is not necessarily anything at `/OWNER` -- this
    defaulted to that path, and on a deployment with no namespace page every
    repository header carried a link to a 404.
    """

  attr :visibility, :atom, values: [:public, :private], default: :public
  attr :class, :any, default: nil
  attr :rest, :global

  slot :tabs, doc: "the section bar, normally one `repo_tabs/1`"
  slot :inner_block, required: true, doc: "the main column, normally one `file_table/1`"
  slot :about, doc: "the trailing rail, normally one `repo_about/1`"

  def repo_view(assigns) do
    ~H"""
    <div class={["repo-page", @class]} {@rest}>
      <header class="repo-page__identity">
        <%!-- Decorative: the owner's name is the next thing in the trail, and an
        initial announced ahead of it reads as a stray letter. --%>
        <.avatar
          fallback={String.upcase(String.first(@owner))}
          tone={:accent}
          aria-hidden="true"
        />
        <.breadcrumb class="repo-page__trail" label={"#{@owner} / #{@repo}"}>
          <:item :if={@owner_path} navigate={@owner_path}>{@owner}</:item>
          <:item :if={is_nil(@owner_path)}>{@owner}</:item>
          <:item>{@repo}</:item>
        </.breadcrumb>
        <.badge variant={:dim}>{visibility_label(@visibility)}</.badge>
      </header>

      {render_slot(@tabs)}

      <div class="repo-view">
        <div class="repo-view__main">{render_slot(@inner_block)}</div>
        <div :if={@about != []} class="repo-view__rail">{render_slot(@about)}</div>
      </div>
    </div>
    """
  end

  defp visibility_label(:private), do: "Private"
  defp visibility_label(_visibility), do: "Public"

  @doc """
  One file's diff: a header, its hunks, and every line numbered on both sides.

  Adapted from Pierre's `FileDiff` (`@pierre/diffs`, Apache 2.0,
  `pierrecomputer/pierre`). What carried over is the model rather than the
  code -- see `docs/2026-08-20-pierre-code-surfaces-port.md`. Takes an
  `OpenAgents.Diff.File`, which `OpenAgents.Diff.parse/1` produces from the
  output of `git diff-tree -p -M`.

  Unified rather than split. A split view needs roughly twice the width to say
  the same thing, and on a narrow screen it either scrolls sideways or squeezes
  both sides into columns too thin to read. The two line-number gutters carry
  what the split layout is for: which line this was, and which line it is now.

  Every line is addressable. A line's new-side number is a link to itself, so a
  reader can point someone at a line rather than describing where it is. The
  anchor is scoped by path, since one page holds many files.

  Colour is not the only carrier of meaning: an inserted line is marked `+` and
  a deleted one `-` in the gutter, so the diff survives greyscale and a reader
  who cannot separate the two tints.

  Collapsible through native `<details>`, open by default. A reviewer opening a
  commit wants to see it, and a large file is the one they most want to fold
  away -- so the control is there without costing a click on arrival.
  """
  attr :file, :map, required: true, doc: "an `OpenAgents.Diff.File`"
  attr :open, :boolean, default: true
  attr :class, :any, default: nil
  attr :rest, :global

  def diff_file(assigns) do
    assigns = assign(assigns, :slug, diff_slug(assigns.file.path))

    ~H"""
    <details id={"diff-#{@slug}"} class={["diff-file", @class]} open={@open} {@rest}>
      <summary class="diff-file__header">
        <.icon name="chevron-right" class="diff-file__caret" />
        <span class="diff-file__path">
          <span :if={@file.old_path} class="diff-file__from">{@file.old_path} →</span>
          {@file.path}
        </span>
        <span class="diff-file__status" data-status={@file.status}>{@file.status}</span>
        <span :if={@file.insertions > 0} class="diff-file__count" data-kind="insert">
          +{@file.insertions}
        </span>
        <span :if={@file.deletions > 0} class="diff-file__count" data-kind="delete">
          -{@file.deletions}
        </span>
      </summary>

      <p :if={@file.binary?} class="diff-file__note">
        Binary file. Nothing to show as text.
      </p>

      <p :if={not @file.binary? and @file.hunks == []} class="diff-file__note">
        No content change.
      </p>

      <div :for={hunk <- @file.hunks} class="diff-hunk">
        <p class="diff-hunk__header">
          <span class="diff-hunk__range">
            @@ -{hunk.old_start},{hunk.old_count} +{hunk.new_start},{hunk.new_count} @@
          </span>
          <span :if={hunk.heading} class="diff-hunk__heading">{hunk.heading}</span>
        </p>

        <table class="diff-lines">
          <tbody>
            <tr
              :for={line <- hunk.lines}
              id={line_id(@slug, line)}
              class="diff-line"
              data-kind={line.kind}
            >
              <td class="diff-line__number diff-line__number--old">{line.old_number}</td>
              <td class="diff-line__number diff-line__number--new">
                <a :if={line.new_number} href={"##{line_id(@slug, line)}"}>{line.new_number}</a>
                <span :if={is_nil(line.new_number)}>{nil}</span>
              </td>
              <td class="diff-line__marker" aria-hidden="true">{marker(line.kind)}</td>
              <td class="diff-line__text">
                <pre><code>{line.text}</code></pre>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </details>
    """
  end

  # A path is not a DOM id: slashes and dots make `#a/b.ex` an invalid
  # fragment, so the anchor uses a flattened form. Path-scoped rather than
  # global, because one page holds many files and `#L12` alone would be
  # ambiguous across them.
  defp diff_slug(path), do: String.replace(path, ~r/[^A-Za-z0-9]+/, "-")

  defp line_id(slug, %{new_number: number}) when is_integer(number), do: "#{slug}-L#{number}"
  defp line_id(slug, %{old_number: number}) when is_integer(number), do: "#{slug}-R#{number}"
  defp line_id(_slug, _line), do: nil

  defp marker(:insert), do: "+"
  defp marker(:delete), do: "-"
  defp marker(_kind), do: " "

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

  attr :variant, :atom,
    values: [:primary, :secondary, :outline, :ghost, :destructive, :chip, :notched, :link],
    default: :primary

  # Every atom attr states its values. Without a `values:` list Phoenix cannot
  # check call sites, and this one defaulted to `:md` -- not one of
  # `button/1`'s sizes -- so it rendered `data-size="md"`, matched no size
  # rule, and left the control with no height, padding or type scale at all.
  attr :size, :atom, values: [:default, :xs, :sm, :lg], default: :default

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
