defmodule OpenAgents.Plugins.EmbeddingsErrorProvider do
  @moduledoc false

  @behaviour OpenAgents.Memory.EmbeddingProvider

  @impl true
  def embed(_text, _config), do: {:error, :test_provider_error}
end
