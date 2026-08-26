defmodule OpenAgents.Memories.Retrieval.Lexical do
  @moduledoc """
  PostgreSQL full-text scoring over memory bodies. **This is the stand-in, not
  the target.**

  The workspace retrieval rule is that user-facing retrieval routes on meaning,
  not on words: embeddings and cosine similarity, which
  `OpenAgents.Memories.Retrieval.Semantic` implements. This module exists so a
  deployment with no embedding credential still recalls something, and it is
  marked here the way the capability rail marks its own lexical scorer
  (`OpenAgents.Tools.Selector`) rather than being presented as the answer.

  What it cannot do is the reason the marking matters. "Remember I use pnpm,
  not npm" shares no word with "install the deps", so word overlap scores that
  pair at zero. The `user` bucket is attached regardless of score for exactly
  that reason (`OpenAgents.Memories.recall/3`), which is a bound on the damage
  rather than a fix. Only the semantic backend actually connects the two.

  Scoring is `ts_rank_cd` over the generated `search_vector` column, read
  through the partial GIN index on live rows, under the `english` text-search
  configuration so that stop words drop out and words stem.

  The query is the turn's words joined with `or`, not with the `and` that
  `websearch_to_tsquery` defaults to. A turn is a sentence, not a search box:
  requiring every word of "the migration failed" to appear in a memory would
  match nothing an account ever wrote. Sharing one content word is the bar,
  which is the same bar the issue states for the `learned` bucket, and stop
  words are gone before it is applied so "the" cannot clear it.
  """

  @behaviour OpenAgents.Memories.Retrieval

  import Ecto.Query

  alias OpenAgents.Memories.Memory
  alias OpenAgents.Repo

  # Only what fits a text-search query. A whole conversation turn pasted into
  # `websearch_to_tsquery` costs more to parse than the ranking is worth.
  @maximum_query_characters 512
  @maximum_query_words 64

  # A word the parser would read as an operator rather than as a word. They are
  # stripped so a turn saying "or" cannot produce `or or or` and fail to parse.
  @operators ~w(or and not)

  @impl true
  def available?, do: true

  # Any match at all. `ts_rank_cd` is unnormalized and its magnitude means
  # nothing across queries, so the only honest floor is "the words appear".
  @impl true
  def floor, do: 0.0

  @impl true
  def score(user_id, query, candidates) do
    text = prepare(query)
    ids = Enum.map(candidates, & &1.id)

    if text == "" or ids == [] do
      {:ok, %{}}
    else
      {:ok, ranked(user_id, text, ids)}
    end
  rescue
    _error -> :error
  end

  @impl true
  def score_shared(query, candidates) do
    text = prepare(query)
    ids = Enum.map(candidates, & &1.id)

    if text == "" or ids == [] do
      {:ok, %{}}
    else
      {:ok, shared(text, ids)}
    end
  rescue
    _error -> :error
  end

  # `user_id` is the scope predicate, and it is written here rather than
  # inherited from the candidate ids (MEMORY-010). The id list narrows the
  # read; it does not bound it, and a caller that assembled that list wrongly
  # would otherwise reach another account's rows through this query.
  defp ranked(user_id, text, ids) do
    from(memory in Memory,
      where: memory.user_id == ^user_id,
      where: is_nil(memory.superseded_by_id),
      where: memory.id in ^ids,
      where: fragment("? @@ websearch_to_tsquery('english', ?)", memory.search_vector, ^text),
      select: {
        memory.id,
        fragment(
          "ts_rank_cd(?, websearch_to_tsquery('english', ?), 32)",
          memory.search_vector,
          ^text
        )
      }
    )
    |> Repo.all()
    |> Map.new(fn {id, rank} -> {id, rank / 1} end)
  end

  # The shared bucket's ranking query, and the one query in this module that
  # names no account. `bucket` is what stands in its place, which is
  # MEMORY-001's amendment written as a predicate rather than as a filter over
  # the result: a caller who assembled the candidate ids wrongly still cannot
  # reach an account-scoped row through this read. The caller narrowed those
  # ids to admitted, live, `ledger`-or-above rows before it got here
  # (`OpenAgents.Memories.SystemRecall`); this query re-states the two
  # predicates it can state cheaply rather than trusting the list alone.
  defp shared(text, ids) do
    from(memory in Memory,
      where: memory.bucket == "system",
      where: is_nil(memory.superseded_by_id),
      where: memory.id in ^ids,
      where: fragment("? @@ websearch_to_tsquery('english', ?)", memory.search_vector, ^text),
      select: {
        memory.id,
        fragment(
          "ts_rank_cd(?, websearch_to_tsquery('english', ?), 32)",
          memory.search_vector,
          ^text
        )
      }
    )
    |> Repo.all()
    |> Map.new(fn {id, rank} -> {id, rank / 1} end)
  end

  # `websearch_to_tsquery` reads `-` as negation, quotes as phrases, and `or`
  # as disjunction. A turn carrying punctuation would ask for something the
  # reader did not, so everything but letters and digits goes first; then the
  # words are rejoined with `or`, which is the operator this wants and not the
  # one the parser assumes.
  defp prepare(query) do
    query
    |> String.slice(0, @maximum_query_characters)
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.reject(&(&1 in @operators))
    |> Enum.take(@maximum_query_words)
    |> Enum.join(" or ")
  end
end
