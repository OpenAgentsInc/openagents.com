defmodule OpenAgents.Providers.Provider do
  @moduledoc """
  Boundary for generating an assistant response.

  Providers emit Sarah-domain events through the callback. Wire event names,
  raw provider objects, transport exceptions, and SSE framing terminate inside
  the adapter.
  """

  @callback id() :: String.t()

  @type capability :: :text | :tool_calls | :usage
  @callback capabilities() :: [capability()]

  @doc """
  Whether this adapter's credential is configured on this deployment.

  Optional. `OpenAgents.Inference.Models` asks it to publish availability in
  the model catalog and to refuse an unavailable model before a call is made
  (PROVIDER-002). An adapter that does not export it is taken as configured —
  the test adapters need no credential. The answer says only that a secret is
  present, never what it is.
  """
  @callback configured?() :: boolean()

  @doc """
  Whether this adapter may have its request answered by a model other than the
  one it asked for.

  Optional, and `false` where it is not exported: an adapter that calls one
  vendor with one model gets that model or an error. It is `true` only where
  the deployment has configured the lane to substitute — the Vercel AI Gateway
  with a fallback model list — and the answer bounds what silence means. A
  substitutable adapter whose response does not disclose the serving model has
  not told the host what answered, so the host records the model as unresolved
  and prices nothing, rather than recording the requested model as though it
  served (METER-001).
  """
  @callback substitutable?() :: boolean()

  @optional_callbacks configured?: 0, substitutable?: 0

  @callback stream(
              OpenAgents.Providers.Request.t(),
              (OpenAgents.Providers.ProviderEvent.t() -> any())
            ) :: :ok | {:error, OpenAgents.Providers.ProviderEvent.failure_reason()}
end
