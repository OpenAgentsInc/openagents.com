defmodule OpenAgentsWeb.GymLive do
  @moduledoc """
  The Gym: graded benchmark runs of our agents, operator-only.

  Read-only over `OpenAgents.Gym` — the harness runs elsewhere and posts
  results through `POST /api/v1/gym/runs`; this surface is the scoreboard
  that capability work (models, plugins, harness changes) is read against.
  Operator-gated the same way `/chat` is: the route sits behind the
  `:operator` pipeline, the mount re-checks, and every event re-checks,
  because a long-lived socket outlives the decision that opened it.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgents.Accounts
  alias OpenAgents.Gym
  alias OpenAgents.Gym.Run

  @impl true
  def mount(_params, _session, socket) do
    if Accounts.admin?(socket.assigns.current_user) do
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

  defp presence(""), do: nil
  defp presence(suite) when is_binary(suite), do: suite

  defp load(socket, suite) do
    runs = Gym.list_runs(suite: suite)

    socket
    |> assign(:page_title, "Gym")
    |> assign(:suite, suite)
    |> assign(:suites, Gym.suites())
    |> assign(:runs_empty?, runs == [])
    |> stream(:runs, runs, reset: true)
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

        <div :if={@runs_empty?}>
          <.empty title="No runs recorded yet">
            No graded runs have been posted. The harness records one with
            <code>POST /api/v1/gym/runs</code>
            — see <code>docs/2026-08-24-harbor-terminal-bench-plan.md</code>.
          </.empty>
        </div>

        <div :if={!@runs_empty?} class="overflow-x-auto">
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
                  {Calendar.strftime(run.inserted_at, "%Y-%m-%d %H:%M")}
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
                <td>{run.tasks_passed}/{run.tasks_total}</td>
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
