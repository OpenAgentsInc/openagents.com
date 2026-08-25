defmodule OpenAgents.Memories.SynonymEmbeddingsProvider do
  @moduledoc """
  A deterministic embedding provider that puts related words in one dimension.

  The point of the target retrieval backend is that it connects text sharing no
  word — "install the deps" and "I use pnpm, not npm" — so a test provider that
  embedded by token would prove nothing the lexical stand-in does not already
  do. This one maps a small set of related words onto shared dimensions, which
  is the property a real embedding has and the property recall depends on.
  """

  @behaviour OpenAgents.Memory.EmbeddingProvider

  # Each list is one dimension: words in it embed toward each other.
  @topics [
    ~w(install deps dependencies pnpm npm yarn packages),
    ~w(deploy release ship promote production),
    ~w(test suite spec assertion coverage)
  ]

  @impl true
  def embed(text, %{dimensions: dimensions}) do
    tokens = text |> String.downcase() |> String.split(~r/[^a-z0-9]+/u, trim: true)

    vector =
      for index <- 0..(dimensions - 1) do
        case Enum.at(@topics, index) do
          nil -> 0.0
          words -> tokens |> Enum.count(&(&1 in words)) |> :erlang.float()
        end
      end

    {:ok, vector}
  end
end
