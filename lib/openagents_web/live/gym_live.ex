defmodule OpenAgentsWeb.GymLive do
  @moduledoc """
  The Gym: graded benchmark runs of our agents, operator-only, live.

  Read-only over `OpenAgents.Gym` — the harness runs elsewhere and posts
  results through `POST /api/v1/gym/runs` and the lifecycle routes; this
  surface is the scoreboard that capability work (models, plugins, harness
  changes) is read against. It subscribes to the gym topic, so a running
  suite appears the moment the harness registers it, its trial tally moves
  as trials report, and the run flips to the graded table in place when it
  finalizes — no reload anywhere.

  Operator-gated the same way `/chat` is: the route sits behind the
  `:operator` pipeline, the mount re-checks, and every event re-checks,
  because a long-lived socket outlives the decision that opened it.

  The graded table stays a stream. The running section is a bounded assign
  instead, because each entry carries a live trial tally that mutates on
  every `{:gym_trial, _}` broadcast, and the collection is bounded by the
  number of suites running at once rather than by history.
  """

  use OpenAgentsWeb, :live_view

  import OpenAgentsWeb.AI.Conversation, only: [shimmer: 1]

  alias OpenAgents.Accounts
  alias OpenAgents.Gym
  alias OpenAgents.Gym.Run

  @impl true
  def mount(_params, _session, socket) do
    if Accounts.admin?(socket.assigns.current_user) do
      # Subscribe before the snapshot read, so a run or trial that lands
      # between the two arrives as a message rather than being missed.
      if connected?(socket), do: Gym.subscribe()

      {:ok, load(socket, nil)}
    else
      {:ok, redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("filter", %{"suite" => suite}, socket) do
    if Accounts.admin?(socket.assigns.current_user) do
      {:noreply, load(socket, presence(suite))}
    else
      {:noreply, redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_info({:gym_run, %Run{}}, socket) do
    # Start, finalize, abandon, and sweep all reload the page's two
    # sections under the current filter, which is what moves a finalized
    # run from the running section into the graded table in place.
    if Accounts.admin?(socket.assigns.current_user) do
      {:noreply, load(socket, socket.assigns.suite)}
    else
      {:noreply, redirect(socket, to: ~p"/")}
    end
  end

  def handle_info({:gym_trial, trial}, socket) do
    if Accounts.admin?(socket.assigns.current_user) do
      running =
        Enum.map(socket.assigns.running, fn entry ->
          if entry.run.id == trial.run_id, do: running_entry(entry.run), else: entry
        end)

      {:noreply, assign(socket, :running, running)}
    else
      {:noreply, redirect(socket, to: ~p"/")}
    end
  end

  defp presence(""), do: nil
  defp presence(suite) when is_binary(suite), do: suite

  defp load(socket, suite) do
    runs = Gym.list_runs(suite: suite)
    {running, finished} = Enum.split_with(runs, &(&1.status == "running"))

    socket
    |> assign(:page_title, "Gym")
    |> assign(:suite, suite)
    |> assign(:suites, Gym.suites())
    |> assign(:running, Enum.map(running, &running_entry/1))
    |> assign(:runs_empty?, runs == [])
    |> assign(:table_empty?, finished == [])
    |> stream(:runs, finished, reset: true)
  end

  # A running run with its live trial tally: how many trials the harness
  # has reported and how many have passed so far.
  defp running_entry(run) do
    trials = Gym.list_trials(run)

    %{
      run: run,
      reported: length(trials),
      passed: Enum.count(trials, &(&1.state == "passed"))
    }
  end

  defp percent(nil), do: "—"
  defp percent(score), do: "#{Float.round(score * 100, 1)}%"

  defp dollars(nil), do: "—"
  defp dollars(microusd), do: "$#{Float.round(microusd / 1_000_000, 4)}"

  defp elapsed(nil), do: "—"

  defp elapsed(seconds) when seconds < 60, do: "#{seconds}s"

  defp elapsed(seconds) do
    minutes = div(seconds, 60)
    rest = rem(seconds, 60)
    if(rest == 0, do: "#{minutes}m", else: "#{minutes}m #{rest}s")
  end

  defp elapsed_since(started_at),
    do: elapsed(max(DateTime.diff(DateTime.utc_now(), started_at, :second), 0))

  # A run still `running` (or swept to `abandoned`) has no grades yet.
  defp counts(passed, total) when is_integer(passed) and is_integer(total),
    do: "#{passed}/#{total}"

  defp counts(_passed, _total), do: "—"

  defp tokens(nil, nil), do: "—"
  defp tokens(input, output), do: "#{format_count(input)} in / #{format_count(output)} out"

  defp format_count(nil), do: "—"
  defp format_count(count) when count >= 1_000_000, do: "#{Float.round(count / 1_000_000, 1)}M"
  defp format_count(count) when count >= 1_000, do: "#{Float.round(count / 1_000, 1)}k"
  defp format_count(count), do: Integer.to_string(count)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
    >
      <div class="mx-auto max-w-6xl space-y-6">
        <.header>
          Gym
          <:subtitle>
            Graded benchmark runs, newest first. The harness posts results;
            this page reads them. Operator-only.
          </:subtitle>
        </.header>

        <form id="gym-suite-filter" phx-change="filter">
          <select name="suite" class="select" data-size="sm">
            <option value="" selected={@suite == nil}>All suites</option>
            <option :for={suite <- @suites} value={suite} selected={@suite == suite}>
              {suite}
            </option>
          </select>
        </form>

        <section :if={@running != []} id="gym-running" class="space-y-3" aria-label="Running now">
          <h2 class="text-sm font-medium text-muted-foreground">Running now</h2>
          <.link
            :for={entry <- @running}
            navigate={~p"/gym/runs/#{entry.run.id}"}
            id={"gym-running-#{entry.run.id}"}
            class="block"
          >
            <.card class="text-sm transition-colors hover:border-primary">
              <div class="flex flex-wrap items-center gap-x-6 gap-y-2">
                <span class="font-mono">{entry.run.suite}</span>
                <span>
                  {entry.run.agent}
                  <span :if={entry.run.agent_version} class="text-muted-foreground">
                    @{entry.run.agent_version}
                  </span>
                </span>
                <span class="font-mono">{entry.run.model}</span>
                <span>{entry.run.lane || "—"}</span>
                <span class="tabular-nums" data-tally>
                  {entry.passed} passed / {entry.reported} reported
                </span>
                <span class="whitespace-nowrap text-muted-foreground">
                  {elapsed_since(entry.run.inserted_at)}
                </span>
                <.shimmer text="Running" tag="span" class="text-xs" />
              </div>
            </.card>
          </.link>
        </section>

        <div :if={@runs_empty?}>
          <.empty title="No runs recorded yet">
            No graded runs have been posted. The harness records one with
            <code>POST /api/v1/gym/runs</code>
            — see <code>docs/2026-08-24-harbor-terminal-bench-plan.md</code>.
          </.empty>
        </div>

        <div :if={!@table_empty?} class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>Recorded</th>
                <th>Suite</th>
                <th>Agent</th>
                <th>Model</th>
                <th>Lane</th>
                <th>Score</th>
                <th>Tasks</th>
                <th>Duration</th>
                <th>Tokens</th>
                <th>Cost</th>
              </tr>
            </thead>
            <tbody id="gym-runs" phx-update="stream">
              <tr :for={{id, run} <- @streams.runs} id={id}>
                <td class="whitespace-nowrap">
                  <.link navigate={~p"/gym/runs/#{run.id}"} class="hover:underline">
                    {Calendar.strftime(run.inserted_at, "%Y-%m-%d %H:%M")}
                  </.link>
                </td>
                <td class="font-mono text-sm">{run.suite}</td>
                <td>
                  {run.agent}
                  <span :if={run.agent_version} class="text-muted-foreground">
                    @{run.agent_version}
                  </span>
                </td>
                <td class="font-mono text-sm">{run.model}</td>
                <td>{run.lane || "—"}</td>
                <td class="font-semibold">{percent(Run.score(run))}</td>
                <td>{counts(run.tasks_passed, run.tasks_total)}</td>
                <td class="whitespace-nowrap">{elapsed(run.duration_seconds)}</td>
                <td class="whitespace-nowrap text-sm">
                  {tokens(run.input_tokens, run.output_tokens)}
                </td>
                <td>{dollars(run.cost_microusd)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
