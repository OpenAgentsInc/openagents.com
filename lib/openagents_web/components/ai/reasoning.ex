defmodule OpenAgentsWeb.AI.Reasoning do
  @moduledoc """
  The agent's visible thinking and work, ported from Vercel's AI Elements.

  Six AI Elements files land here as one module: `reasoning`, `chain-of-thought`,
  `tool`, `task`, `plan`, and `checkpoint`. They belong together because they
  answer one question for the reader — what is the agent doing right now, and
  what did it already do. Their Tailwind classes are carried across as written
  so the harvested surface still reads as AI Elements; only tokens our theme
  names differently, and utilities our bundle does not ship, are substituted.
  Each substitution carries a comment at its call site.

  ## Compound components become siblings, except `plan/1`

  React expresses these as compound components sharing a context. HEEx has no
  context, so five of the six become sibling function components that a caller
  nests by hand, with the state React kept in context passed as explicit
  attributes (`streaming`, `duration`, `state`). That keeps the AI Elements call
  shape and makes the state the LiveView owns visible at the call site.

  `plan/1` is the exception and takes slots. Its footer must stay visible while
  its content collapses, and a `<details>` element hides every child that is not
  its `<summary>`. Only the parent can place a child outside the collapsing
  region, so the parent has to know about the parts.

  ## Collapsing without React

  Radix `Collapsible` backs `reasoning`, `tool`, `task`, `chain-of-thought`, and
  `plan` upstream. All five use `<details>`/`<summary>` here — one mechanism for
  the whole batch. `<details>` needs no JavaScript, no client state library, and
  no hook; the browser supplies the disclosure semantics, the implicit
  `aria-expanded`, and keyboard operation. The server writes the initial state
  through the `open` attribute, so "auto-open while streaming, collapse when
  done" stays a LiveView decision: pass `open={@streaming}` and re-render.

  Two consequences are worth knowing. A reader who toggles a `<details>` owns it
  until the next server render of that attribute, exactly as an uncontrolled
  Radix collapsible behaves. And `data-[state=open]` from the source becomes the
  `open` variant, since `<details>` carries a real `open` attribute.

  ## Markdown

  `reasoning_content/1` renders through `OpenAgents.Markdown.to_html/2` where
  AI Elements renders `<Streamdown>`. Pass `streaming` while the text is still
  arriving so the renderer completes unbalanced markup.
  """
  use OpenAgentsWeb, :html

  @tool_states ~w(
    input-streaming input-available output-available output-error
    approval-requested approval-responded output-denied
  )

  # Shared summary treatment. `<summary>` is `display: list-item` by default,
  # which paints a disclosure triangle; `flex` removes it in Chrome and Firefox
  # and the WebKit pseudo-element rule removes it in Safari. A function rather
  # than a module attribute, because `@name` inside `~H` reads an assign.
  defp summary_class, do: "cursor-pointer list-none [&::-webkit-details-marker]:hidden"

  @doc """
  A collapsible block of model reasoning.

  Wraps `reasoning_trigger/1` and `reasoning_content/1`. Give `open` from the
  LiveView: AI Elements opens itself while `isStreaming` is true and closes a
  second after it turns false, which is state a server render already holds.

      <.reasoning id="turn-7-reasoning" open={@streaming}>
        <.reasoning_trigger streaming={@streaming} duration={@thought_seconds} />
        <.reasoning_content text={@reasoning_text} streaming={@streaming} />
      </.reasoning>
  """
  attr :id, :string, default: nil
  attr :open, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def reasoning(assigns) do
    ~H"""
    <%!-- Source: "not-prose mb-4". `not-prose` needs the typography plugin,
    which this bundle does not load, so it is dropped. `group` is added so the
    trigger's chevron can key off the parent's open state. --%>
    <details id={@id} class={["group mb-4", @class]} open={@open} {@rest}>
      {render_slot(@inner_block)}
    </details>
    """
  end

  @doc """
  The reasoning disclosure control and its elapsed-duration label.

  With no `inner_block`, renders the AI Elements default: a brain glyph, the
  thinking message, and a chevron that flips when the block opens. The message
  reads "Thinking..." while `streaming`, then "Thought for N seconds" once
  `duration` is known, and "Thought for a few seconds" when it is not.
  """
  attr :id, :string, default: nil
  attr :streaming, :boolean, default: false
  attr :duration, :integer, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block

  def reasoning_trigger(assigns) do
    ~H"""
    <summary
      id={@id}
      class={[
        "flex w-full items-center gap-2 text-muted-foreground text-sm transition-colors hover:text-foreground",
        summary_class(),
        @class
      ]}
      {@rest}
    >
      <%= if @inner_block != [] do %>
        {render_slot(@inner_block)}
      <% else %>
        <%!-- lucide BrainIcon -> Apps SDK `brain`. --%>
        <.icon name="brain" class="size-4" />
        <%!-- Source wraps the streaming label in <Shimmer>, a masked gradient
        sweep from an AI Elements file outside this batch. `animate-pulse` is the
        nearest utility this bundle ships. --%>
        <p class={["m-0", (@streaming || @duration == 0) && "animate-pulse"]}>
          {thinking_message(@streaming, @duration)}
        </p>
        <%!-- lucide ChevronDownIcon -> Apps SDK `chevron-down`. `data-[state=open]`
        becomes the `open` variant, which `<details>` supplies natively. --%>
        <.icon
          name="chevron-down"
          class="size-4 transition-transform rotate-0 group-open:rotate-180"
        />
      <% end %>
    </summary>
    """
  end

  defp thinking_message(streaming, duration) when streaming or duration == 0, do: "Thinking..."
  defp thinking_message(_streaming, nil), do: "Thought for a few seconds"
  defp thinking_message(_streaming, duration), do: "Thought for #{duration} seconds"

  @doc """
  The reasoning text, rendered as markdown.

  Pass `streaming` while the text is still arriving so partial markup completes.
  """
  attr :id, :string, default: nil
  attr :text, :string, required: true
  attr :streaming, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global

  def reasoning_content(assigns) do
    ~H"""
    <%!-- Source adds enter/exit animation utilities from tailwindcss-animate
    (`data-[state=open]:animate-in`, `slide-in-from-top-2`, `fade-out-0`). That
    plugin is not in this bundle, so the animation classes are dropped and the
    disclosure is instant. --%>
    <div
      id={@id}
      class={["mt-4 text-sm text-muted-foreground outline-none", @class]}
      {@rest}
    >
      {OpenAgents.Markdown.to_html(@text, streaming: @streaming)}
    </div>
    """
  end

  @doc """
  A collapsible chain-of-thought trace.

  Upstream this is a plain `<div>` holding two separate Radix collapsibles that
  share one context, so the header and the content can be siblings in the DOM.
  A single `<details>` expresses the same thing with one element, so this port
  collapses the pair: put `chain_of_thought_header/1` and
  `chain_of_thought_content/1` directly inside.
  """
  attr :id, :string, default: nil
  attr :open, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def chain_of_thought(assigns) do
    ~H"""
    <%!-- Source: "not-prose w-full space-y-4". `not-prose` dropped (no
    typography plugin); `group` added for the chevron. --%>
    <details id={@id} class={["group w-full space-y-4", @class]} open={@open} {@rest}>
      {render_slot(@inner_block)}
    </details>
    """
  end

  @doc """
  The chain-of-thought disclosure control. Defaults to the label "Chain of thought".
  """
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block

  def chain_of_thought_header(assigns) do
    ~H"""
    <summary
      id={@id}
      class={[
        "flex w-full items-center gap-2 text-muted-foreground text-sm transition-colors hover:text-foreground",
        summary_class(),
        @class
      ]}
      {@rest}
    >
      <.icon name="brain" class="size-4" />
      <span class="flex-1 text-left">
        <%= if @inner_block != [] do %>
          {render_slot(@inner_block)}
        <% else %>
          Chain of thought
        <% end %>
      </span>
      <.icon name="chevron-down" class="size-4 transition-transform rotate-0 group-open:rotate-180" />
    </summary>
    """
  end

  @doc """
  The body of a chain-of-thought trace. Holds `chain_of_thought_step/1` elements.
  """
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def chain_of_thought_content(assigns) do
    ~H"""
    <%!-- Enter/exit animation utilities dropped: see reasoning_content/1. --%>
    <div id={@id} class={["mt-2 space-y-3 text-popover-foreground outline-none", @class]} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  One step in a chain of thought.

  `status` dims the step: `:active` is the step being worked, `:complete` is
  behind it, and `:pending` is ahead of it.
  """
  attr :id, :string, default: nil
  attr :icon, :string, default: "dot"
  attr :label, :string, required: true
  attr :description, :string, default: nil
  attr :status, :atom, values: [:complete, :active, :pending], default: :complete
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block

  def chain_of_thought_step(assigns) do
    ~H"""
    <%!-- Source also carries "fade-in-0 slide-in-from-top-2 animate-in"; dropped
    with the rest of the tailwindcss-animate utilities. --%>
    <div id={@id} class={["flex gap-2 text-sm", step_status_class(@status), @class]} {@rest}>
      <div class="relative mt-0.5">
        <.icon name={@icon} class="size-4" />
        <div class="absolute top-7 bottom-0 left-1/2 -mx-px w-px bg-border"></div>
      </div>
      <div class="flex-1 space-y-2 overflow-hidden">
        <div>{@label}</div>
        <div :if={@description} class="text-muted-foreground text-xs">{@description}</div>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  defp step_status_class(:active), do: "text-foreground"
  defp step_status_class(:complete), do: "text-muted-foreground"
  defp step_status_class(:pending), do: "text-muted-foreground/50"

  @doc """
  A row of search results found during a step.
  """
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def chain_of_thought_search_results(assigns) do
    ~H"""
    <div id={@id} class={["flex flex-wrap items-center gap-2", @class]} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  One search result inside `chain_of_thought_search_results/1`.
  """
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def chain_of_thought_search_result(assigns) do
    ~H"""
    <%!-- Source uses shadcn Badge variant="secondary"; `UI.badge/1` is the
    equivalent primitive here and `:dim` is its quiet variant. --%>
    <.badge id={@id} variant={:dim} class={["gap-1 px-2 py-0.5 font-normal text-xs", @class]} {@rest}>
      {render_slot(@inner_block)}
    </.badge>
    """
  end

  @doc """
  An image produced during a step, with an optional caption.
  """
  attr :id, :string, default: nil
  attr :caption, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def chain_of_thought_image(assigns) do
    ~H"""
    <div id={@id} class={["mt-2 space-y-2", @class]} {@rest}>
      <div class="relative flex max-h-[22rem] items-center justify-center overflow-hidden rounded-lg bg-muted p-3">
        {render_slot(@inner_block)}
      </div>
      <p :if={@caption} class="text-muted-foreground text-xs">{@caption}</p>
    </div>
    """
  end

  @doc """
  A collapsible record of one tool call.

  Wraps `tool_header/1`, then `tool_content/1` holding `tool_input/1` and
  `tool_output/1`.
  """
  attr :id, :string, default: nil
  attr :open, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def tool(assigns) do
    ~H"""
    <%!-- Source: "group not-prose mb-4 w-full rounded-md border". `not-prose`
    dropped (no typography plugin). --%>
    <details id={@id} class={["group mb-4 w-full rounded-md border", @class]} open={@open} {@rest}>
      {render_slot(@inner_block)}
    </details>
    """
  end

  @doc """
  The tool disclosure control: the tool's name and its current state.

  `type` is the AI SDK part type. `tool-getWeather` displays as `getWeather`;
  `dynamic-tool` displays `tool_name`. `title` overrides both.
  """
  attr :id, :string, default: nil
  attr :title, :string, default: nil
  attr :type, :string, required: true
  attr :tool_name, :string, default: nil
  attr :state, :string, values: @tool_states, required: true
  attr :class, :any, default: nil
  attr :rest, :global

  def tool_header(assigns) do
    ~H"""
    <summary
      id={@id}
      class={["flex w-full items-center justify-between gap-4 p-3", summary_class(), @class]}
      {@rest}
    >
      <div class="flex items-center gap-2">
        <%!-- lucide WrenchIcon -> Apps SDK `tools`, which is a wrench. --%>
        <.icon name="tools" class="size-4 text-muted-foreground" />
        <span class="font-medium text-sm">{tool_display_name(@title, @type, @tool_name)}</span>
        <.tool_status_badge state={@state} />
      </div>
      <.icon
        name="chevron-down"
        class="size-4 text-muted-foreground transition-transform group-open:rotate-180"
      />
    </summary>
    """
  end

  defp tool_display_name(title, _type, _tool_name) when is_binary(title), do: title
  defp tool_display_name(_title, "dynamic-tool", tool_name), do: tool_name

  defp tool_display_name(_title, type, _tool_name) do
    type |> String.split("-") |> Enum.drop(1) |> Enum.join("-")
  end

  @doc """
  The state of a tool call, as a labelled badge.

  Upstream this is a neutral badge whose glyph carries the colour. `UI.badge/1`
  colours the whole badge instead, which is this product's rule — semantic
  colour reinforces the words rather than sitting beside them — so the glyph
  inherits `currentColor` and the per-icon colour classes are dropped.
  """
  attr :id, :string, default: nil
  attr :state, :string, values: @tool_states, required: true
  attr :class, :any, default: nil
  attr :rest, :global

  def tool_status_badge(assigns) do
    ~H"""
    <.badge
      id={@id}
      variant={tool_state_variant(@state)}
      class={["gap-1.5 rounded-full text-xs", @class]}
      {@rest}
    >
      <.icon
        name={tool_state_icon(@state)}
        class={["size-4", @state == "input-available" && "animate-pulse"]}
      />
      {tool_state_label(@state)}
    </.badge>
    """
  end

  defp tool_state_label("approval-requested"), do: "Awaiting approval"
  defp tool_state_label("approval-responded"), do: "Responded"
  defp tool_state_label("input-available"), do: "Running"
  defp tool_state_label("input-streaming"), do: "Pending"
  defp tool_state_label("output-available"), do: "Completed"
  defp tool_state_label("output-denied"), do: "Denied"
  defp tool_state_label("output-error"), do: "Error"

  # lucide ClockIcon -> `clock`, CircleIcon -> `empty-circle`,
  # CheckCircleIcon -> `check-circle`, XCircleIcon -> `x-circle`.
  defp tool_state_icon("approval-requested"), do: "clock"
  defp tool_state_icon("approval-responded"), do: "check-circle"
  defp tool_state_icon("input-available"), do: "clock"
  defp tool_state_icon("input-streaming"), do: "empty-circle"
  defp tool_state_icon("output-available"), do: "check-circle"
  defp tool_state_icon("output-denied"), do: "x-circle"
  defp tool_state_icon("output-error"), do: "x-circle"

  defp tool_state_variant("approval-requested"), do: :warning
  defp tool_state_variant("approval-responded"), do: :info
  defp tool_state_variant("input-available"), do: :info
  defp tool_state_variant("input-streaming"), do: :dim
  defp tool_state_variant("output-available"), do: :success
  defp tool_state_variant("output-denied"), do: :warning
  defp tool_state_variant("output-error"), do: :danger

  @doc """
  The body of a tool call. Holds `tool_input/1` and `tool_output/1`.
  """
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def tool_content(assigns) do
    ~H"""
    <%!-- Enter/exit animation utilities dropped: see reasoning_content/1. --%>
    <div id={@id} class={["space-y-4 p-4 text-popover-foreground outline-none", @class]} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  The parameters a tool was called with, as formatted JSON.
  """
  attr :id, :string, default: nil
  attr :input, :string, required: true
  attr :class, :any, default: nil
  attr :rest, :global

  def tool_input(assigns) do
    ~H"""
    <div id={@id} class={["space-y-2 overflow-hidden", @class]} {@rest}>
      <h4 class="font-medium text-muted-foreground text-xs uppercase tracking-wide">Parameters</h4>
      <div class="rounded-md bg-muted/50">
        <.ai_code_block code={@input} />
      </div>
    </div>
    """
  end

  @doc """
  What a tool returned, or the error it raised.

  Renders nothing when neither `output` nor `error_text` is set, matching the
  upstream early return.
  """
  attr :id, :string, default: nil
  attr :output, :string, default: nil
  attr :error_text, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  def tool_output(assigns) do
    ~H"""
    <div :if={@output || @error_text} id={@id} class={["space-y-2", @class]} {@rest}>
      <h4 class="font-medium text-muted-foreground text-xs uppercase tracking-wide">
        {if @error_text, do: "Error", else: "Result"}
      </h4>
      <div class={[
        "overflow-x-auto rounded-md text-xs [&_table]:w-full",
        if(@error_text,
          do: "bg-destructive/10 text-destructive",
          else: "bg-muted/50 text-foreground"
        )
      ]}>
        <div :if={@error_text}>{@error_text}</div>
        <.ai_code_block :if={@output} code={@output} />
      </div>
    </div>
    """
  end

  # AI Elements renders tool payloads through its own `CodeBlock`, which is not
  # in this batch. Until that port lands, a preformatted block carries the same
  # shape without claiming syntax highlighting it does not do.
  attr :code, :string, required: true

  defp ai_code_block(assigns) do
    ~H"""
    <pre class="overflow-x-auto p-4 font-mono text-xs"><code>{@code}</code></pre>
    """
  end

  @doc """
  A collapsible record of one piece of agent work.

  Open by default, as upstream. Wraps `task_trigger/1` and `task_content/1`.
  """
  attr :id, :string, default: nil
  attr :open, :boolean, default: true
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def task(assigns) do
    ~H"""
    <details id={@id} class={["group", @class]} open={@open} {@rest}>
      {render_slot(@inner_block)}
    </details>
    """
  end

  @doc """
  The task disclosure control, showing what the task is.
  """
  attr :id, :string, default: nil
  attr :title, :string, required: true
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block

  def task_trigger(assigns) do
    ~H"""
    <%!-- Upstream renders `CollapsibleTrigger asChild` around a <div>, so the
    trigger element is the child. `<summary>` is already the trigger, so the
    wrapper and its child merge into one element. --%>
    <summary
      id={@id}
      class={[
        "flex w-full items-center gap-2 text-muted-foreground text-sm transition-colors hover:text-foreground",
        summary_class(),
        @class
      ]}
      {@rest}
    >
      <%= if @inner_block != [] do %>
        {render_slot(@inner_block)}
      <% else %>
        <%!-- lucide SearchIcon -> Apps SDK `search`. --%>
        <.icon name="search" class="size-4" />
        <p class="m-0 text-sm">{@title}</p>
        <.icon name="chevron-down" class="size-4 transition-transform group-open:rotate-180" />
      <% end %>
    </summary>
    """
  end

  @doc """
  The list of things a task did. Holds `task_item/1` elements.
  """
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def task_content(assigns) do
    ~H"""
    <%!-- Enter/exit animation utilities dropped: see reasoning_content/1. --%>
    <div id={@id} class={["text-popover-foreground outline-none", @class]} {@rest}>
      <div class="mt-4 space-y-2 border-muted border-l-2 pl-4">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  One line of task work.
  """
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def task_item(assigns) do
    ~H"""
    <div id={@id} class={["text-muted-foreground text-sm", @class]} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  A file named inside a task item.
  """
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def task_item_file(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "inline-flex items-center gap-1 rounded-md border bg-secondary px-1.5 py-0.5 text-foreground text-xs",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  A plan the agent intends to follow, on a card whose body collapses.

  This is the one part of the batch that takes slots rather than siblings. Its
  footer stays visible while its body collapses, and `<details>` hides every
  child but the `<summary>`, so the parent has to place the footer outside the
  collapsing region.

      <.plan id="build-plan" open streaming={@streaming}>
        <:header>
          <div>
            <.plan_title streaming={@streaming}>Ship the parser</.plan_title>
            <.plan_description streaming={@streaming}>Four steps.</.plan_description>
          </div>
          <.plan_trigger />
        </:header>
        <.task id="plan-step-1">...</.task>
        <:footer><.button variant={:primary}>Approve</.button></:footer>
      </.plan>
  """
  attr :id, :string, default: nil
  attr :open, :boolean, default: true
  attr :streaming, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global
  slot :header, required: true
  slot :footer
  slot :inner_block, required: true

  def plan(assigns) do
    ~H"""
    <.card id={@id} class={["shadow-none", @class]} {@rest}>
      <details class="group" open={@open}>
        <summary
          class={["flex items-start justify-between gap-2 px-6 py-4", summary_class()]}
          data-slot="plan-header"
        >
          {render_slot(@header)}
        </summary>
        <div class="px-6 pb-4" data-slot="plan-content">{render_slot(@inner_block)}</div>
      </details>
      <div :if={@footer != []} class="flex items-center gap-2 px-6 pb-4" data-slot="plan-footer">
        {render_slot(@footer)}
      </div>
    </.card>
    """
  end

  @doc """
  The name of a plan. Shimmers while `streaming`.
  """
  attr :id, :string, default: nil
  attr :streaming, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def plan_title(assigns) do
    ~H"""
    <%!-- shadcn CardTitle is "leading-none font-semibold". <Shimmer> is not in
    this batch; `animate-pulse` stands in, as in reasoning_trigger/1. --%>
    <h3
      id={@id}
      class={["leading-none font-semibold", @streaming && "animate-pulse", @class]}
      data-slot="plan-title"
      {@rest}
    >
      {render_slot(@inner_block)}
    </h3>
    """
  end

  @doc """
  What a plan is for. Shimmers while `streaming`.
  """
  attr :id, :string, default: nil
  attr :streaming, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def plan_description(assigns) do
    ~H"""
    <%!-- shadcn CardDescription is "text-muted-foreground text-sm". --%>
    <p
      id={@id}
      class={[
        "text-balance text-muted-foreground text-sm",
        @streaming && "animate-pulse",
        @class
      ]}
      data-slot="plan-description"
      {@rest}
    >
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  A control that sits in a plan header, opposite the title.
  """
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def plan_action(assigns) do
    ~H"""
    <div id={@id} class={["ml-auto", @class]} data-slot="plan-action" {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  The affordance that shows a plan header can be opened and closed.

  Upstream this is a ghost icon button and the Radix trigger. Here the whole
  `<summary>` is the control, so a nested button would be a second interactive
  element inside it; this renders the glyph only. The screen-reader text is kept
  so the summary still says what activating it does.
  """
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  def plan_trigger(assigns) do
    ~H"""
    <span
      id={@id}
      class={[
        "inline-flex size-8 shrink-0 items-center justify-center rounded-md text-muted-foreground",
        @class
      ]}
      data-slot="plan-trigger"
      {@rest}
    >
      <%!-- lucide ChevronsUpDownIcon -> Apps SDK `chevron-up-down`. --%>
      <.icon name="chevron-up-down" class="size-4" />
      <span class="sr-only">Toggle plan</span>
    </span>
    """
  end

  @doc """
  A marked point in a conversation that can be returned to.

  The trailing rule fills whatever width the controls leave.
  """
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def checkpoint(assigns) do
    ~H"""
    <div
      id={@id}
      class={["flex items-center gap-0.5 overflow-hidden text-muted-foreground", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
      <%!-- shadcn Separator, which is decorative and announces nothing. --%>
      <hr class="h-px flex-1 border-0 bg-border" />
    </div>
    """
  end

  @doc """
  The glyph that marks a checkpoint.
  """
  attr :id, :string, default: nil
  attr :name, :string, default: "saved-xs"
  attr :class, :any, default: nil
  attr :rest, :global

  def checkpoint_icon(assigns) do
    ~H"""
    <%!-- lucide BookmarkIcon -> Apps SDK `saved-xs`, the vendored bookmark. --%>
    <.icon id={@id} name={@name} class={["size-4 shrink-0", @class]} {@rest} />
    """
  end

  @doc """
  A control on a checkpoint, such as restoring it.

  Upstream wraps the button in a Radix tooltip. Radix is not available, so
  `tooltip` becomes the native `title` attribute: same text, no JavaScript, and
  it still reaches assistive technology.
  """
  attr :id, :string, default: nil
  attr :tooltip, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def checkpoint_trigger(assigns) do
    ~H"""
    <.button id={@id} variant={:ghost} size={:sm} title={@tooltip} class={@class} {@rest}>
      {render_slot(@inner_block)}
    </.button>
    """
  end
end
