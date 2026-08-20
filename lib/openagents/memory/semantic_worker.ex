defmodule OpenAgents.Memory.SemanticWorker do
  @moduledoc "Bounded asynchronous semantic outbox consumer; accepted turns never wait for it."
  use GenServer

  require Logger

  alias OpenAgents.Memory.SemanticIndex

  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @doc false
  def drain(worker \\ __MODULE__), do: GenServer.call(worker, :drain, 120_000)

  @impl true
  def init(options) do
    config = Application.fetch_env!(:openagents, :semantic_index)
    processor = Keyword.get(options, :processor, &process/1)

    if Keyword.fetch!(config, :enabled) do
      _manifest = SemanticIndex.ensure_manifest!(Map.new(config))

      if Keyword.get(options, :autostart, true), do: schedule(0)
    end

    {:ok, %{config: config, processor: processor}}
  end

  @impl true
  def handle_call(:drain, _from, state) do
    {result, state} = run_drain(state)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:drain, state) do
    {_result, state} = run_drain(state)
    schedule(Keyword.fetch!(state.config, :poll_interval_ms))
    {:noreply, state}
  end

  defp schedule(delay), do: Process.send_after(self(), :drain, delay)

  defp run_drain(state) do
    result =
      try do
        {:ok, state.processor.(state.config)}
      rescue
        _exception -> {:error, :semantic_drain_failed}
      catch
        _kind, _reason -> {:error, :semantic_drain_failed}
      end

    if result == {:error, :semantic_drain_failed} do
      Logger.warning("semantic_drain_failed code=worker_exception")
    end

    {result, state}
  end

  defp process(config) do
    SemanticIndex.process_all(
      Keyword.fetch!(config, :provider),
      Keyword.fetch!(config, :batch_size),
      provider_timeout_ms: Keyword.get(config, :provider_timeout_ms, 15_000),
      lease_ms: Keyword.get(config, :lease_ms, 30_000)
    )
  end
end
