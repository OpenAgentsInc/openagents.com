defmodule OpenAgentsWeb.BoxRateLimiter do
  @moduledoc false

  use GenServer

  @table :openagents_box_api_rate_limits
  @default_window_seconds 60
  @default_create_limit 10
  @default_command_limit 30
  @minimum_sweep_interval_ms 1_000
  @maximum_sweep_interval_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  @spec allow?(term(), :create | :command) :: :ok | {:error, :rate_limited}
  def allow?(principal, operation)
      when operation in [:create, :command, :run_create, :run_command] do
    GenServer.call(__MODULE__, {:allow, principal, operation})
  end

  @impl true
  def init(_options) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:allow, principal, operation}, _from, %{table: table} = state) do
    window_seconds = setting(:rate_limit_window_seconds, @default_window_seconds)
    limit = setting(rate_limit_key(operation), default_limit(operation))
    bucket = div(System.system_time(:second), window_seconds)
    key = {operation, principal, bucket}

    :ets.insert_new(table, {key, 0})
    count = :ets.update_counter(table, key, {2, 1})

    reply =
      if count <= limit do
        :ok
      else
        :ets.update_counter(table, key, {2, -1})
        {:error, :rate_limited}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:sweep, %{table: table} = state) do
    current_bucket = div(System.system_time(:second), setting(:rate_limit_window_seconds, 60))

    table
    |> :ets.tab2list()
    |> Enum.each(fn {{_operation, _principal, bucket} = key, _count} ->
      if bucket < current_bucket, do: :ets.delete(table, key)
    end)

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, sweep_interval_ms())
  end

  defp sweep_interval_ms do
    :rate_limit_window_seconds
    |> setting(@default_window_seconds)
    |> then(&:timer.seconds/1)
    |> max(@minimum_sweep_interval_ms)
    |> min(@maximum_sweep_interval_ms)
  end

  defp rate_limit_key(:create), do: :create_rate_limit
  defp rate_limit_key(:command), do: :command_rate_limit
  defp rate_limit_key(:run_create), do: :run_create_rate_limit
  defp rate_limit_key(:run_command), do: :run_command_rate_limit

  defp default_limit(:create), do: @default_create_limit
  defp default_limit(:command), do: @default_command_limit
  defp default_limit(:run_create), do: @default_create_limit
  defp default_limit(:run_command), do: @default_command_limit

  defp setting(key, default) do
    case Keyword.get(Application.get_env(:openagents, :box_api, []), key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end
end
