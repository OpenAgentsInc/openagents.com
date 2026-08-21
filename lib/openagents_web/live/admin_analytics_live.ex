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
              Computed live from PostHog over the trailing twenty-four hours. These are
              aggregate operational facts about usage; no conversation or memory content
              is readable from this page.
            </p>
            <div class="admin-totals">
              <.badge variant={:info}>TRAILING 24 HOURS</.badge>
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
            Querying PostHog for the trailing twenty-four hours…
          </.alert>

          <div :if={@status == :loaded && @overview} class="space-y-8">
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
end
