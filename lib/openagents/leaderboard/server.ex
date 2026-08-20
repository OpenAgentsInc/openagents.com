defmodule OpenAgents.Leaderboard.Server do
  @moduledoc """
  Computes the public leaderboard once per interval and fans the result out.

  The board is public, so the number of connected viewers is unbounded and
  anonymous. If every LiveView reread PostgreSQL on every invalidation, one busy
  voice call would fan out to N unindexed aggregates — a cheap way to hurt the
  database from outside. Invalidations are therefore coalesced here, the ranking
  is computed once, and the same result is pushed to local subscribers.

  The cache is a projection, never authority: it is derived only from
  PostgreSQL and a lost cache costs a recompute, not data.
  """

  use GenServer

  require Logger

  alias OpenAgents.Leaderboard
  alias OpenAgents.Leaderboard.Entry

  @default_interval_ms 1_000
  @call_timeout 15_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @doc "The cached board, computing it on first use."
  @spec entries() :: [Entry.t()]
  def entries, do: GenServer.call(__MODULE__, :entries, @call_timeout)

  @doc "Recompute now and push to subscribers, cancelling any pending debounce."
  @spec refresh() :: [Entry.t()]
  def refresh, do: GenServer.call(__MODULE__, :refresh, @call_timeout)

  @impl true
  def init(_options) do
    :ok = Phoenix.PubSub.subscribe(OpenAgents.PubSub, Leaderboard.invalidation_topic())
    {:ok, %{entries: nil, timer: nil}}
  end

  @impl true
  def handle_call(:entries, _from, state) do
    state = if state.entries, do: state, else: compute(state)
    {:reply, state.entries || [], state}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    state = state |> cancel_timer() |> compute() |> publish()
    {:reply, state.entries || [], state}
  end

  @impl true
  def handle_info(:leaderboard_invalidated, %{timer: nil} = state) do
    if auto_refresh?(),
      do: {:noreply, %{state | timer: Process.send_after(self(), :recompute, interval_ms())}},
      else: {:noreply, state}
  end

  # A recompute is already scheduled; this invalidation folds into it.
  def handle_info(:leaderboard_invalidated, state), do: {:noreply, state}

  def handle_info(:recompute, state) do
    {:noreply, %{state | timer: nil} |> compute() |> publish()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Only publish a real change. A voice session reports usage repeatedly, and an
  # unchanged board should not wake every connected browser.
  defp publish(%{changed?: true, entries: entries} = state) do
    Phoenix.PubSub.local_broadcast(
      OpenAgents.PubSub,
      Leaderboard.topic(),
      {:leaderboard_updated, entries}
    )

    Map.delete(state, :changed?)
  end

  defp publish(state), do: Map.delete(state, :changed?)

  defp compute(state) do
    entries = Leaderboard.compute_entries()
    %{state | entries: entries} |> Map.put(:changed?, entries != state.entries)
  rescue
    error ->
      # The board is a projection. A failed recompute keeps serving the last
      # good ranking rather than taking a public page down.
      Logger.warning("leaderboard recompute failed: #{Exception.message(error)}")
      Map.put(state, :changed?, false)
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    _remaining = Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp interval_ms,
    do: Application.get_env(:openagents, :leaderboard_refresh_interval_ms, @default_interval_ms)

  # Tests drive the board explicitly so a debounced recompute cannot outlive the
  # database sandbox that owns its rows. The end-to-end path stays covered by
  # turning this back on for the test that asserts it.
  defp auto_refresh?,
    do: Application.get_env(:openagents, :leaderboard_auto_refresh_enabled, true)
end
