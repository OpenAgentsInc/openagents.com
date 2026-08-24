defmodule OpenAgents.Machines.PairingExpiry do
  @moduledoc """
  Periodically expires pairings whose windows have closed.

  Without it the only thing that expired a pairing was the CLI polling for its
  token, so an abandoned pairing kept a sealed computer token and a live
  computer indefinitely. See `INVARIANTS.md`, IDENTITY-011.
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
    _ = OpenAgents.Machines.expire_elapsed_pairings()
    schedule(interval_ms)
    {:noreply, interval_ms}
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :expire, interval_ms)
end
