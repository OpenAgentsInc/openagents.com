defmodule OpenAgents.Capacity.Evidence do
  @moduledoc false

  @callback fetch(term()) :: {:ok, map()} | {:error, term()}
end
