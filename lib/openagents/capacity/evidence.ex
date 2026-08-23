defmodule OpenAgents.Capacity.Evidence do
  @moduledoc false

  @callback fetch(term()) :: {:ok, map()} | {:error, term()}
  @callback read(term()) :: {:ok, map()} | {:error, term()}

  @optional_callbacks read: 1
end
