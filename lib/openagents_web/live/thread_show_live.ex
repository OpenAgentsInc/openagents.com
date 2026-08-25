defmodule OpenAgentsWeb.ThreadShowLive do
  @moduledoc """
  One thread's transcript, read-only, live.

  Private by default: an unknown id and another account's `dark` thread both
  raise the plain 404 (`OpenAgentsWeb.PublicNotFoundError`), matching how the
  API scopes the same read — existence is never confirmed to a reader the
  thread's transparency tier does not admit.

  A thread opened at a wider tier is readable here by any signed-in account
  holding its id, which is the audience this route can actually enforce: it
  sits in the `:authenticated` live session, so there is no anonymous reader to
  admit and none is invented. What the tier does not disclose is the owner's
  money — the budget card is the account's grant, and it renders for the owner
  only (THREAD-002).

  The snapshot-to-live order follows the projection protocol the issue names:
  subscribe to the thread's topic first, then read the snapshot, then let
  buffered broadcasts drain through `handle_info/2` with a monotonic
  `last_event_id` dedup, so an event is never dropped and never doubled.

  The event vocabulary renders typed — `turn.user`, `turn.reasoning`,
  `tool.ran`, `turn.assistant` — and every payload field is read defensively:
  the payloads are client-written and their shape is not pinned by the server,
  so a missing or oddly typed field degrades to the neutral raw row rather
  than crashing the view. Unknown event types take the raw row too.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgents.Inference.Pricing
  alias OpenAgents.Markdown
  alias OpenAgents.Threads

  # Transcript pages are capped at 50 by the context; forty pages bounds the
  # view at 2,000 events, which is past any measured session.
  @maximum_pages 40
  @bounded_json_characters 2_000

  @impl true
  def mount(%{"id" => thread_id}, _session, socket) do
    user = socket.assigns.current_user
    _reaped = Threads.reap_expired(user)

    case Threads.fetch_readable(user, thread_id) do
      :error ->
        raise OpenAgentsWeb.PublicNotFoundError, message: "thread not found"

      {:ok, thread, relation} ->
        # Attach the live subscriber before reading the snapshot: an append
        # that lands between the two arrives as a buffered message and is
        # deduped below by id, so the gap cannot lose an event.
        if connected?(socket), do: Threads.subscribe(thread)

        events = transcript(thread)
        owner? = relation == :owner

        {:ok,
         socket
         |> assign(:page_title, "Thread · OpenAgents")
         |> assign(:thread, thread)
         |> assign(:owner?, owner?)
         |> assign(:grant, owner? && Threads.latest_grant(thread))
         |> assign(:last_event_id, last_id(events))
         |> assign(:events_empty?, events == [])
         |> stream(:events, events)}
    end
  end

  @impl true
  def handle_info({:thread_event, event}, socket) do
    if event.id <= socket.assigns.last_event_id do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:last_event_id, event.id)
       |> assign(:events_empty?, false)
       |> update(:thread, fn thread -> %{thread | event_count: thread.event_count + 1} end)
       |> stream_insert(:events, event)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
    >
      <main id="thread-show" class="mx-auto w-full max-w-4xl space-y-6 px-4 py-10">
        <header class="space-y-3">
          <div class="flex flex-wrap items-center gap-3">
            <.badge variant={status_variant(@thread.status)}>{@thread.status}</.badge>
            <span class="font-mono text-xs text-muted-foreground">{@thread.id}</span>
          </div>
          <h1 class="text-2xl font-semibold tracking-tight">{@thread.objective}</h1>
          <dl
            id="thread-facts"
            class="flex flex-wrap gap-x-6 gap-y-1 text-sm text-muted-foreground"
          >
            <div class="flex gap-1.5">
              <dt>Model</dt>
              <%!-- To the catalog, where this lane's rates and the authority
              behind them are readable. The cost cell below says what this
              session spent; this says what a call on it costs. --%>
              <dd class="font-mono text-xs leading-5">
                <.link navigate={~p"/models"} id="thread-model-link" class="hover:underline">
                  {@thread.model}
                </.link>
              </dd>
            </div>
            <div class="flex gap-1.5">
              <dt>Reasoning</dt>
              <dd>{@thread.reasoning_effort}</dd>
            </div>
            <div class="flex gap-1.5">
              <dt>Permissions</dt>
              <dd>{@thread.permission_profile}</dd>
            </div>
            <div class="flex gap-1.5">
              <dt>Visibility</dt>
              <dd id="thread-visibility">{visibility_label(@thread.visibility)}</dd>
            </div>
            <div class="flex gap-1.5">
              <dt>Events</dt>
              <dd id="thread-event-count" class="tabular-nums">{@thread.event_count}</dd>
            </div>
            <div class="flex gap-1.5">
              <dt>Opened</dt>
              <dd><.time_ago at={@thread.started_at} /></dd>
            </div>
            <div :if={@thread.completed_at} class="flex gap-1.5">
              <dt>Completed</dt>
              <dd><.time_ago at={@thread.completed_at} /></dd>
            </div>
          </dl>
        </header>

        <.card :if={@grant} id="thread-budget" class="text-sm">
          <div class="flex flex-wrap gap-x-8 gap-y-2">
            <div>
              <div class="text-xs text-muted-foreground">Grant</div>
              <div>{@grant.status}</div>
            </div>
            <div>
              <div class="text-xs text-muted-foreground">Calls</div>
              <div class="tabular-nums">{@grant.call_count} / {ceiling(@grant.max_calls)}</div>
            </div>
            <div>
              <div class="text-xs text-muted-foreground">Tokens</div>
              <div class="tabular-nums">
                {grant_spent(@grant, "total_tokens")} / {ceiling(@grant.max_total_tokens)}
              </div>
            </div>
            <div>
              <div class="text-xs text-muted-foreground">Cost</div>
              <div id="thread-budget-cost" class="tabular-nums" data-basis={cost_basis(@grant)}>
                {cost_spent(@grant)} / {dollars(@grant.max_cost_microusd)}
              </div>
              <div
                :if={cost_basis(@grant) != "declared"}
                id="thread-budget-cost-note"
                class="text-xs text-muted-foreground"
              >
                {cost_note(cost_basis(@grant))}
              </div>
            </div>
            <div :if={@grant.expires_at}>
              <div class="text-xs text-muted-foreground">Expires</div>
              <div><.time_ago at={@grant.expires_at} /></div>
            </div>
          </div>
        </.card>

        <.card :if={@thread.report} id="thread-report" class="text-sm">
          <div class="mb-1 text-xs text-muted-foreground">Report</div>
          <div class="whitespace-pre-wrap">{@thread.report}</div>
        </.card>

        <section aria-label="Transcript" class="space-y-3">
          <.empty :if={@events_empty?} id="thread-transcript-empty" title="No events yet">
            The transcript fills as the thread works.
          </.empty>

          <div id="thread-events" phx-update="stream" class="space-y-3">
            <div :for={{dom_id, event} <- @streams.events} id={dom_id} data-kind={event.event_type}>
              <.event_row event={event} />
            </div>
          </div>
        </section>
      </main>
    </Layouts.app>
    """
  end

  # ── event rendering ──────────────────────────────────────────────────────

  # One transcript entry, dispatched on its type. Each typed clause reads its
  # payload defensively and falls back to the neutral raw row when the field
  # it renders around is missing, so a malformed payload degrades instead of
  # crashing the transcript.
  defp event_row(%{event: %{event_type: "turn.user"} = event} = assigns) do
    case text(event.payload) do
      nil ->
        raw_row(assigns)

      text ->
        assigns = assign(assigns, text: text, steered: steered?(event.payload))

        ~H"""
        <.card class="text-sm">
          <div class="mb-1 flex items-center gap-2 text-xs text-muted-foreground">
            <span class="font-medium text-foreground">You</span>
            <.badge :if={@steered} variant={:warning}>steered</.badge>
            <.time_ago at={@event.emitted_at} />
          </div>
          <div class="whitespace-pre-wrap">{@text}</div>
        </.card>
        """
    end
  end

  defp event_row(%{event: %{event_type: "turn.reasoning"} = event} = assigns) do
    case text(event.payload) do
      nil ->
        raw_row(assigns)

      text ->
        assigns = assign(assigns, text: text)

        ~H"""
        <details class="rounded-md border border-border">
          <summary class="cursor-pointer select-none px-3 py-2 text-xs text-muted-foreground">
            Reasoning · {String.length(@text)} chars · <.time_ago at={@event.emitted_at} />
          </summary>
          <div class="whitespace-pre-wrap border-t border-border px-3 py-2 text-sm text-muted-foreground">
            {@text}
          </div>
        </details>
        """
    end
  end

  defp event_row(%{event: %{event_type: "tool.ran"} = event} = assigns) do
    case string(event.payload, ["tool", "name"]) do
      nil ->
        raw_row(assigns)

      tool ->
        assigns =
          assign(assigns,
            tool: tool,
            tool_status: string(event.payload, ["status"]),
            arguments: bounded_json(Map.get(event.payload, "arguments")),
            result: bounded_json(Map.get(event.payload, "result"))
          )

        ~H"""
        <details class="rounded-md border border-border">
          <summary class="flex cursor-pointer select-none items-center gap-2 px-3 py-2 text-xs">
            <.kbd>{@tool}</.kbd>
            <.badge :if={@tool_status} variant={tool_status_variant(@tool_status)}>
              {@tool_status}
            </.badge>
            <span class="text-muted-foreground"><.time_ago at={@event.emitted_at} /></span>
          </summary>
          <div class="space-y-2 border-t border-border px-3 py-2 text-xs">
            <div :if={@arguments}>
              <div class="mb-1 text-muted-foreground">Arguments</div>
              <pre class="overflow-x-auto rounded-md bg-muted p-2 font-mono"><code phx-no-format>{@arguments}</code></pre>
            </div>
            <div :if={@result}>
              <div class="mb-1 text-muted-foreground">Result</div>
              <pre class="overflow-x-auto rounded-md bg-muted p-2 font-mono"><code phx-no-format>{@result}</code></pre>
            </div>
          </div>
        </details>
        """
    end
  end

  defp event_row(%{event: %{event_type: "turn.assistant"} = event} = assigns) do
    case text(event.payload) do
      nil ->
        raw_row(assigns)

      text ->
        assigns =
          assign(assigns,
            html: Markdown.to_html(text),
            usage: usage_line(event.payload)
          )

        ~H"""
        <.card class="text-sm">
          <div class="mb-1 flex items-center gap-2 text-xs text-muted-foreground">
            <span class="font-medium text-foreground">Assistant</span>
            <.time_ago at={@event.emitted_at} />
          </div>
          <div class="markdown space-y-2">{@html}</div>
          <div :if={@usage} class="mt-2 text-xs tabular-nums text-muted-foreground">{@usage}</div>
        </.card>
        """
    end
  end

  defp event_row(assigns), do: raw_row(assigns)

  # The neutral row: whatever the type, whatever the payload, it renders as
  # the recorded fact rather than crashing the transcript around it.
  defp raw_row(assigns) do
    assigns = assign(assigns, json: bounded_json(assigns.event.payload))

    ~H"""
    <details class="rounded-md border border-border">
      <summary class="flex cursor-pointer select-none items-center gap-2 px-3 py-2 text-xs">
        <code class="font-mono">{@event.event_type}</code>
        <span class="text-muted-foreground"><.time_ago at={@event.emitted_at} /></span>
      </summary>
      <pre
        :if={@json}
        class="overflow-x-auto border-t border-border px-3 py-2 font-mono text-xs"
      ><code phx-no-format>{@json}</code></pre>
    </details>
    """
  end

  # ── snapshot ─────────────────────────────────────────────────────────────

  defp transcript(thread), do: transcript(thread, nil, @maximum_pages, [])

  defp transcript(_thread, _after_id, 0, pages), do: pages |> Enum.reverse() |> List.flatten()

  defp transcript(thread, after_id, remaining, pages) do
    page = Threads.list_events(thread, after: after_id)

    case last_id(page) do
      0 -> transcript(thread, after_id, 0, pages)
      last -> transcript(thread, last, remaining - 1, [page | pages])
    end
  end

  defp last_id([]), do: 0
  defp last_id(events), do: List.last(events).id

  # ── payload readers ──────────────────────────────────────────────────────

  defp text(payload), do: string(payload, ["text"])

  defp string(payload, keys) when is_map(payload) do
    Enum.find_value(keys, fn key ->
      case Map.get(payload, key) do
        value when is_binary(value) and value != "" -> value
        _other -> nil
      end
    end)
  end

  defp string(_payload, _keys), do: nil

  defp steered?(payload) when is_map(payload), do: Map.get(payload, "steered") == true
  defp steered?(_payload), do: false

  defp bounded_json(nil), do: nil

  defp bounded_json(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, json} when byte_size(json) > @bounded_json_characters ->
        String.slice(json, 0, @bounded_json_characters) <> "\n…"

      {:ok, json} ->
        json

      {:error, _unencodable} ->
        inspect(value, limit: 50, printable_limit: @bounded_json_characters)
    end
  end

  defp usage_line(payload) when is_map(payload) do
    case Map.get(payload, "usage") do
      usage when is_map(usage) ->
        parts =
          [
            {"input", integer(usage, "input_tokens") || integer(usage, "prompt_tokens")},
            {"output", integer(usage, "output_tokens") || integer(usage, "completion_tokens")},
            {"total", integer(usage, "total_tokens")}
          ]
          |> Enum.filter(fn {_label, value} -> value end)
          |> Enum.map(fn {label, value} -> "#{value} #{label}" end)

        if parts == [], do: nil, else: Enum.join(parts, " · ") <> " tok"

      _absent ->
        nil
    end
  end

  defp usage_line(_payload), do: nil

  defp integer(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      value when is_float(value) -> trunc(value)
      _absent -> nil
    end
  end

  defp grant_spent(grant, key) do
    case grant.usage do
      usage when is_map(usage) -> integer(usage, key) || 0
      _absent -> 0
    end
  end

  # A null ceiling is unbounded, not zero and not missing. Rendering nil left
  # the denominator blank, which read as a rendering fault rather than as the
  # thread's actual authority.
  defp ceiling(nil), do: "∞"
  defp ceiling(value), do: value

  defp dollars(nil), do: "∞"
  defp dollars(microusd), do: "$#{:erlang.float_to_binary(microusd / 1_000_000, decimals: 2)}"

  # What this grant has spent, or the word for not knowing. `$0.00` is what
  # this cell used to show for a lane with no declared rates, and it was the
  # most confident wrong number on the page: the coder runs on that lane
  # (METER-001).
  defp cost_spent(grant) do
    case Pricing.cost(grant.usage) do
      nil -> "Unpriced"
      microusd -> dollars(microusd)
    end
  end

  defp cost_basis(grant), do: Pricing.usage_basis(grant.usage)

  defp cost_note("unpriced"),
    do: "No rates declared for this model, so this session's cost is unknown rather than zero."

  defp cost_note(_provisional),
    do: "Provisional rates. This is a working figure, not a bill."

  # The tier word plus what it means for a reader, because "dark" alone tells
  # the owner nothing about who can see the page they are looking at.
  defp visibility_label("dark"), do: "dark · only you"
  defp visibility_label("ledger"), do: "ledger · anyone signed in with the link"
  defp visibility_label(visibility), do: visibility

  defp status_variant("open"), do: :info
  defp status_variant("succeeded"), do: :success
  defp status_variant("failed"), do: :danger
  defp status_variant("cancelled"), do: :dim
  defp status_variant(_status), do: :default

  defp tool_status_variant("ok"), do: :success
  defp tool_status_variant("success"), do: :success
  defp tool_status_variant("error"), do: :danger
  defp tool_status_variant("failed"), do: :danger
  defp tool_status_variant(_status), do: :default
end
