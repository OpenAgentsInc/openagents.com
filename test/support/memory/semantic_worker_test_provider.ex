defmodule OpenAgents.Memory.SemanticWorkerTestProvider do
  @moduledoc false

  @behaviour OpenAgents.Memory.EmbeddingProvider

  @impl true
  def embed(_text, %{dimensions: dimensions}) do
    case Application.fetch_env!(:openagents, :semantic_worker_test_mode) do
      :success ->
        {:ok, List.duplicate(0.0, dimensions)}

      :failure ->
        {:error, :semantic_provider_offline}

      {:block, observer} when is_pid(observer) ->
        send(observer, {:semantic_provider_started, self()})

        receive do
          :release_semantic_provider -> {:ok, List.duplicate(0.0, dimensions)}
        after
          60_000 -> {:error, :semantic_provider_timeout}
        end
    end
  end
end
