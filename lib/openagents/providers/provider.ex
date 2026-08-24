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

  @optional_callbacks configured?: 0

  @callback stream(
              OpenAgents.Providers.Request.t(),
              (OpenAgents.Providers.ProviderEvent.t() -> any())
            ) :: :ok | {:error, OpenAgents.Providers.ProviderEvent.failure_reason()}
end
