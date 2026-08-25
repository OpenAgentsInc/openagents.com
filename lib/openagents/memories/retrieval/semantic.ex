defmodule OpenAgents.Memories.Retrieval.Semantic do
  @moduledoc """
  Cosine similarity over memory embeddings. **This is the target backend.**

  Retrieval routes on meaning here rather than on shared words, which is what
  lets "remember I use pnpm, not npm" reach a later "install the deps" — a pair
  the lexical stand-in scores at zero because they have no word in common.

  An account holds few memories, and `OpenAgents.Memories` caps how many are
  live, so the vectors are compared in this process rather than through an
  index. That is the same trade the tool catalog makes in
  `OpenAgents.Tools.Embeddings`: a bounded set does not earn a per-turn
  pgvector query. The embedding itself is written on the row at create time by
  `OpenAgents.Memories.create/2`, under the same provider boundary the rest of
  this repository embeds through (`OpenAgents.Memory.EmbeddingProvider`).

  Every failure degrades rather than raising. No credential, a provider that
  errors, a query the provider will not embed, a row whose vector was written
  under a different model — each one leaves the caller falling back to the
  stand-in or scoring nothing, never failing the turn.
  """

  @behaviour OpenAgents.Memories.Retrieval

  alias OpenAgents.Memories.Memory
  alias OpenAgents.Tools.Embeddings

  @impl true
  def available? do
    config = config()
    Keyword.get(config, :embeddings_enabled, false) == true and not is_nil(config[:provider])
  end

  # A `learned` memory has to be about this turn before it interrupts it.
  # Cosine over a small embedding puts unrelated sentences well under this and
  # related ones well over it.
  @impl true
  def floor, do: Keyword.get(config(), :floor, 0.3)

  # This backend issues no query of its own: it compares vectors already loaded
  # by `OpenAgents.Memories.list/2`, whose read names `user_id`. `user_id` is
  # still taken and still enforced, so a candidate from another account cannot
  # be scored even if a caller assembled the list wrongly (MEMORY-010).
  @impl true
  def score(user_id, query, candidates) do
    with true <- available?(),
         {:ok, vector} <- embed(query) do
      {:ok, cosines(vector, Enum.filter(candidates, &(&1.user_id == user_id)))}
    else
      _unavailable -> :error
    end
  rescue
    _error -> :error
  end

  @doc """
  The embedding to store on a new memory, or `nil` when the rail is off.

  Called on the write path so recall never has to embed the store, only the
  turn. A provider failure returns `nil`: the memory is still written, and it
  is recalled through the stand-in until something re-embeds it.
  """
  @spec embedding_for(String.t()) :: {[float()], String.t()} | nil
  def embedding_for(body) when is_binary(body) do
    case embed(body) do
      {:ok, vector} -> {vector, model_id()}
      :error -> nil
    end
  end

  def embedding_for(_body), do: nil

  @doc "The embedding model rows are written under on this deployment."
  @spec model_id() :: String.t()
  def model_id, do: Keyword.get(config(), :model_id, "text-embedding-3-small")

  defp embed(text) do
    if available?() do
      case provider().embed(text, embed_config()) do
        {:ok, vector} when is_list(vector) and vector != [] -> {:ok, vector}
        _failure -> :error
      end
    else
      :error
    end
  rescue
    _error -> :error
  end

  # A row embedded under a different model is not comparable to this query, so
  # it scores nothing here and reaches the turn through the stand-in instead.
  defp cosines(vector, candidates) do
    model = model_id()

    candidates
    |> Enum.flat_map(fn
      %Memory{embedding: stored, embedding_model: ^model, id: id}
      when is_list(stored) and stored != [] ->
        [{id, Embeddings.cosine(vector, stored)}]

      _unembedded ->
        []
    end)
    |> Map.new()
  end

  # `|| []` rather than a `get_env/3` default: the key can be present and nil,
  # and a nil there would reach `Keyword.get/3` as a hard crash on a path whose
  # whole contract is to degrade.
  defp config, do: Application.get_env(:openagents, :memory_recall) || []

  defp provider, do: Keyword.get(config(), :provider)

  defp embed_config do
    config = config()

    %{
      model_id: model_id(),
      model_version: Keyword.get(config, :model_version, "2024-01"),
      dimensions: Keyword.get(config, :dimensions, 64)
    }
  end
end
