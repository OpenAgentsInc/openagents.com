defmodule OpenAgents.Effects.Worker do
  @moduledoc """
  Drives committed effects to a terminal state (EFFECT-001).

  The worker owns no state that matters. Everything it needs is in the
  database: the effect, its lease, its attempt count, its last error. Losing
  the worker, or the machine it runs on, therefore loses no effect —
  `OpenAgents.Effects.reclaim_expired/1` returns whatever it was holding to the
  queue, and any other node's worker picks it up.

  One pass does, in order:

    1. Reclaim effects whose lease expired, so a dead worker's work comes back.
    2. Claim a bounded batch under a fresh lease.
    3. Dispatch each to its handler, with the effect's deterministic
       idempotency key, and record `complete/1` or `fail/2`.

  Claiming and completing are separate records on purpose (EFFECT-002). A
  claimed effect is one a worker said it would try; it is not evidence that
  anything ran, and it is never evidence that anything finished.

  Tests and operators drive the loop through `tick/1`, so no test has to sleep
  and no operator has to guess whether a pass happened.
  """

  use GenServer

  require Logger

  alias OpenAgents.Effects
  alias OpenAgents.Effects.Effect
  alias OpenAgents.Effects.Registry

  @default_interval 1_000

  @typedoc "What one pass did."
  @type pass :: %{
          reclaimed: non_neg_integer(),
          claimed: non_neg_integer(),
          completed: non_neg_integer(),
          failed: non_neg_integer()
        }

  @doc "Start the worker loop."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    {name, options} = Keyword.pop(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @doc "Run one pass synchronously, returning what it did."
  @spec tick(GenServer.server()) :: pass()
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick, 60_000)

  @doc """
  Run one pass without a running worker.

  Exposed so a test, a recovery path, or a one-off operator command can drain
  the outbox without standing a process up first.
  """
  @spec run_once(keyword()) :: pass()
  def run_once(options \\ []) do
    identity = Keyword.get_lazy(options, :identity, &default_identity/0)
    limit = Keyword.get(options, :limit, 20)
    lease_seconds = Keyword.get(options, :lease_seconds, Effects.lease_seconds())

    reclaimed = Effects.reclaim_expired()

    claimed =
      Effects.claim_batch(identity,
        limit: limit,
        lease_seconds: lease_seconds,
        kinds: Registry.kinds()
      )

    {completed, failed} =
      Enum.reduce(claimed, {0, 0}, fn effect, {done, dead} ->
        case dispatch(effect) do
          :ok -> {done + 1, dead}
          :error -> {done, dead + 1}
        end
      end)

    %{reclaimed: reclaimed, claimed: length(claimed), completed: completed, failed: failed}
  end

  @doc """
  Run one claimed effect's handler and record the outcome.

  Exposed so a caller that already holds an effect can drive it without racing
  the claim query.
  """
  @spec dispatch(Effect.t()) :: :ok | :error
  def dispatch(%Effect{} = effect) do
    case run_handler(effect) do
      :ok ->
        {:ok, _effect} = Effects.complete(effect)
        :ok

      {:ok, _result} ->
        {:ok, _effect} = Effects.complete(effect)
        :ok

      {:error, reason} ->
        # The log carries a bounded code, never the payload: the durable
        # `last_error` column is where the detail belongs, redacted once on the
        # way in.
        Logger.warning(
          "effect_failed kind=#{effect.kind} effect=#{effect.id} " <>
            "attempt=#{effect.attempts} code=#{Effects.error_code(reason)}"
        )

        {:ok, _effect} = Effects.fail(effect, reason)
        :error
    end
  end

  @impl GenServer
  def init(options) do
    state = %{
      identity: Keyword.get_lazy(options, :identity, &default_identity/0),
      interval: Keyword.get(options, :interval, @default_interval),
      limit: Keyword.get(options, :limit, 20),
      lease_seconds: Keyword.get(options, :lease_seconds, Effects.lease_seconds()),
      poll: Keyword.get(options, :poll, true)
    }

    if state.poll, do: schedule(state)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:tick, _from, state), do: {:reply, pass(state), state}

  @impl GenServer
  def handle_info(:tick, state) do
    _pass = pass(state)
    schedule(state)
    {:noreply, state}
  end

  defp pass(state) do
    run_once(identity: state.identity, limit: state.limit, lease_seconds: state.lease_seconds)
  end

  defp run_handler(%Effect{} = effect) do
    case Registry.fetch(effect.kind) do
      {:ok, handler} ->
        try do
          handler.run(effect, effect.idempotency_key)
        rescue
          error -> {:error, {:raised, Exception.message(error)}}
        catch
          kind, reason -> {:error, {kind, inspect(reason, limit: 20)}}
        end

      {:error, :unknown_kind} ->
        {:error, {:unknown_kind, effect.kind}}
    end
  end

  defp schedule(%{interval: interval}), do: Process.send_after(self(), :tick, interval)

  defp default_identity do
    "#{node()}/#{:erlang.phash2(self())}"
  end
end
