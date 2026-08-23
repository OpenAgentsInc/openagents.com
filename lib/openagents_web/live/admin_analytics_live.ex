defmodule OpenAgentsWeb.AdminAnalyticsLive do
  @moduledoc """
  Operator view of product analytics, pulled server-side from PostHog.

  Every number here is computed by PostHog at request time through
  `OpenAgents.PostHog`, so the surface adds no second aggregation authority:
  what an operator sees matches what the PostHog app would answer for the same
  window. Read-only, operator-gated, and honest about its three non-happy
  states — unconfigured credentials, a failed pull, and loading.

  It shows operational facts about accounts as aggregates. It never renders
  conversation content, memory claims, or anything a person wrote.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgents.Accounts
  alias OpenAgents.PostHog

  @impl true
  def mount(_params, _session, socket) do
    if Accounts.admin?(socket.assigns.current_user) do
      socket =
        socket
        |> assign(:page_title, "Operator · Analytics")
        |> assign(:status, :loading)
        |> assign(:overview, nil)

      if connected?(socket) do
        send(self(), :load)
      end

      {:ok, socket}
    else
      {:ok, redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    # Re-checked per event, not only at mount: a long-lived socket outlives the
    # decision that opened it.
    if Accounts.admin?(socket.assigns.current_user) do
      {:noreply,
       socket
       |> assign(:status, :loading)
       |> load()}
    else
      {:noreply, redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_info(:load, socket), do: {:noreply, load(socket)}

  defp load(%{assigns: %{status: :loading}} = socket) do
    case PostHog.overview() do
      {:ok, overview} ->
        assign(socket, status: :loaded, overview: overview)

      {:error, reason} when reason in [:not_configured, :unavailable] ->
        assign(socket, status: reason, overview: nil)
    end
  end

  # A refresh while a load is already resolving must not clobber the newer
  # state with an older response.
  defp load(socket), do: socket

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
      title="PostHog analytics"
    >
      <main id="admin-analytics-page" class="app-shell admin-shell">
        <section class="admin space-y-8" aria-labelledby="analytics-heading">
          <header class="admin-heading">
            <h1 id="analytics-heading">Product analytics</h1>
            <p>
              Computed live from PostHog. Usage covers the trailing twenty-four hours,
              and triage health uses the rolling windows shown below. These are aggregate
              operational facts; no conversation or memory content is readable from this page.
            </p>
            <div class="admin-totals">
              <.badge variant={:info}>LIVE POSTHOG</.badge>
              <.badge
                :if={@status == :loaded && @overview}
                variant={:dim}
                id="analytics-generated-at"
              >
                GENERATED {Calendar.strftime(@overview.generated_at, "%Y-%m-%d %H:%M UTC")}
              </.badge>
              <.text_button id="analytics-refresh" phx-click="refresh" disabled={@status == :loading}>
                {if(@status == :loading, do: "REFRESHING…", else: "REFRESH")}
              </.text_button>
            </div>
          </header>

          <.alert
            :if={@status == :not_configured}
            id="analytics-not-configured"
            appearance={:notice}
            variant={:warning}
          >
            This deployment has no PostHog read credentials configured. Set
            <.kbd>OPENAGENTS_POSTHOG_PERSONAL_API_KEY</.kbd>
            and
            <.kbd>OPENAGENTS_POSTHOG_PROJECT_ID</.kbd>
            to enable this surface.
          </.alert>

          <.alert
            :if={@status == :unavailable}
            id="analytics-unavailable"
            appearance={:notice}
            variant={:danger}
          >
            <div class="space-y-3">
              <p>PostHog did not answer the last query. Nothing on this page is stale data.</p>
              <.button id="analytics-retry" variant={:secondary} phx-click="refresh">
                TRY AGAIN
              </.button>
            </div>
          </.alert>

          <.alert :if={@status == :loading} id="analytics-loading" appearance={:row}>
            Querying PostHog…
          </.alert>

          <div :if={@status == :loaded && @overview} class="space-y-8">
            <section aria-labelledby="triage-health-heading">
              <.card id="analytics-triage-health">
                <div class="space-y-1">
                  <h2 id="triage-health-heading" class="card-title">Triage health</h2>
                  <p class="text-muted-foreground">
                    Response and label health use issues created in the trailing 90 days.
                    Issue flow covers the trailing eight weeks.
                  </p>
                </div>
                <% triage = @overview.triage_health %>
                <div class="grid gap-4 py-5 md:grid-cols-3">
                  <div class="rounded-md border border-border p-4">
                    <p class="text-sm text-muted-foreground">Median first maintainer response</p>
                    <p id="triage-median-response" class="mt-2 text-2xl font-semibold">
                      {format_hours(triage["median_first_maintainer_response_hours"])}
                    </p>
                  </div>
                  <div class="rounded-md border border-border p-4">
                    <p class="text-sm text-muted-foreground">Unlabeled after 24 hours</p>
                    <p id="triage-unlabeled-share" class="mt-2 text-2xl font-semibold">
                      {format_percent(triage["unlabeled_after_24h_percent"])}
                    </p>
                  </div>
                  <div class="rounded-md border border-border p-4">
                    <p class="text-sm text-muted-foreground">Eligible open issues</p>
                    <p id="triage-eligible-issues" class="mt-2 text-2xl font-semibold">
                      {triage["eligible_issues"]}
                    </p>
                    <p class="mt-1 text-sm text-muted-foreground">
                      {triage["unlabeled_issues"]} currently have no labels.
                    </p>
                  </div>
                </div>
                <.table id="analytics-weekly-issue-flow" rows={@overview.weekly_issue_flow}>
                  <:col :let={row} label="Week of">{row["week"]}</:col>
                  <:col :let={row} label="Created">{row["created"]}</:col>
                  <:col :let={row} label="Closed">{row["closed"]}</:col>
                </.table>
              </.card>
            </section>

            <section aria-labelledby="funnel-heading">
              <.card id="analytics-funnel">
                <h2 id="funnel-heading" class="card-title">Activation funnel</h2>
                <ul class="divide-y divide-border">
                  <li class="flex items-center justify-between gap-4 py-3">
                    <span>GitHub authorization started</span>
                    <span class="font-semibold">{@overview.funnel["auth_started"]}</span>
                  </li>
                  <li class="flex items-center justify-between gap-4 py-3">
                    <span>Accounts created</span>
                    <span class="font-semibold">{@overview.funnel["user_signed_up"]}</span>
                  </li>
                  <li class="flex items-center justify-between gap-4 py-3">
                    <span>Returning sign-ins</span>
                    <span class="font-semibold">{@overview.funnel["user_signed_in"]}</span>
                  </li>
                  <li class="flex items-center justify-between gap-4 py-3">
                    <span>First chat messages sent</span>
                    <span class="font-semibold">{@overview.funnel["chat_message_sent"]}</span>
                  </li>
                </ul>
              </.card>
            </section>

            <section aria-labelledby="turns-heading">
              <.card id="analytics-chat-turns">
                <h2 id="turns-heading" class="card-title">Chat turns</h2>
                <% turns = @overview.chat_turns %>
                <div class="flex flex-wrap items-center gap-3 pb-3">
                  <.badge>{turns["turns"]} TURNS</.badge>
                  <.badge :if={turns["completed"] > 0} variant={:success}>
                    {turns["completed"]} COMPLETED
                  </.badge>
                  <.badge :if={turns["failed"] > 0} variant={:danger}>
                    {turns["failed"]} FAILED
                  </.badge>
                  <.badge :if={turns["cancelled"] > 0} variant={:warning}>
                    {turns["cancelled"]} CANCELLED
                  </.badge>
                </div>
                <p class="text-muted-foreground">
                  Average turn {format_duration(turns["avg_duration_ms"])}; longest {format_duration(
                    turns["max_duration_ms"]
                  )}.
                </p>
              </.card>
            </section>

            <section aria-labelledby="lifecycle-heading">
              <.card id="analytics-chat-lifecycle">
                <div class="space-y-1">
                  <h2 id="lifecycle-heading" class="card-title">Chat lifecycle and tokens</h2>
                  <p class="text-muted-foreground">
                    Assistant deliveries, queued messages, and turn failures over the trailing
                    twenty-four hours. Token totals are provider-reported and counted once per turn.
                  </p>
                </div>
                <% lifecycle = @overview.chat_lifecycle %>
                <div class="grid gap-4 py-5 md:grid-cols-3">
                  <div class="rounded-md border border-border p-4">
                    <p class="text-sm text-muted-foreground">Assistant messages received</p>
                    <p id="lifecycle-messages-received" class="mt-2 text-2xl font-semibold">
                      {lifecycle["messages_received"]}
                    </p>
                    <p class="mt-1 text-sm text-muted-foreground">
                      {lifecycle["messages_queued"]} messages waited behind an active turn.
                    </p>
                  </div>
                  <div class="rounded-md border border-border p-4">
                    <p class="text-sm text-muted-foreground">Turn failure rate</p>
                    <p id="lifecycle-failure-rate" class="mt-2 text-2xl font-semibold">
                      {format_percent(lifecycle["turn_failure_percent"])}
                    </p>
                    <p class="mt-1 text-sm text-muted-foreground">
                      {lifecycle["turns_failed"]} of {lifecycle["turns_finished"]} finished turns
                      ended in failure or cancellation.
                    </p>
                  </div>
                  <div class="rounded-md border border-border p-4">
                    <p class="text-sm text-muted-foreground">Tokens used</p>
                    <p id="lifecycle-total-tokens" class="mt-2 text-2xl font-semibold">
                      {total_tokens(@overview.chat_token_usage)}
                    </p>
                    <p class="mt-1 text-sm text-muted-foreground">
                      Input plus output across every model.
                    </p>
                  </div>
                </div>
                <.table id="analytics-chat-tokens-table" rows={@overview.chat_token_usage}>
                  <:col :let={row} label="Model">{row["model"]}</:col>
                  <:col :let={row} label="Provider">{row["provider"]}</:col>
                  <:col :let={row} label="Turns">{row["turns"]}</:col>
                  <:col :let={row} label="Input">{row["input_tokens"]}</:col>
                  <:col :let={row} label="Output">{row["output_tokens"]}</:col>
                  <:col :let={row} label="Total">{row["total_tokens"]}</:col>
                </.table>
              </.card>
            </section>

            <section aria-labelledby="events-heading">
              <.card id="analytics-event-volume">
                <h2 id="events-heading" class="card-title">Event volume</h2>
                <.table id="analytics-events-table" rows={@overview.event_counts}>
                  <:col :let={row} label="Event">{row["event"]}</:col>
                  <:col :let={row} label="Count">{row["count"]}</:col>
                  <:col :let={row} label="People">{row["people"]}</:col>
                </.table>
              </.card>
            </section>

            <section aria-labelledby="pages-heading">
              <.card id="analytics-top-pages">
                <h2 id="pages-heading" class="card-title">Top pages</h2>
                <.table id="analytics-pages-table" rows={@overview.top_pages}>
                  <:col :let={row} label="URL">{row["url"]}</:col>
                  <:col :let={row} label="Views">{row["views"]}</:col>
                </.table>
              </.card>
            </section>
          </div>
        </section>
      </main>
    </Layouts.app>
    """
  end

  defp format_duration(nil), do: "n/a"

  defp format_duration(ms) when is_number(ms) and ms >= 1_000 do
    "#{:erlang.float_to_binary(ms / 1_000, decimals: 1)}s"
  end

  defp format_duration(ms) when is_integer(ms), do: "#{ms}ms"

  defp total_tokens(rows) when is_list(rows),
    do: Enum.reduce(rows, 0, fn row, total -> total + (row["total_tokens"] || 0) end)

  defp format_hours(nil), do: "No data"
  defp format_hours(hours) when is_integer(hours), do: "#{hours}h"

  defp format_hours(hours) when is_float(hours),
    do: "#{:erlang.float_to_binary(hours, decimals: 1)}h"

  defp format_percent(value) when is_integer(value), do: "#{value}%"

  defp format_percent(value) when is_float(value),
    do: "#{:erlang.float_to_binary(value, decimals: 1)}%"
end
