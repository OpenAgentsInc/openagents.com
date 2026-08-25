defmodule OpenAgents.Inference.Health do
  @moduledoc """
  What each model lane has actually done lately, so the catalog can stop
  claiming a lane is available while every call to it fails.

  The catalog used to answer one question — is a credential configured — and
  publish the answer as `availability`. That is a claim about wiring, not about
  whether the lane answers, and the difference is not academic: a whole
  delegation fleet was blocked by a default model whose credential was present
  and whose every call failed, while `GET /api/v1/models` reported it
  `available` (#238, #199).

  This records the outcome of real calls and lets the catalog say what it
  knows:

  - `:unknown` — nothing has been tried since boot. Not a promise either way.
  - `:healthy` — the last call succeeded.
  - `:degraded` — `@degraded_after` consecutive failures with no success since.

  Deliberately not a circuit breaker. Nothing here refuses a call or routes
  around a lane; a caller that wants the failing lane still gets it. The only
  claim being fixed is the published one, because a client that reads the
  catalog and picks a dead lane was misled by us rather than by the provider.

  State is per node and lives in ETS. It is lost on restart, which is correct:
  health is a statement about now, and a node that has just booted has not
  tried anything yet — that is exactly `:unknown`.
  """

  use GenServer

  @table :openagents_inference_health
  @degraded_after 3

  @type status :: :unknown | :healthy | :degraded

  @doc "How many consecutive failures make a lane degraded."
  @spec degraded_after() :: pos_integer()
  def degraded_after, do: @degraded_after

  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(_options) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Record that a call to `model_id` answered.

  Success clears the failure run outright rather than decrementing it: a lane
  that answers is working now, and holding a grudge for earlier failures would
  keep publishing `degraded` about a lane that recovered.
  """
  @spec record_success(String.t()) :: :ok
  def record_success(model_id) when is_binary(model_id) do
    if table?(), do: :ets.insert(@table, {model_id, 0, :healthy})
    :ok
  end

  @doc """
  Record that a call to `model_id` failed.

  `status` is the upstream HTTP status when the failure carried one
  (`OpenAgents.OperationalLog.status/1`) and `nil` otherwise. It is kept so an
  operator reading health sees *why*, and never inferred: a failure with no
  status reports none.
  """
  @spec record_failure(String.t(), pos_integer() | nil) :: :ok
  def record_failure(model_id, status \\ nil) when is_binary(model_id) do
    if table?() do
      failures =
        case :ets.lookup(@table, model_id) do
          [{^model_id, count, _}] when is_integer(count) -> count + 1
          _ -> 1
        end

      :ets.insert(@table, {model_id, failures, {:failed, status}})
    end

    :ok
  end

  @doc "The status of one lane, and the last upstream status when it failed."
  @spec status(String.t()) :: {status(), pos_integer() | nil}
  def status(model_id) when is_binary(model_id) do
    case table?() && :ets.lookup(@table, model_id) do
      [{^model_id, 0, :healthy}] ->
        {:healthy, nil}

      [{^model_id, failures, {:failed, upstream}}] when failures >= @degraded_after ->
        {:degraded, upstream}

      [{^model_id, _failures, {:failed, upstream}}] ->
        # Below the threshold a lane is not yet degraded, but the last failure
        # is still worth surfacing to whoever asks.
        {:healthy, upstream}

      _ ->
        {:unknown, nil}
    end
  end

  @doc "Forget everything recorded. For tests and for an operator resetting a lane."
  @spec reset() :: :ok
  def reset do
    if table?(), do: :ets.delete_all_objects(@table)
    :ok
  end

  defp table?, do: :ets.whereis(@table) != :undefined
end
