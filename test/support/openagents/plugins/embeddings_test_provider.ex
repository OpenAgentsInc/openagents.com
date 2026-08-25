defmodule OpenAgents.Plugins.EmbeddingsTestProvider do
  @moduledoc false

  @behaviour OpenAgents.Memory.EmbeddingProvider

  @words ["git", "history", "weather", "forecast"]

  @impl true
  def embed(text, %{dimensions: dimensions}) do
    vector = for _ <- 1..dimensions, do: 0.0
    tokens = text |> String.downcase() |> String.split(~r/[^a-z0-9]+/u, trim: true)

    vector =
      Enum.reduce(tokens, vector, fn token, acc ->
        case Enum.find_index(@words, &(&1 == token)) do
          nil ->
            acc

          idx when idx < dimensions ->
            List.update_at(acc, idx, &(&1 + 1.0))

          _other ->
            acc
        end
      end)

    {:ok, vector}
  end
end
