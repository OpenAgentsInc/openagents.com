defmodule OpenAgentsWeb.AdminTokensLive do
  @moduledoc """
  Operator view of productive token usage versus raw volume.

  Every number is computed by `OpenAgents.TokenProductivity` at request time
  straight from PostgreSQL, the same tables the leaderboard reads, so the
  surface adds no second aggregation authority. Read-only and operator-gated.

  It shows aggregate token counts and rates only. It never renders
  conversation content, objectives, reports, or anything a person wrote.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgents.Accounts
  alias OpenAgents.TokenProductivity

  @impl true
  def mount(_params, _session, socket) do
    if Accounts.admin?(socket.assigns.current_user) do
      socket =
        socket
        |> assign(:page_title, "Operator · Tokens")
        |> assign(:status, :loading)
        |> assign(:report, nil)

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
    assign(socket, status: :loaded, report: TokenProductivity.report())
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
      title="Token productivity"
    >
      <main id="admin-tokens-page" class="app-shell admin-shell">
        <section class="admin space-y-8" aria-labelledby="tokens-heading">
          <header class="admin-heading">
            <h1 id="tokens-heading">Token productivity</h1>
            <p>
              Raw token volume next to the tokens that produced durable outcomes —
              merged work, closed issues, and verified receipts. Aggregate counts
              only; no conversation or run content is readable from this page.
            </p>
            <div class="admin-totals">
              <.badge
                :if={@status == :loaded && @report}
                variant={:dim}
                id="tokens-generated-at"
              >
                GENERATED {Calendar.strftime(@report.generated_at, "%Y-%m-%d %H:%M UTC")}
              </.badge>
              <.text_button id="tokens-refresh" phx-click="refresh" disabled={@status == :loading}>
                {if(@status == :loading, do: "REFRESHING…", else: "REFRESH")}
              </.text_button>
            </div>
          </header>

          <.alert :if={@status == :loading} id="tokens-loading" appearance={:row}>
            Computing token totals…
          </.alert>

          <div :if={@status == :loaded && @report} class="space-y-8">
            <section aria-labelledby="productive-heading">
              <.card id="tokens-productive">
                <h2 id="productive-heading" class="card-title">Productive versus raw</h2>
                <div class="flex flex-wrap items-center gap-3 pb-3">
                  <.badge>{format_tokens(@report.raw.total_tokens)} RAW</.badge>
                  <.badge variant={:success}>
                    {format_tokens(@report.productive.total_tokens)} PRODUCTIVE
                  </.badge>
                  <.badge :if={@report.productive.share} variant={:info}>
                    {format_share(@report.productive.share)} PRODUCTIVE SHARE
                  </.badge>
                </div>
                <ul class="divide-y divide-border">
                  <li class="flex items-center justify-between gap-4 py-3">
                    <span>Merged work</span>
                    <span class="font-semibold">
                      {format_tokens(@report.productive.merged_work.total_tokens)}
                    </span>
                  </li>
                  <li class="flex items-center justify-between gap-4 py-3">
                    <span>Closed issues</span>
                    <span class="font-semibold">
                      {format_tokens(@report.productive.closed_issues.total_tokens)}
                    </span>
                  </li>
                  <li class="flex items-center justify-between gap-4 py-3">
                    <span>Verified receipts</span>
                    <span class="font-semibold">
                      {format_tokens(@report.productive.verified_receipts.total_tokens)}
                    </span>
                  </li>
                </ul>
              </.card>
            </section>

            <section aria-labelledby="rates-heading">
              <.card id="tokens-rates">
                <h2 id="rates-heading" class="card-title">Cache and split</h2>
                <ul class="divide-y divide-border">
                  <li class="flex items-center justify-between gap-4 py-3">
                    <span>Cache hit rate</span>
                    <span class="font-semibold">{format_share(@report.cache.hit_rate)}</span>
                  </li>
                  <li class="flex items-center justify-between gap-4 py-3">
                    <span>Cached input tokens</span>
                    <span class="font-semibold">
                      {format_tokens(@report.cache.cached_input_tokens)}
                    </span>
                  </li>
                  <li class="flex items-center justify-between gap-4 py-3">
                    <span>Input share</span>
                    <span class="font-semibold">{format_share(@report.split.input_share)}</span>
                  </li>
                  <li class="flex items-center justify-between gap-4 py-3">
                    <span>Input / output tokens</span>
                    <span class="font-semibold">
                      {format_tokens(@report.split.input_tokens)} / {format_tokens(
                        @report.split.output_tokens
                      )}
                    </span>
                  </li>
                </ul>
              </.card>
            </section>

            <section aria-labelledby="sources-heading">
              <.card id="tokens-sources">
                <h2 id="sources-heading" class="card-title">Raw volume by source</h2>
                <.table id="tokens-sources-table" rows={source_rows(@report.sources)}>
                  <:col :let={row} label="Source">{row.label}</:col>
                  <:col :let={row} label="Input">{format_tokens(row.totals.input_tokens)}</:col>
                  <:col :let={row} label="Output">{format_tokens(row.totals.output_tokens)}</:col>
                  <:col :let={row} label="Total">{format_tokens(row.totals.total_tokens)}</:col>
                </.table>
              </.card>
            </section>

            <section aria-labelledby="providers-heading">
              <.card id="tokens-providers">
                <h2 id="providers-heading" class="card-title">Provider throughput</h2>
                <p :if={@report.providers == []} class="text-muted-foreground">
                  No completed provider steps recorded yet.
                </p>
                <.table
                  :if={@report.providers != []}
                  id="tokens-providers-table"
                  rows={@report.providers}
                >
                  <:col :let={row} label="Provider">{row.provider_id}</:col>
                  <:col :let={row} label="Steps">{row.steps}</:col>
                  <:col :let={row} label="Input">{format_tokens(row.input_tokens)}</:col>
                  <:col :let={row} label="Output">{format_tokens(row.output_tokens)}</:col>
                  <:col :let={row} label="Tokens/s">{format_rate(row.tokens_per_second)}</:col>
                </.table>
              </.card>
            </section>
          </div>
        </section>
      </main>
    </Layouts.app>
    """
  end

  defp source_rows(sources) do
    [
      %{label: "Typed turns", totals: sources.typed_turns},
      %{label: "Voice sessions", totals: sources.voice_sessions},
      %{label: "Work jobs", totals: sources.work_jobs},
      %{label: "SCV runs", totals: sources.scv_runs}
    ]
  end

  defp format_tokens(count) when is_integer(count) do
    count
    |> Integer.to_charlist()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_share(nil), do: "n/a"

  defp format_share(share) when is_float(share),
    do: "#{:erlang.float_to_binary(share * 100, decimals: 1)}%"

  defp format_rate(nil), do: "n/a"

  defp format_rate(rate) when is_float(rate),
    do: :erlang.float_to_binary(rate, decimals: 1)
end
