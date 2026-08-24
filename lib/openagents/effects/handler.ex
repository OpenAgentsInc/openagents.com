defmodule OpenAgents.Effects.Handler do
  @moduledoc """
  What a durable effect's kind resolves to.

  A handler is given the effect and its deterministic idempotency key, and
  nothing else. Everything it needs is in `effect.payload`, because a handler
  that reads ambient state is not replayable, and a redelivered effect is a
  replay.

  The key is stable across retries, restarts, and nodes, so a handler that
  reaches something outside this system can hand it that key and let the far
  side dedupe. A handler that cannot do that must be idempotent some other way:
  `run/2` will be called more than once for one effect whenever a worker dies
  between doing the work and recording that it did.

  Returning `{:error, reason}` — or raising — is a retry, until the effect's
  `maximum_attempts`.
  """

  alias OpenAgents.Effects.Effect

  @callback run(effect :: Effect.t(), idempotency_key :: String.t()) ::
              :ok | {:ok, term()} | {:error, term()}
end
