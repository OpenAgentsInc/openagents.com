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

  @callback stream(
              OpenAgents.Providers.Request.t(),
              (OpenAgents.Providers.ProviderEvent.t() -> any())
            ) :: :ok | {:error, OpenAgents.Providers.ProviderEvent.failure_reason()}
end
