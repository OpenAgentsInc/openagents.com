defmodule OpenAgentsWeb.AI.PromptInput do
  @moduledoc """
  The composer: everything between a reader's cursor and a submitted turn.

  Ported from Vercel's AI Elements (MIT) — `prompt-input.tsx`, `attachments.tsx`,
  `speech-input.tsx`, `mic-selector.tsx`, `model-selector.tsx`, and `queue.tsx`.
  The Tailwind is the point of the port and is carried across close to
  verbatim; the React around it is not. Four things changed on the way, and
  each one is a rule of this repo rather than a preference:

    * **No React, no Radix, no client state library.** The source keeps input
      text, attachment lists, recording state, and menu state in hooks and
      contexts. Here the caller owns all of it: components take what to draw
      and emit events. The three behaviors markup cannot express — auto-resize
      with Enter-to-submit, microphone capture, and incremental filtering — are
      colocated LiveView hooks, per `AGENTS.md`.

    * **Forms are Phoenix's.** `prompt_input/1` is `Phoenix.Component.form/1`
      driven by a `to_form/2` assign with a required DOM id, and
      `prompt_input_textarea/1` takes a `Phoenix.HTML.FormField`. It renders
      `OpenAgentsWeb.UI.textarea/1` rather than `UI.input/1` because `input/1`
      wraps its control in a `.field` with a bottom margin, and the input group
      needs the control to be a direct flex child.

    * **`bg-accent` means something else here.** In shadcn, `--accent` is a
      quiet hover surface. In OpenAgents it is the indigo brand color (see the
      deliberate name collision noted in `assets/css/app.css`), so every
      `hover:bg-accent` in the source is `hover:bg-muted` here, and
      `hover:text-accent-foreground` is `hover:text-foreground`. Keeping the
      source class would have painted indigo on every hover.

    * **`dark:` is dead in this bundle.** Basecoat declares the variant as
      `&:is(html.dark *)`, and this app themes by `data-theme` on `:root`, so
      every `dark:` utility in the source would compile to a selector that
      never matches. They are dropped rather than left as noise; the palette
      already inverts through the token ladder.

  Icons go through `OpenAgentsWeb.UI.icon/1` and the vendored Apps SDK set
  only. The `lucide-react` glyphs map as: `CornerDownLeft` to
  `arrow-curved-left`, `Square` to `stop`, `X` to `x`, `Spinner` to `spin`,
  `Plus` to `plus`, `Image` to `image-square`, `Monitor` to `desktop`, `Mic` to
  `mic`, `Paperclip` to `paperclip`, `FileText` to `file-document`, `Globe` to
  `globe`, `Music2` to `music`, `Video` to `video`, `ChevronDown` to
  `chevron-down`, and `ChevronsUpDown` to `chevron-up-down`. No Heroicons
  fallback was needed, so `docs/ICONS.md` gains no inventory entry.
  """

  use Phoenix.Component

  alias OpenAgentsWeb.UI

  # ── Shared class recipes ──────────────────────────────────────────────────
  # The shadcn `input-group` primitive is not vendored into this app's CSS
  # bundle (`assets/css/app.css` imports Basecoat components one at a time and
  # `input-group` is not on the list), so its structure lives here as the same
  # utilities the primitive composes. That is what the port asked for anyway.

  @input_group """
  group/input-group relative flex w-full min-w-0 items-center rounded-md border \
  border-input shadow-xs outline-none transition-[color,box-shadow] \
  h-9 has-[>textarea]:h-auto \
  has-[>[data-align=inline-start]]:[&>input]:pl-2 \
  has-[>[data-align=inline-end]]:[&>input]:pr-2 \
  has-[>[data-align=block-start]]:h-auto has-[>[data-align=block-start]]:flex-col \
  has-[>[data-align=block-start]]:[&>input]:pb-3 \
  has-[>[data-align=block-end]]:h-auto has-[>[data-align=block-end]]:flex-col \
  has-[>[data-align=block-end]]:[&>input]:pt-3 \
  has-[[data-slot=input-group-control]:focus-visible]:border-ring \
  has-[[data-slot=input-group-control]:focus-visible]:ring-ring/50 \
  has-[[data-slot=input-group-control]:focus-visible]:ring-[3px] \
  has-[[data-slot][aria-invalid=true]]:border-destructive \
  has-[[data-slot][aria-invalid=true]]:ring-destructive/20\
  """

  @addon """
  flex h-auto cursor-text select-none items-center justify-center gap-2 py-1.5 \
  text-sm font-medium text-muted-foreground \
  [&>svg:not([class*='size-'])]:size-4 [&>kbd]:rounded-[calc(var(--radius)-5px)] \
  group-data-[disabled=true]/input-group:opacity-50 \
  order-last w-full justify-start px-3 pb-3 [.border-t]:pt-3 \
  group-has-[>input]/input-group:pb-2.5\
  """

  @button_base "flex min-w-0 items-center gap-2 text-sm shadow-none"

  @command_item """
  flex w-full cursor-default select-none items-center gap-2 rounded-sm px-2 py-1.5 \
  text-sm outline-none hover:bg-muted hover:text-foreground \
  aria-selected:bg-muted aria-selected:text-foreground \
  data-[disabled=true]:pointer-events-none data-[disabled=true]:opacity-50 \
  [&>svg:not([class*='size-'])]:size-4\
  """

  @statuses [:ready, :submitted, :streaming, :error]
  @variants [:grid, :inline, :list]
  @sizes [:xs, :sm, :icon_xs, :icon_sm]

  # ── PromptInput: the form shell ───────────────────────────────────────────

  @doc """
  The composer form: a `Phoenix.Component.form/1` wrapping the input group.

  The source renders a hidden `<input type="file">` beside the form and drives
  it from React context. The same input is rendered here and driven by the
  colocated `.PromptInput` hook, which also carries the two behaviors the
  source keeps in JavaScript for the same reason: dropped and pasted files are
  written onto the file input through a `DataTransfer` so a normal
  `phx-change` upload sees them, and drag state is published as `data-dragging`
  on the form so the `drop_overlay` slot can appear.

  `accept`, `multiple`, and the upload name are attributes because the file
  transport is the LiveView's business, not this component's.
  """
  attr :id, :string, required: true
  attr :for, :any, required: true, doc: "a `to_form/2` result"
  attr :accept, :string, default: nil, doc: ~s(such as "image/*")
  attr :multiple, :boolean, default: true
  attr :file_input_name, :string, default: nil, doc: "name for the hidden file input"

  attr :submit_on_enter, :boolean,
    default: true,
    doc: "Enter submits and Shift+Enter inserts a newline"

  attr :backspace_event, :string,
    default: nil,
    doc: """
    pushed when Backspace is pressed in an empty textarea, which is how the
    source removes the last attachment
    """

  attr :class, :any, default: nil
  attr :group_class, :any, default: nil
  attr :rest, :global, include: ~w(method action)
  slot :inner_block, required: true
  slot :drop_overlay, doc: "shown while files are dragged over the composer"

  def prompt_input(assigns) do
    ~H"""
    <div class="contents">
      <input
        type="file"
        id={"#{@id}-files"}
        name={@file_input_name}
        accept={@accept}
        multiple={@multiple}
        aria-label="Upload files"
        title="Upload files"
        class="hidden"
      />
      <.form
        for={@for}
        id={@id}
        class={["group/prompt-input relative w-full", @class]}
        phx-hook=".PromptInput"
        data-file-input={"#{@id}-files"}
        data-submit-on-enter={to_string(@submit_on_enter)}
        data-backspace-event={@backspace_event}
        data-dragging="false"
        {@rest}
      >
        <div
          role="group"
          data-slot="input-group"
          class={[input_group(), "overflow-hidden", @group_class]}
        >
          {render_slot(@inner_block)}
        </div>
        <div
          :if={@drop_overlay != []}
          aria-hidden="true"
          class={[
            "pointer-events-none absolute inset-0 hidden items-center justify-center",
            "rounded-md bg-background/80 text-muted-foreground text-sm backdrop-blur-sm",
            "group-data-[dragging=true]/prompt-input:flex"
          ]}
        >
          {render_slot(@drop_overlay)}
        </div>
      </.form>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PromptInput">
      export default {
        mounted() {
          this.textarea = this.el.querySelector("textarea[data-slot='input-group-control']")
          this.fileInput = document.getElementById(this.el.dataset.fileInput)
          this.composing = false
          this.dragDepth = 0

          this.resize = () => {
            const el = this.textarea
            if (!el) return
            // `field-sizing-content` already does this where it is supported.
            // This keeps the control honest everywhere else, and the reset to
            // "auto" must run before scrollHeight is read or the box grows
            // without ever shrinking again.
            el.style.height = "auto"
            el.style.height = `${el.scrollHeight}px`
          }

          this.onCompositionStart = () => { this.composing = true }
          this.onCompositionEnd = () => { this.composing = false }

          this.onKeyDown = (event) => {
            if (event.key === "Enter" && this.el.dataset.submitOnEnter === "true") {
              if (this.composing || event.isComposing || event.shiftKey) return
              event.preventDefault()
              const submit = this.el.querySelector("button[type='submit']")
              if (submit && submit.disabled) return
              this.el.requestSubmit()
              return
            }

            const backspaceEvent = this.el.dataset.backspaceEvent
            if (event.key === "Backspace" && backspaceEvent && event.currentTarget.value === "") {
              event.preventDefault()
              this.pushEvent(backspaceEvent, {})
            }
          }

          this.adopt = (fileList) => {
            if (!this.fileInput || !fileList || fileList.length === 0) return false
            const transfer = new DataTransfer()
            if (this.fileInput.multiple) {
              for (const file of this.fileInput.files) transfer.items.add(file)
            }
            for (const file of fileList) transfer.items.add(file)
            this.fileInput.files = transfer.files
            this.fileInput.dispatchEvent(new Event("input", { bubbles: true }))
            this.fileInput.dispatchEvent(new Event("change", { bubbles: true }))
            return true
          }

          this.onPaste = (event) => {
            const files = []
            for (const item of event.clipboardData?.items ?? []) {
              if (item.kind !== "file") continue
              const file = item.getAsFile()
              if (file) files.push(file)
            }
            if (files.length > 0 && this.adopt(files)) event.preventDefault()
          }

          this.onDragEnter = (event) => {
            if (!event.dataTransfer?.types?.includes("Files")) return
            this.dragDepth += 1
            this.el.dataset.dragging = "true"
          }

          this.onDragOver = (event) => {
            if (event.dataTransfer?.types?.includes("Files")) event.preventDefault()
          }

          this.onDragLeave = () => {
            this.dragDepth = Math.max(0, this.dragDepth - 1)
            if (this.dragDepth === 0) this.el.dataset.dragging = "false"
          }

          this.onDrop = (event) => {
            if (!event.dataTransfer?.types?.includes("Files")) return
            event.preventDefault()
            this.dragDepth = 0
            this.el.dataset.dragging = "false"
            this.adopt(event.dataTransfer.files)
          }

          if (this.textarea) {
            this.textarea.addEventListener("input", this.resize)
            this.textarea.addEventListener("keydown", this.onKeyDown)
            this.textarea.addEventListener("paste", this.onPaste)
            this.textarea.addEventListener("compositionstart", this.onCompositionStart)
            this.textarea.addEventListener("compositionend", this.onCompositionEnd)
            this.resize()
          }
          this.el.addEventListener("dragenter", this.onDragEnter)
          this.el.addEventListener("dragover", this.onDragOver)
          this.el.addEventListener("dragleave", this.onDragLeave)
          this.el.addEventListener("drop", this.onDrop)
        },

        updated() { this.resize() },

        destroyed() {
          if (this.textarea) {
            this.textarea.removeEventListener("input", this.resize)
            this.textarea.removeEventListener("keydown", this.onKeyDown)
            this.textarea.removeEventListener("paste", this.onPaste)
            this.textarea.removeEventListener("compositionstart", this.onCompositionStart)
            this.textarea.removeEventListener("compositionend", this.onCompositionEnd)
          }
          this.el.removeEventListener("dragenter", this.onDragEnter)
          this.el.removeEventListener("dragover", this.onDragOver)
          this.el.removeEventListener("dragleave", this.onDragLeave)
          this.el.removeEventListener("drop", this.onDrop)
        },
      }
    </script>
    """
  end

  @doc """
  A transparent grouping wrapper, so a caller can compose the composer's parts
  in one block without adding a box to the flex layout.
  """
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def prompt_input_body(assigns) do
    ~H"""
    <div class={["contents", @class]} {@rest}>{render_slot(@inner_block)}</div>
    """
  end

  @doc """
  The message control.

  Takes a `Phoenix.HTML.FormField` so the id, name, and value come from the
  form the shell is already driving. The class strip is the source's
  `field-sizing-content max-h-48 min-h-16` on top of the input-group control
  recipe, which flattens the vendored `.textarea` border, radius, background,
  and focus ring — in an input group the *group* carries all four.
  """
  attr :id, :string, default: nil
  attr :field, Phoenix.HTML.FormField, default: nil
  attr :name, :string, default: nil
  attr :value, :string, default: nil
  attr :placeholder, :string, default: "What would you like to know?"
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(autocomplete disabled maxlength readonly required rows)

  def prompt_input_textarea(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign(:field, nil)
    |> assign(:id, assigns.id || field.id)
    |> assign(:name, field.name)
    |> assign(:value, Phoenix.HTML.Form.normalize_value("textarea", field.value))
    |> prompt_input_textarea()
  end

  def prompt_input_textarea(assigns) do
    ~H"""
    <UI.textarea
      id={@id}
      name={@name}
      value={@value}
      placeholder={@placeholder}
      data-slot="input-group-control"
      class={[
        "field-sizing-content max-h-48 min-h-16",
        "flex-1 resize-none rounded-none border-0 bg-transparent py-3 shadow-none",
        "focus-visible:ring-0",
        @class
      ]}
      {@rest}
    />
    """
  end

  @doc """
  The strip above the control. Attachments live here.

  The source aligns this addon `block-end` and then reorders it with
  `order-first`, which is the shape kept below: the input group's flex-column
  branch keys off `data-align`, and `order-first` is what actually lifts it.
  """
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def prompt_input_header(assigns) do
    ~H"""
    <div
      role="group"
      data-slot="input-group-addon"
      data-align="block-end"
      class={[addon(), "order-first flex-wrap gap-1", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The strip below the control: tools on one side, submit on the other."
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def prompt_input_footer(assigns) do
    ~H"""
    <div
      role="group"
      data-slot="input-group-addon"
      data-align="block-end"
      class={[addon(), "justify-between gap-1", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  The composer toolbar. The same shape as `prompt_input_footer/1`, which is the
  name the current source gives it; `toolbar` is kept because that is what the
  part is called everywhere else in AI Elements.
  """
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def prompt_input_toolbar(assigns) do
    ~H"""
    <.prompt_input_footer class={@class} {@rest}>
      {render_slot(@inner_block)}
    </.prompt_input_footer>
    """
  end

  @doc "A run of controls inside the toolbar."
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def prompt_input_tools(assigns) do
    ~H"""
    <div class={["flex min-w-0 items-center gap-1", @class]} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  A composer control.

  Renders `OpenAgentsWeb.UI.button/1` with the source's input-group button
  sizing on top, so the product's own button grammar keeps the color and focus
  treatment while the composer keeps AI Elements' geometry.

  The source wraps this in a Radix tooltip. There is no Radix here and the repo
  has no tooltip primitive, so `tooltip` becomes the native `title` attribute:
  the same text, reachable by pointer but not by keyboard. An icon-only control
  still needs its own `aria-label`.
  """
  attr :variant, :atom,
    values: [:primary, :secondary, :outline, :ghost, :destructive],
    default: :ghost

  attr :size, :atom, values: @sizes, default: :icon_sm
  attr :tooltip, :string, default: nil
  attr :type, :string, default: "button"
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled form name value popovertarget popovertargetaction)
  slot :inner_block, required: true

  def prompt_input_button(assigns) do
    ~H"""
    <UI.button
      type={@type}
      variant={@variant}
      title={@tooltip}
      class={[button_base(), button_size_class(@size), @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </UI.button>
    """
  end

  @doc """
  The send control, and the stop control while a turn is in flight.

  `status` is the caller's: `:ready`, `:submitted`, `:streaming`, or `:error` —
  the same four `ChatStatus` values the source reads. `:submitted` and
  `:streaming` are "generating", which renames the control to **Stop**; given
  `on_stop`, the control also stops being a submit button, exactly as the
  source does, so pressing it aborts rather than sending a second turn.
  """
  attr :id, :string, default: nil
  attr :status, :atom, values: @statuses, default: :ready
  attr :on_stop, :any, default: nil, doc: "a `Phoenix.LiveView.JS` command or event name"
  attr :label, :string, default: nil, doc: "overrides the derived accessible name"
  attr :size, :atom, values: @sizes, default: :icon_sm
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled form name value)
  slot :inner_block

  def prompt_input_submit(assigns) do
    generating? = assigns.status in [:submitted, :streaming]

    assigns =
      assigns
      |> assign(:generating?, generating?)
      |> assign(:stopping?, generating? and not is_nil(assigns.on_stop))

    ~H"""
    <UI.button
      id={@id}
      type={if @stopping?, do: "button", else: "submit"}
      variant={:primary}
      phx-click={@stopping? && @on_stop}
      aria-label={@label || if(@generating?, do: "Stop", else: "Submit")}
      data-status={@status}
      class={[button_base(), button_size_class(@size), "justify-center", @class]}
      {@rest}
    >
      <%= if @inner_block != [] do %>
        {render_slot(@inner_block)}
      <% else %>
        <UI.icon :if={@status == :ready} name="arrow-curved-left" class="size-4" />
        <UI.icon :if={@status == :submitted} name="spin" class="size-4 animate-spin" />
        <UI.icon :if={@status == :streaming} name="stop" class="size-4" />
        <UI.icon :if={@status == :error} name="x" class="size-4" />
      <% end %>
    </UI.button>
    """
  end

  # ── Action menu ───────────────────────────────────────────────────────────

  @doc """
  The composer's add menu.

  A native `popover`, the same bounded disclosure `OpenAgentsWeb.UI.menu/1`
  documents, rather than a port of Radix's dropdown. Render the trigger with
  `prompt_input_action_menu_trigger/1` and give it this menu's id.
  """
  attr :id, :string, required: true
  attr :label, :string, default: "Composer actions"
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def prompt_input_action_menu(assigns) do
    ~H"""
    <UI.menu id={@id} label={@label} class={["min-w-56 p-1", @class]} {@rest}>
      {render_slot(@inner_block)}
    </UI.menu>
    """
  end

  @doc "Opens the action menu. Defaults to the source's plus glyph."
  attr :id, :string, default: nil
  attr :menu, :string, required: true, doc: "the `prompt_input_action_menu/1` id"
  attr :label, :string, default: "Open composer actions"
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled)
  slot :inner_block

  def prompt_input_action_menu_trigger(assigns) do
    ~H"""
    <.prompt_input_button
      id={@id}
      aria-label={@label}
      popovertarget={@menu}
      popovertargetaction="toggle"
      class={@class}
      {@rest}
    >
      <%= if @inner_block != [] do %>
        {render_slot(@inner_block)}
      <% else %>
        <UI.icon name="plus" class="size-4" />
      <% end %>
    </.prompt_input_button>
    """
  end

  @doc "The action menu's own body, for grouping items."
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def prompt_input_action_menu_content(assigns) do
    ~H"""
    <div class={["flex flex-col gap-0.5", @class]} {@rest}>{render_slot(@inner_block)}</div>
    """
  end

  @doc "One action in the menu."
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled form name value popovertarget popovertargetaction)
  slot :inner_block, required: true

  def prompt_input_action_menu_item(assigns) do
    ~H"""
    <button id={@id} type="button" role="menuitem" class={[command_item(), @class]} {@rest}>
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc """
  The menu item that opens the file dialog.

  The source calls `attachments.openFileDialog()` through React context. Here
  the item is a label pointing at the composer's hidden file input, so the
  browser opens the dialog and no JavaScript is involved at all.
  """
  attr :id, :string, default: nil
  attr :for, :string, required: true, doc: "the `prompt_input/1` id"
  attr :label, :string, default: "Add photos or files"
  attr :class, :any, default: nil
  attr :rest, :global

  def prompt_input_action_add_attachments(assigns) do
    ~H"""
    <label
      id={@id}
      role="menuitem"
      tabindex="0"
      for={"#{@for}-files"}
      class={[command_item(), "cursor-pointer", @class]}
      {@rest}
    >
      <UI.icon name="image-square" class="mr-2 size-4" />{@label}
    </label>
    """
  end

  @doc """
  The menu item that captures the screen.

  Screen capture is `getDisplayMedia`, which only a user gesture on the client
  can start, so the item carries `phx-click` for the LiveView to hear and the
  capture stays the caller's to wire. The source's inline canvas capture is
  deliberately not reimplemented: it produces a `File`, and file transport
  belongs to the LiveView's uploader.
  """
  attr :id, :string, default: nil
  attr :label, :string, default: "Take screenshot"
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled)

  def prompt_input_action_add_screenshot(assigns) do
    ~H"""
    <button id={@id} type="button" role="menuitem" class={[command_item(), @class]} {@rest}>
      <UI.icon name="desktop" class="mr-2 size-4" />{@label}
    </button>
    """
  end

  # ── Model select, in the composer toolbar ─────────────────────────────────

  @doc """
  The model picker that sits in the composer toolbar.

  A native `<select>`. Radix's Select splits into Trigger, Value, Content, and
  Item so that a `<div>` can pretend to be a control; a real `<select>` is one
  element that already has the keyboard behavior, the typeahead, and the mobile
  treatment, so the split has nothing left to describe. The source's trigger
  classes are carried onto it, minus `bg-accent` — see the module note.
  """
  attr :id, :string, default: nil
  attr :name, :string, default: nil
  attr :value, :any, default: nil
  attr :label, :string, default: "Model"
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled form required)
  slot :inner_block, required: true

  def prompt_input_model_select(assigns) do
    ~H"""
    <select
      id={@id}
      name={@name}
      aria-label={@label}
      class={[
        "h-8 rounded-md border-none bg-transparent px-2 font-medium text-muted-foreground text-sm",
        "shadow-none transition-colors",
        "hover:bg-muted hover:text-foreground",
        "aria-expanded:bg-muted aria-expanded:text-foreground",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/50",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block, @value)}
    </select>
    """
  end

  @doc "One model in `prompt_input_model_select/1`."
  attr :value, :string, required: true
  attr :selected, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled)
  slot :inner_block, required: true

  def prompt_input_model_select_item(assigns) do
    ~H"""
    <option value={@value} selected={@selected} class={@class} {@rest}>
      {render_slot(@inner_block)}
    </option>
    """
  end

  # ── Attachments ───────────────────────────────────────────────────────────

  @doc """
  The list of things attached to the next turn.

  `variant` is the source's: `:grid` for the thumbnail strip above the control,
  `:inline` for chips beside it, `:list` for a stacked review. Each child
  `attachment/1` must be told the same variant — React passed it down through
  context, and HEEx has no context.
  """
  attr :id, :string, default: nil
  attr :variant, :atom, values: @variants, default: :grid
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def attachments(assigns) do
    ~H"""
    <div
      id={@id}
      data-slot="attachments"
      data-variant={@variant}
      class={[
        "flex items-start",
        @variant == :list && "flex-col gap-2",
        @variant != :list && "flex-wrap gap-2",
        @variant == :grid && "ml-auto w-fit",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "One attachment."
  attr :id, :string, default: nil
  attr :variant, :atom, values: @variants, default: :grid
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def attachment(assigns) do
    ~H"""
    <div
      id={@id}
      data-slot="attachment"
      data-variant={@variant}
      class={[
        "group/attachment relative",
        @variant == :grid && "size-24 overflow-hidden rounded-lg",
        @variant == :inline &&
          [
            "flex h-8 cursor-pointer select-none items-center gap-1.5",
            "rounded-md border border-border px-1.5",
            "font-medium text-sm transition-all",
            "hover:bg-muted hover:text-foreground"
          ],
        @variant == :list &&
          [
            "flex w-full items-center gap-3 rounded-lg border p-3",
            "hover:bg-muted/50"
          ],
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  The attachment's thumbnail.

  An image or a video poster when `src` is given and the media category can
  show one; otherwise the glyph for the category, which is how the source
  distinguishes an audio file from a document at a glance.
  """
  attr :variant, :atom, values: @variants, default: :grid

  attr :media_category, :atom,
    values: [:image, :video, :audio, :document, :source, :unknown],
    default: :unknown

  attr :src, :string, default: nil
  attr :filename, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  def attachment_preview(assigns) do
    ~H"""
    <div
      data-slot="attachment-preview"
      class={[
        "flex shrink-0 items-center justify-center overflow-hidden",
        @variant == :grid && "size-full bg-muted",
        @variant == :inline && "size-5 rounded bg-background",
        @variant == :list && "size-12 rounded bg-muted",
        @class
      ]}
      {@rest}
    >
      <img
        :if={@media_category == :image and @src}
        src={@src}
        alt={@filename || "Image"}
        width={if @variant == :grid, do: "96", else: "20"}
        height={if @variant == :grid, do: "96", else: "20"}
        class={["size-full object-cover", @variant != :grid && "rounded"]}
      />
      <video
        :if={@media_category == :video and @src}
        src={@src}
        muted
        class="size-full object-cover"
      />
      <UI.icon
        :if={is_nil(@src) or @media_category not in [:image, :video]}
        name={media_icon(@media_category)}
        class={[if(@variant == :inline, do: "size-3", else: "size-4"), "text-muted-foreground"]}
      />
    </div>
    """
  end

  @doc """
  The attachment's name, and optionally its media type.

  Renders nothing in the `:grid` variant, where the thumbnail is the whole
  item — the same early return the source makes.
  """
  attr :label, :string, required: true
  attr :variant, :atom, values: @variants, default: :inline
  attr :media_type, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  def attachment_info(assigns) do
    ~H"""
    <div
      :if={@variant != :grid}
      data-slot="attachment-info"
      class={["min-w-0 flex-1", @class]}
      {@rest}
    >
      <span class="block truncate">{@label}</span>
      <span :if={@media_type} class="block truncate text-muted-foreground text-xs">
        {@media_type}
      </span>
    </div>
    """
  end

  @doc """
  Removes one attachment.

  In `:grid` and `:inline` the control is revealed on hover, as in the source.
  That hides a control from a pointer user until they look for it, and it must
  not hide it from anyone else, so the visible label stays `sr-only`, the
  button keeps its own `aria-label`, and `focus-visible` reveals it as well.
  """
  attr :id, :string, default: nil
  attr :variant, :atom, values: @variants, default: :grid
  attr :label, :string, default: "Remove"
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled form name value)
  slot :inner_block

  def attachment_remove(assigns) do
    ~H"""
    <UI.button
      id={@id}
      type="button"
      variant={:ghost}
      aria-label={@label}
      data-slot="attachment-remove"
      class={[
        @variant == :grid &&
          [
            "absolute top-2 right-2 size-6 rounded-full p-0",
            "bg-background/80 backdrop-blur-sm",
            "opacity-0 transition-opacity group-hover/attachment:opacity-100 focus-visible:opacity-100",
            "hover:bg-background",
            "[&>svg]:size-3"
          ],
        @variant == :inline &&
          [
            "size-5 rounded p-0",
            "opacity-0 transition-opacity group-hover/attachment:opacity-100 focus-visible:opacity-100",
            "[&>svg]:size-2.5"
          ],
        @variant == :list && ["size-8 shrink-0 rounded p-0", "[&>svg]:size-4"],
        @class
      ]}
      {@rest}
    >
      <%= if @inner_block != [] do %>
        {render_slot(@inner_block)}
      <% else %>
        <UI.icon name="x" />
      <% end %>
      <span class="sr-only">{@label}</span>
    </UI.button>
    """
  end

  @doc "What stands in for the attachment list when nothing is attached."
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block

  def attachment_empty(assigns) do
    ~H"""
    <div
      id={@id}
      data-slot="attachment-empty"
      class={["flex items-center justify-center p-4 text-muted-foreground text-sm", @class]}
      {@rest}
    >
      <%= if @inner_block != [] do %>
        {render_slot(@inner_block)}
      <% else %>
        No attachments
      <% end %>
    </div>
    """
  end

  # ── Speech input ──────────────────────────────────────────────────────────

  @doc """
  Push-to-talk.

  The source detects the Web Speech API, falls back to `MediaRecorder`, and
  disables itself when neither exists. All three live in the colocated
  `.SpeechInput` hook, which publishes what it found as `data-mode` and its
  state as `data-recording` and `data-processing` on the wrapper, so the whole
  visual treatment — including the three staggered ping rings — is CSS keyed
  off attributes rather than a React render.

  Recognized text is pushed to the LiveView as `transcript_event` with a
  `"text"` key. Recorded audio cannot travel in a LiveView event, so in the
  `MediaRecorder` fallback the hook writes the blob onto the file input named
  by `audio_input` and lets the caller's uploader carry it. Without one, the
  control disables itself in that fallback, which is what the source does when
  no `onAudioRecorded` callback is given.
  """
  attr :id, :string, required: true
  attr :transcript_event, :string, required: true
  attr :audio_input, :string, default: nil, doc: "id of a file input for the recorded audio"
  attr :lang, :string, default: "en-US"
  attr :label, :string, default: "Start voice input"
  attr :stop_label, :string, default: "Stop voice input"
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled)

  def speech_input(assigns) do
    ~H"""
    <div
      id={@id}
      class="group/speech relative inline-flex items-center justify-center"
      phx-hook=".SpeechInput"
      data-recording="false"
      data-processing="false"
      data-lang={@lang}
      data-transcript-event={@transcript_event}
      data-audio-input={@audio_input}
    >
      <div
        :for={index <- 0..2}
        aria-hidden="true"
        class={[
          "absolute inset-0 hidden animate-ping rounded-full border-2 border-destructive/30",
          "group-data-[recording=true]/speech:block"
        ]}
        style={"animation-delay: #{index * 0.3}s; animation-duration: 2s"}
      >
      </div>
      <UI.button
        id={"#{@id}-button"}
        type="button"
        variant={:primary}
        aria-label={@label}
        data-label={@label}
        data-stop-label={@stop_label}
        class={[
          "relative z-10 size-8 justify-center rounded-full p-0 transition-all duration-300",
          "bg-primary text-primary-foreground hover:bg-primary/80 hover:text-primary-foreground",
          "group-data-[recording=true]/speech:bg-destructive",
          "group-data-[recording=true]/speech:text-white",
          "group-data-[recording=true]/speech:hover:bg-destructive/80",
          @class
        ]}
        {@rest}
      >
        <UI.icon
          name="spin"
          class="hidden size-4 animate-spin group-data-[processing=true]/speech:block"
        />
        <UI.icon
          name="stop"
          class={[
            "hidden size-4 group-data-[recording=true]/speech:block",
            "group-data-[processing=true]/speech:hidden"
          ]}
        />
        <UI.icon
          name="mic"
          class={[
            "size-4 group-data-[recording=true]/speech:hidden",
            "group-data-[processing=true]/speech:hidden"
          ]}
        />
      </UI.button>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".SpeechInput">
      const detectMode = () => {
        if (typeof window === "undefined") return "none"
        if ("SpeechRecognition" in window || "webkitSpeechRecognition" in window) {
          return "speech-recognition"
        }
        if ("MediaRecorder" in window && "mediaDevices" in navigator) return "media-recorder"
        return "none"
      }

      export default {
        mounted() {
          this.button = this.el.querySelector("button")
          this.mode = detectMode()
          this.el.dataset.mode = this.mode
          this.chunks = []

          const audioInput = () =>
            this.el.dataset.audioInput ? document.getElementById(this.el.dataset.audioInput) : null

          if (this.mode === "none" || (this.mode === "media-recorder" && !audioInput())) {
            this.button.disabled = true
            return
          }

          this.setRecording = (recording) => {
            this.el.dataset.recording = recording ? "true" : "false"
            this.button.setAttribute(
              "aria-label",
              recording ? this.button.dataset.stopLabel : this.button.dataset.label
            )
          }

          if (this.mode === "speech-recognition") {
            const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition
            this.recognition = new Recognition()
            this.recognition.continuous = true
            this.recognition.interimResults = true
            this.recognition.lang = this.el.dataset.lang

            this.recognition.addEventListener("start", () => this.setRecording(true))
            this.recognition.addEventListener("end", () => this.setRecording(false))
            this.recognition.addEventListener("error", () => this.setRecording(false))
            this.recognition.addEventListener("result", (event) => {
              let text = ""
              for (let i = event.resultIndex; i < event.results.length; i += 1) {
                const result = event.results[i]
                if (result.isFinal) text += result[0]?.transcript ?? ""
              }
              if (text) this.pushEvent(this.el.dataset.transcriptEvent, { text })
            })
          }

          this.startRecorder = async () => {
            try {
              this.stream = await navigator.mediaDevices.getUserMedia({ audio: true })
            } catch {
              this.setRecording(false)
              return
            }
            this.chunks = []
            this.recorder = new MediaRecorder(this.stream)
            this.recorder.addEventListener("dataavailable", (event) => {
              if (event.data.size > 0) this.chunks.push(event.data)
            })
            this.recorder.addEventListener("stop", () => {
              for (const track of this.stream.getTracks()) track.stop()
              this.stream = null
              const blob = new Blob(this.chunks, { type: "audio/webm" })
              const input = audioInput()
              if (blob.size === 0 || !input) return
              this.el.dataset.processing = "true"
              const transfer = new DataTransfer()
              transfer.items.add(new File([blob], "speech.webm", { type: "audio/webm" }))
              input.files = transfer.files
              input.dispatchEvent(new Event("input", { bubbles: true }))
              input.dispatchEvent(new Event("change", { bubbles: true }))
              this.el.dataset.processing = "false"
            })
            this.recorder.start()
            this.setRecording(true)
          }

          this.onClick = () => {
            const recording = this.el.dataset.recording === "true"
            if (this.mode === "speech-recognition") {
              if (recording) { this.recognition.stop() } else { this.recognition.start() }
              return
            }
            if (recording) {
              if (this.recorder && this.recorder.state === "recording") this.recorder.stop()
              this.setRecording(false)
            } else {
              this.startRecorder()
            }
          }

          this.button.addEventListener("click", this.onClick)
        },

        destroyed() {
          if (this.button && this.onClick) this.button.removeEventListener("click", this.onClick)
          if (this.recognition) this.recognition.stop()
          if (this.recorder && this.recorder.state === "recording") this.recorder.stop()
          if (this.stream) { for (const track of this.stream.getTracks()) track.stop() }
        },
      }
    </script>
    """
  end

  # ── Mic selector ──────────────────────────────────────────────────────────

  @doc """
  Chooses the microphone.

  The device list only exists on the client — `enumerateDevices` returns
  nothing useful until microphone permission has been granted, and the source
  requests it when its popover opens. The same sequence is a colocated hook
  here, filling a native `<select>`, so the element carries
  `phx-update="ignore"`: its options are the hook's, and a LiveView patch must
  not discard them.

  Devices the server already knows can still be passed as `mic_selector_item/1`
  children; the hook replaces them once the browser answers.
  """
  attr :id, :string, required: true
  attr :name, :string, default: nil
  attr :label, :string, default: "Microphone"
  attr :placeholder, :string, default: "Select microphone..."
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled form required)
  slot :inner_block

  def mic_selector(assigns) do
    ~H"""
    <select
      id={@id}
      name={@name}
      aria-label={@label}
      phx-hook=".MicSelector"
      phx-update="ignore"
      data-placeholder={@placeholder}
      class={[
        "h-8 min-w-0 max-w-56 truncate rounded-md border border-input bg-transparent px-2",
        "text-left text-muted-foreground text-sm shadow-none transition-colors",
        "hover:bg-muted hover:text-foreground",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/50",
        @class
      ]}
      {@rest}
    >
      <option value="">{@placeholder}</option>
      {render_slot(@inner_block)}
    </select>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".MicSelector">
      // The source strips the trailing hardware id out of a device label and
      // shows it dimmed beside the name. An <option> holds text and nothing
      // else, so the two parts are joined rather than styled apart.
      const deviceIdPattern = /\s*\(([0-9a-f]{4}:[0-9a-f]{4})\)$/i

      export default {
        async mounted() {
          if (!navigator.mediaDevices || !navigator.mediaDevices.enumerateDevices) {
            this.el.disabled = true
            return
          }

          this.load = async () => {
            let devices = []
            try {
              devices = await navigator.mediaDevices.enumerateDevices()
            } catch {
              return
            }
            const inputs = devices.filter((device) => device.kind === "audioinput" && device.label)
            if (inputs.length === 0) return

            const selected = this.el.value
            this.el.replaceChildren()
            this.el.append(new Option(this.el.dataset.placeholder, ""))
            for (const device of inputs) {
              const matches = device.label.match(deviceIdPattern)
              const label = matches
                ? `${device.label.replace(deviceIdPattern, "")} (${matches[1]})`
                : device.label
              this.el.append(new Option(label, device.deviceId))
            }
            if (selected) this.el.value = selected
          }

          this.onDeviceChange = () => this.load()
          navigator.mediaDevices.addEventListener("devicechange", this.onDeviceChange)
          await this.load()
        },

        destroyed() {
          if (this.onDeviceChange) {
            navigator.mediaDevices.removeEventListener("devicechange", this.onDeviceChange)
          }
        },
      }
    </script>
    """
  end

  @doc "One microphone the server already knows about."
  attr :value, :string, required: true
  attr :selected, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def mic_selector_item(assigns) do
    ~H"""
    <option value={@value} selected={@selected} class={@class} {@rest}>
      {render_slot(@inner_block)}
    </option>
    """
  end

  # ── Model selector, the searchable panel ──────────────────────────────────

  @doc """
  The full model picker: a searchable list in a bounded disclosure.

  The source is a `cmdk` command palette inside a Radix dialog. Neither is
  vendored, so this is `OpenAgentsWeb.UI.menu/1` — a native `popover` — with
  the filtering in a colocated hook that matches each item's `data-value` and
  reveals `model_selector_empty/1` when nothing survives.
  """
  attr :id, :string, required: true
  attr :label, :string, default: "Select a model"
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def model_selector(assigns) do
    ~H"""
    <UI.menu
      id={@id}
      label={@label}
      class={["w-80 max-w-[90vw] overflow-hidden p-0", @class]}
      phx-hook=".ModelSelectorFilter"
      {@rest}
    >
      {render_slot(@inner_block)}
    </UI.menu>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ModelSelectorFilter">
      export default {
        mounted() {
          this.input = this.el.querySelector("[data-slot='model-selector-input']")
          if (!this.input) return

          this.filter = () => {
            const query = this.input.value.trim().toLowerCase()
            let matched = 0
            for (const item of this.el.querySelectorAll("[data-slot='model-selector-item']")) {
              const value = (item.dataset.value || item.textContent || "").toLowerCase()
              const hit = query === "" || value.includes(query)
              item.hidden = !hit
              if (hit) matched += 1
            }
            for (const group of this.el.querySelectorAll("[data-slot='model-selector-group']")) {
              const items = [...group.querySelectorAll("[data-slot='model-selector-item']")]
              group.hidden = items.length > 0 && items.every((item) => item.hidden)
            }
            for (const empty of this.el.querySelectorAll("[data-slot='model-selector-empty']")) {
              empty.hidden = matched > 0
            }
          }

          this.input.addEventListener("input", this.filter)
          this.el.addEventListener("toggle", this.filter)
          this.filter()
        },

        destroyed() {
          if (this.input) this.input.removeEventListener("input", this.filter)
          this.el.removeEventListener("toggle", this.filter)
        },
      }
    </script>
    """
  end

  @doc "Opens the model selector."
  attr :id, :string, default: nil
  attr :panel, :string, required: true, doc: "the `model_selector/1` id"
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled)
  slot :inner_block, required: true

  def model_selector_trigger(assigns) do
    ~H"""
    <.prompt_input_button
      id={@id}
      size={:sm}
      popovertarget={@panel}
      popovertargetaction="toggle"
      class={@class}
      {@rest}
    >
      {render_slot(@inner_block)}
      <UI.icon name="chevron-up-down" class="size-4 shrink-0 text-muted-foreground" />
    </.prompt_input_button>
    """
  end

  @doc "The panel's search field."
  attr :id, :string, default: nil
  attr :placeholder, :string, default: "Search models..."
  attr :class, :any, default: nil
  attr :rest, :global

  def model_selector_input(assigns) do
    ~H"""
    <div class="flex items-center gap-2 border-b border-border px-3">
      <UI.icon name="magnifying-glass-search" class="size-4 shrink-0 text-muted-foreground" />
      <input
        id={@id}
        type="text"
        role="combobox"
        aria-expanded="true"
        aria-label={@placeholder}
        autocomplete="off"
        placeholder={@placeholder}
        data-slot="model-selector-input"
        class={[
          "h-auto flex-1 border-0 bg-transparent py-3.5 text-sm outline-none",
          "placeholder:text-muted-foreground",
          @class
        ]}
        {@rest}
      />
    </div>
    """
  end

  @doc "The scrolling list of models."
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def model_selector_list(assigns) do
    ~H"""
    <div
      id={@id}
      role="listbox"
      class={["max-h-72 scroll-py-1 overflow-y-auto overflow-x-hidden p-1", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "Shown when the search matches nothing."
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block

  def model_selector_empty(assigns) do
    ~H"""
    <div
      id={@id}
      data-slot="model-selector-empty"
      class={["py-6 text-center text-muted-foreground text-sm", @class]}
      {@rest}
    >
      <%= if @inner_block != [] do %>
        {render_slot(@inner_block)}
      <% else %>
        No models found.
      <% end %>
    </div>
    """
  end

  @doc "A named run of models, such as one provider's."
  attr :id, :string, default: nil
  attr :heading, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def model_selector_group(assigns) do
    ~H"""
    <div
      id={@id}
      role="group"
      aria-label={@heading}
      data-slot="model-selector-group"
      class={["overflow-hidden p-1 text-foreground", @class]}
      {@rest}
    >
      <div :if={@heading} class="px-2 py-1.5 font-medium text-muted-foreground text-xs">
        {@heading}
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  One model.

  `value` is what the filter hook matches against, so give it whatever a reader
  would type: the model's name, its provider, or both.
  """
  attr :id, :string, default: nil
  attr :value, :string, required: true
  attr :selected, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled form name)
  slot :inner_block, required: true

  def model_selector_item(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      role="option"
      aria-selected={to_string(@selected)}
      data-slot="model-selector-item"
      data-value={@value}
      class={[command_item(), @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc "A model's name, filling the row between its logo and its shortcut."
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def model_selector_name(assigns) do
    ~H"""
    <span class={["flex-1 truncate text-left", @class]} {@rest}>{render_slot(@inner_block)}</span>
    """
  end

  @doc "A keyboard shortcut, stated at the trailing edge of a row."
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def model_selector_shortcut(assigns) do
    ~H"""
    <span class={["ml-auto text-muted-foreground text-xs tracking-widest", @class]} {@rest}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc "A rule between groups."
  attr :class, :any, default: nil
  attr :rest, :global

  def model_selector_separator(assigns) do
    ~H"""
    <div role="separator" class={["-mx-1 h-px bg-border", @class]} {@rest}></div>
    """
  end

  @doc """
  A provider's mark.

  The source builds the URL from a provider name against `models.dev`. This
  takes `src` instead: a component in this app does not decide which host the
  page fetches from. `dark:invert` is dropped for the reason in the module
  note — the variant never matches here.
  """
  attr :src, :string, required: true
  attr :provider, :string, required: true, doc: "used for the alternative text"
  attr :class, :any, default: nil
  attr :rest, :global

  def model_selector_logo(assigns) do
    ~H"""
    <img
      src={@src}
      alt={"#{@provider} logo"}
      width="12"
      height="12"
      class={["size-3", @class]}
      {@rest}
    />
    """
  end

  @doc "Overlapping provider marks, for a model several providers serve."
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def model_selector_logo_group(assigns) do
    ~H"""
    <div
      class={[
        "flex shrink-0 items-center -space-x-1",
        "[&>img]:rounded-full [&>img]:bg-background [&>img]:p-px [&>img]:ring-1",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  # ── Queue ─────────────────────────────────────────────────────────────────

  @doc "Messages waiting to be sent, held below the composer."
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def queue(assigns) do
    ~H"""
    <div
      id={@id}
      data-slot="queue"
      class={[
        "flex flex-col gap-2 rounded-xl border border-border bg-background px-3 pt-2 pb-2 shadow-xs",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  A collapsible run of queued items.

  A native `<details>`, so the disclosure works before any JavaScript loads.
  The chevron in `queue_section_label/1` rotates off this element's `open`
  attribute rather than off Radix's `data-state`.
  """
  attr :id, :string, default: nil
  attr :open, :boolean, default: true
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def queue_section(assigns) do
    ~H"""
    <details id={@id} open={@open} class={["group/queue-section", @class]} {@rest}>
      {render_slot(@inner_block)}
    </details>
    """
  end

  @doc "The section's header, which opens and closes it."
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def queue_section_trigger(assigns) do
    ~H"""
    <summary
      class={[
        "group flex w-full cursor-pointer list-none items-center justify-between rounded-md",
        "bg-muted/40 px-3 py-2 text-left font-medium text-muted-foreground text-sm",
        "transition-colors hover:bg-muted [&::-webkit-details-marker]:hidden",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </summary>
    """
  end

  @doc "The section header's own content: a chevron, a count, and a word."
  attr :label, :string, required: true
  attr :count, :integer, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :icon

  def queue_section_label(assigns) do
    ~H"""
    <span class={["flex items-center gap-2", @class]} {@rest}>
      <UI.icon
        name="chevron-down"
        class="size-4 -rotate-90 transition-transform group-open/queue-section:rotate-0"
      />
      {render_slot(@icon)}
      <span>{[@count, @label] |> Enum.reject(&is_nil/1) |> Enum.join(" ")}</span>
    </span>
    """
  end

  @doc "What the section reveals."
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def queue_section_content(assigns) do
    ~H"""
    <div class={@class} {@rest}>{render_slot(@inner_block)}</div>
    """
  end

  @doc "The bounded scrolling list of queued items."
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def queue_list(assigns) do
    ~H"""
    <div id={@id} class={["-mb-1 mt-2 overflow-y-auto", @class]} {@rest}>
      <div class="max-h-40 pr-4">
        <ul>{render_slot(@inner_block)}</ul>
      </div>
    </div>
    """
  end

  @doc "One queued message."
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def queue_item(assigns) do
    ~H"""
    <li
      id={@id}
      class={[
        "group/queue-item flex flex-col gap-1 rounded-md px-3 py-1 text-sm",
        "transition-colors hover:bg-muted",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </li>
    """
  end

  @doc "The dot that says whether a queued item has been sent."
  attr :completed, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global

  def queue_item_indicator(assigns) do
    ~H"""
    <span
      aria-hidden="true"
      class={[
        "mt-0.5 inline-block size-2.5 rounded-full border",
        if(@completed,
          do: "border-muted-foreground/20 bg-muted-foreground/10",
          else: "border-muted-foreground/50"
        ),
        @class
      ]}
      {@rest}
    ></span>
    """
  end

  @doc "The queued message's text."
  attr :completed, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def queue_item_content(assigns) do
    ~H"""
    <span
      class={[
        "line-clamp-1 grow break-words",
        if(@completed, do: "text-muted-foreground/50 line-through", else: "text-muted-foreground"),
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc "Supporting text under a queued message."
  attr :completed, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def queue_item_description(assigns) do
    ~H"""
    <div
      class={[
        "ml-6 text-xs",
        if(@completed, do: "text-muted-foreground/40 line-through", else: "text-muted-foreground"),
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "Controls on a queued item."
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def queue_item_actions(assigns) do
    ~H"""
    <div class={["flex gap-1", @class]} {@rest}>{render_slot(@inner_block)}</div>
    """
  end

  @doc """
  One control on a queued item.

  Revealed on hover in the source. `focus-visible` reveals it as well, because
  a hover-only reveal is a control the keyboard can reach but never see.
  """
  attr :id, :string, default: nil
  attr :label, :string, required: true
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled form name value)
  slot :inner_block, required: true

  def queue_item_action(assigns) do
    ~H"""
    <UI.button
      id={@id}
      type="button"
      variant={:ghost}
      aria-label={@label}
      class={[
        "size-auto rounded p-1 text-muted-foreground opacity-0 transition-opacity",
        "hover:bg-muted-foreground/10 hover:text-foreground",
        "group-hover/queue-item:opacity-100 focus-visible:opacity-100",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </UI.button>
    """
  end

  @doc "The strip of things attached to a queued message."
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def queue_item_attachment(assigns) do
    ~H"""
    <div class={["mt-1 flex flex-wrap gap-2", @class]} {@rest}>{render_slot(@inner_block)}</div>
    """
  end

  @doc "An image attached to a queued message."
  attr :src, :string, required: true
  attr :alt, :string, default: ""
  attr :class, :any, default: nil
  attr :rest, :global

  def queue_item_image(assigns) do
    ~H"""
    <img
      src={@src}
      alt={@alt}
      width="32"
      height="32"
      class={["h-8 w-8 rounded border object-cover", @class]}
      {@rest}
    />
    """
  end

  @doc "A file attached to a queued message."
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def queue_item_file(assigns) do
    ~H"""
    <span
      class={["flex items-center gap-1 rounded border bg-muted px-2 py-1 text-xs", @class]}
      {@rest}
    >
      <UI.icon name="paperclip" class="size-3" />
      <span class="max-w-[100px] truncate">{render_slot(@inner_block)}</span>
    </span>
    """
  end

  @doc """
  What stands in for the queue when nothing is waiting.

  AI Elements has no such part — its queue simply renders no items. An empty
  region with no words leaves a reader unsure whether anything was queued at
  all, so this states the condition, following `attachment_empty/1`.
  """
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block

  def queue_empty(assigns) do
    ~H"""
    <div
      id={@id}
      data-slot="queue-empty"
      class={["flex items-center justify-center px-3 py-4 text-muted-foreground text-sm", @class]}
      {@rest}
    >
      <%= if @inner_block != [] do %>
        {render_slot(@inner_block)}
      <% else %>
        Nothing queued
      <% end %>
    </div>
    """
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp button_size_class(:xs) do
    "h-6 gap-1 rounded-[calc(var(--radius)-5px)] px-2 has-[>svg]:px-2 " <>
      "[&>svg:not([class*='size-'])]:size-3.5"
  end

  defp button_size_class(:sm), do: "h-8 gap-1.5 rounded-md px-2.5 has-[>svg]:px-2.5"

  defp button_size_class(:icon_xs),
    do: "size-6 rounded-[calc(var(--radius)-5px)] p-0 has-[>svg]:p-0"

  defp button_size_class(:icon_sm), do: "size-8 p-0 has-[>svg]:p-0"

  defp media_icon(:image), do: "image-square"
  defp media_icon(:video), do: "video"
  defp media_icon(:audio), do: "music"
  defp media_icon(:document), do: "file-document"
  defp media_icon(:source), do: "globe"
  defp media_icon(_unknown), do: "paperclip"

  defp input_group, do: @input_group
  defp addon, do: @addon
  defp button_base, do: @button_base
  defp command_item, do: @command_item
end
