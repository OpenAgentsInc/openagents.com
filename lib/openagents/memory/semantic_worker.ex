defmodule OpenAgents.Memory.SemanticWorker do
  @moduledoc "Bounded asynchronous semantic outbox consumer; accepted turns never wait for it."
  use GenServer

  alias OpenAgents.Memory.SemanticIndex

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(_options) do
    config = Application.fetch_env!(:sarah, :semantic_index)

    if Keyword.fetch!(config, :enabled) do
      _manifest = SemanticIndex.ensure_manifest!(Map.new(config))
      schedule(0)
    end

    {:ok, config}
  end

  @impl true
  def handle_info(:drain, config) do
    provider = Keyword.fetch!(config, :provider)
    _counts = SemanticIndex.process_all(provider, Keyword.fetch!(config, :batch_size))
    schedule(Keyword.fetch!(config, :poll_interval_ms))
    {:noreply, config}
  end

  defp schedule(delay), do: Process.send_after(self(), :drain, delay)
end
