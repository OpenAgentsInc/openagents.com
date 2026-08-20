defmodule OpenAgents.ReleaseState do
  @moduledoc """
  Holds bounded runtime observations across supported release upgrades.

  The process uses an explicitly versioned state struct. The `0.1.0` release
  uses schema 1 and the `0.2.0` release uses schema 2. A two-way relup calls
  `code_change/3`, which preserves the PID and observations while adding or
  removing schema 2's integrity field.
  """

  use GenServer

  alias OpenAgents.ReleaseState.State

  @current_schema System.get_env("OPENAGENTS_RELUP_STATE_VERSION", "2")
                  |> String.to_integer()
  @maximum_observations 100

  if @current_schema not in [1, 2] do
    raise "OPENAGENTS_RELUP_STATE_VERSION must be 1 or 2"
  end

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Return the process's current state."
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @doc "Store one bounded observation for relup continuity checks."
  def observe(value, server \\ __MODULE__), do: GenServer.call(server, {:observe, value})

  @doc "Return the schema version compiled into this release."
  def current_schema, do: @current_schema

  @doc false
  def install_barrier do
    with path when is_binary(path) <- System.get_env("OPENAGENTS_RELUP_INSTALL_BARRIER_PATH"),
         delay when is_binary(delay) <- System.get_env("OPENAGENTS_RELUP_INSTALL_BARRIER_MS"),
         {milliseconds, ""} <- Integer.parse(delay),
         true <- milliseconds > 0,
         false <- File.exists?(path) do
      File.write!(path, "entered\n", [:exclusive])

      receive do
      after
        milliseconds -> :ok
      end
    else
      _not_enabled -> :ok
    end
  end

  @impl true
  def init(_opts), do: {:ok, state_for(@current_schema, [])}

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  def handle_call({:observe, value}, _from, %State{} = state) do
    observations = Enum.take([value | state.observations], @maximum_observations)
    next = state_for(state.schema_version, observations)
    {:reply, :ok, next}
  end

  @impl true
  def code_change({:down, _from_version}, %State{} = state, _extra) do
    {:ok, state_for(1, state.observations)}
  end

  def code_change(_from_version, %State{schema_version: 1} = state, _extra) do
    {:ok, state_for(2, state.observations)}
  end

  def code_change(_from_version, %State{} = state, _extra) do
    {:ok, state_for(@current_schema, state.observations)}
  end

  defp state_for(1, observations) do
    %State{schema_version: 1, observations: observations, integrity: nil}
  end

  defp state_for(2, observations) do
    integrity =
      :crypto.hash(:sha256, :erlang.term_to_binary(observations)) |> Base.encode16(case: :lower)

    %State{schema_version: 2, observations: observations, integrity: integrity}
  end
end
