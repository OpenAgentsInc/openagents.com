defmodule OpenAgents.Memories.Retrieval do
  @moduledoc """
  The swappable boundary that decides which memories a turn is about.

  Two implementations sit behind one behaviour:

  * `OpenAgents.Memories.Retrieval.Semantic` — **the target.** It embeds the
    incoming input and ranks the account's live memories by cosine similarity
    over the embeddings stored on the rows.
  * `OpenAgents.Memories.Retrieval.Lexical` — **the stand-in.** PostgreSQL
    full-text scoring, marked as a stand-in in the same way the capability
    rail's lexical scorer is (`OpenAgents.Tools.Selector`). It is here so
    recall works on a deployment with no embedding credential, not because
    word overlap is the right way to decide what a sentence is about.

  `rank/3` chooses: the semantic backend when the embedding rail is configured
  and answers, the lexical stand-in otherwise, and the stand-in again when the
  provider errors mid-turn. A turn is never starved of memory because the
  embedding provider is cold, and it is never failed by one either — an
  unreachable backend recalls nothing rather than raising.

  Scores are comparable only within a backend. What crosses the boundary is the
  ordering and the backend's own `floor/0`, never a number a caller interprets.
  """

  alias OpenAgents.Memories.Memory
  alias OpenAgents.Memories.Retrieval.{Lexical, Semantic}

  require Logger

  @typedoc "One ranked memory and the backend's score for it."
  @type ranked :: {Memory.t(), float()}

  @typedoc "Which backend produced a ranking."
  @type backend :: :semantic | :lexical

  @doc """
  Scores `candidates` against `query`, as a map of memory id to score.

  `user_id` is passed rather than inferred from the candidates because
  MEMORY-010 requires the account boundary to be a predicate in every query a
  backend issues. A backend that reads PostgreSQL names the column; the list of
  candidate ids narrows the read, it does not scope it.
  """
  @callback score(user_id :: String.t(), query :: String.t(), candidates :: [Memory.t()]) ::
              {:ok, %{optional(String.t()) => float()}} | :error

  @doc "The score a `learned` memory must clear before it interrupts a turn."
  @callback floor() :: float()

  @doc "Whether this backend is configured on this deployment."
  @callback available?() :: boolean()

  @doc """
  Ranks `candidates` against `query`, highest first.

  Returns `{backend, ranked, floor}`. Every candidate appears, scored; the
  caller decides what the floor means for each bucket, because a `user` memory
  the reader asked for is attached whether or not it shares vocabulary with
  this turn, and a `learned` one is not.
  """
  @spec rank(String.t(), String.t(), [Memory.t()]) :: {backend(), [ranked()], float()}
  def rank(user_id, query, candidates)
      when is_binary(user_id) and is_binary(query) and is_list(candidates) do
    rank(user_id, query, candidates, backend())
  end

  @doc "Ranks with a named backend. Falls back to the stand-in when it cannot answer."
  @spec rank(String.t(), String.t(), [Memory.t()], module()) :: {backend(), [ranked()], float()}
  def rank(_user_id, _query, [], module), do: {name(module), [], module.floor()}

  def rank(user_id, query, candidates, module) do
    case module.score(user_id, query, candidates) do
      {:ok, scores} ->
        {name(module), ordered(candidates, scores), module.floor()}

      :error when module != Lexical ->
        Logger.info("memory_retrieval_fell_back backend=#{name(module)}")
        rank(user_id, query, candidates, Lexical)

      :error ->
        {name(module), ordered(candidates, %{}), module.floor()}
    end
  end

  @doc "The backend this deployment ranks with."
  @spec backend() :: module()
  def backend do
    if Semantic.available?(), do: Semantic, else: Lexical
  end

  @doc "The short name of a backend module, for a note or a log line."
  @spec name(module()) :: backend()
  def name(Semantic), do: :semantic
  def name(_lexical), do: :lexical

  # Highest score first, then newest first, so an account whose memories all
  # score zero still gets a stable, meaningful order rather than table order.
  defp ordered(candidates, scores) do
    candidates
    |> Enum.map(&{&1, Map.get(scores, &1.id, 0.0)})
    |> Enum.sort_by(fn {memory, score} -> {-score, -stamp(memory)} end)
  end

  defp stamp(%Memory{inserted_at: %DateTime{} = at}), do: DateTime.to_unix(at, :microsecond)
  defp stamp(_memory), do: 0
end
