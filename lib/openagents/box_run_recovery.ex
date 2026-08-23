defmodule OpenAgents.BoxRunRecovery do
  @moduledoc false

  use GenServer, restart: :temporary

  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(_options) do
    :ok = OpenAgents.BoxRuns.reconcile_non_terminal()
    {:ok, %{}}
  end
end
