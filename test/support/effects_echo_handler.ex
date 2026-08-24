defmodule OpenAgents.EffectsEchoHandler do
  @moduledoc """
  The effect handler the outbox tests script (EFFECT-001).

  It reports the effect body and its deterministic idempotency key back to the
  process registered as `:effects_test_observer`, so a test can assert what a
  handler actually received — including that redelivery hands it the same key
  every time. A payload carrying `"raise"` raises instead, so a test can prove
  that a handler blowing up is a retry rather than a lost effect.
  """

  @behaviour OpenAgents.Effects.Handler

  alias OpenAgents.Effects.Effect

  @impl OpenAgents.Effects.Handler
  def run(%Effect{payload: %{"raise" => message}}, _idempotency_key),
    do: raise(RuntimeError, message)

  def run(%Effect{payload: payload} = effect, idempotency_key) do
    case Application.get_env(:openagents, :effects_test_observer) do
      pid when is_pid(pid) ->
        send(pid, {:effect_ran, Map.get(payload, "body"), idempotency_key, effect.id})

      _absent ->
        :ok
    end

    :ok
  end
end
