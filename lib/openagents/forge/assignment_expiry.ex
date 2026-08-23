defmodule OpenAgents.Forge.AssignmentExpiry do
  @moduledoc """
  Periodically expires active assignments whose deadlines have passed.
  """

  use GenServer

  @interval_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(options) do
    interval_ms = Keyword.get(options, :interval_ms, @interval_ms)
    schedule(interval_ms)
    {:ok, interval_ms}
  end

  @impl true
  def handle_info(:expire, interval_ms) do
    _ = OpenAgents.Forge.Assignments.expire()
    schedule(interval_ms)
    {:noreply, interval_ms}
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :expire, interval_ms)
end
