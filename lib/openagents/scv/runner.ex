defmodule OpenAgents.SCV.Runner do
  @moduledoc "Defines how an admitted environment executes an SCV driver."

  alias OpenAgents.SCV.Run

  @callback id() :: String.t()
  @callback run(Run.t()) :: {:ok, map()} | {:error, term()}
end
