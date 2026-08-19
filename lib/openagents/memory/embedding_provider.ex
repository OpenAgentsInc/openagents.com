defmodule OpenAgents.Memory.EmbeddingProvider do
  @moduledoc "Provider-neutral embedding boundary for disposable semantic recall derivatives."

  @callback embed(String.t(), map()) :: {:ok, [float()]} | {:error, atom()}
end
