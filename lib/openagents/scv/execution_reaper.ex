defmodule OpenAgents.SCV.ExecutionReaper do
  @moduledoc "Releases capacity held by SCVs whose durable lease expired."

  use GenServer

  require Logger

  @default_interval_ms :timer.seconds(30)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    case Keyword.get(options, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @impl true
  def init(options) do
    state = %{interval_ms: Keyword.get(options, :interval_ms, @default_interval_ms)}
    schedule_reap(Keyword.get(options, :initial_delay_ms, :timer.seconds(5)))
    {:ok, state}
  end

  @impl true
  def handle_info(:reap, state) do
    case reap() do
      count when count > 0 -> Logger.warning("Released #{count} expired SCV lease(s)")
      _count -> :ok
    end

    schedule_reap(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp reap do
    OpenAgents.SCV.Executions.expire_stale()
  rescue
    _error ->
      Logger.warning("Could not reap expired SCV leases code=reaper_failed")
      0
  catch
    _kind, _reason ->
      Logger.warning("Could not reap expired SCV leases code=reaper_failed")
      0
  end

  defp schedule_reap(interval_ms), do: Process.send_after(self(), :reap, interval_ms)
end
