defmodule OpenAgents.Tools.Selector do
  @moduledoc """
  Chooses which tools to expose to the model for a turn — the system doing the
  lookup so the model never has to. There is no all-or-nothing "direct mode":
  every turn ranks the catalog against the turn's intent and exposes the top-K.

  Ranking blends cosine similarity over tool-description embeddings (when the
  embedding index is warm) with a lexical overlap score, and always falls back
  to lexical alone when embeddings are unavailable — a turn is never starved of
  tools because the vector index is cold. `module_discover` is always included
  as an explicit escape hatch so the model can search further when the automatic
  selection missed something. When the owner has an active paired computer,
  `computer_list`, `computer_probe`, and `computer_agent` are always included
  too so a short follow-up cannot drop the delegation chain.

  Ranking runs over the tools this caller can actually reach. Pass
  `:reach` — an `OpenAgents.Tools.Reach.Caller` — and every tool whose
  declared reach the caller does not hold is dropped before scoring, so an
  unreachable tool neither takes a top-K slot nor survives as an
  always-include. Omitting `:reach` ranks the whole catalog and is only for
  callers with no turn behind them, such as registry inspection.
  """

  alias OpenAgents.Tools.{Embeddings, Reach, Snapshot}
  alias OpenAgents.Tools.Discovery.Doc

  @always_included ["module_discover"]
  @paired_computer_tools ["computer_list", "computer_probe", "computer_agent"]
  @embedding_weight 0.7
  @lexical_weight 0.3

  @doc """
  Names that must stay in the exposed set. Always includes `module_discover`.
  `opts[:always_include]` adds extra names; `opts[:computer_paired?]` adds the
  computer delegation chain.
  """
  @spec always_include(keyword()) :: [String.t()]
  def always_include(opts \\ []) do
    extras = opts |> Keyword.get(:always_include, []) |> List.wrap()

    extras =
      if Keyword.get(opts, :computer_paired?, false) do
        extras ++ @paired_computer_tools
      else
        extras
      end

    Enum.uniq(@always_included ++ extras)
  end

  @doc """
  Rank the snapshot's tools against `intent` and return `{tools, omitted_count}`,
  the selected `Tool` structs highest-relevance first and how many were left
  out. `opts`: `:top_k` (default from config), `:tags` (a MapSet/list to
  require — tag-filtered discovery), `:always_include` (extra tool names that
  must stay exposed), `:computer_paired?` (also keep the computer delegation
  chain), `:reach` (a `Reach.Caller` narrowing the catalog to what this caller
  can reach). Always-includes may exceed `top_k` by a small fixed number.
  """
  @spec select(Snapshot.t(), String.t() | nil, keyword()) ::
          {[OpenAgents.Tools.Tool.t()], non_neg_integer()}
  def select(%Snapshot{} = snapshot, intent, opts \\ []) do
    top_k = Keyword.get(opts, :top_k, default_top_k())
    always_include = always_include(opts)

    candidates =
      snapshot.tools
      |> Map.values()
      |> reachable(opts[:reach])
      |> tag_filtered(opts[:tags])

    query_vector =
      case intent && Embeddings.embed_query(intent) do
        {:ok, vector} -> vector
        _absent -> nil
      end

    tool_vectors = Embeddings.vectors(snapshot.digest)
    intent_tokens = Doc.tokenize(intent || "")

    ranked =
      candidates
      |> Enum.map(fn tool -> {tool, score(tool, intent_tokens, query_vector, tool_vectors)} end)
      |> Enum.sort_by(fn {tool, score} -> {-score, tool.name} end)
      |> Enum.map(&elem(&1, 0))

    selected = ranked |> Enum.take(top_k) |> ensure_always_included(ranked, always_include)
    {selected, max(length(candidates) - length(selected), 0)}
  end

  @doc "Convenience: just the selected `Tool` structs."
  @spec select_tools(Snapshot.t(), String.t() | nil, keyword()) :: [OpenAgents.Tools.Tool.t()]
  def select_tools(snapshot, intent, opts \\ []) do
    {tools, _omitted} = select(snapshot, intent, opts)
    tools
  end

  # ── scoring ──────────────────────────────────────────────────────────────

  defp score(tool, intent_tokens, query_vector, tool_vectors) do
    lexical = lexical_score(intent_tokens, Doc.tokens(tool))

    case embedding_score(tool, query_vector, tool_vectors) do
      nil -> lexical
      embedding -> @embedding_weight * embedding + @lexical_weight * lexical
    end
  end

  defp embedding_score(tool, query_vector, tool_vectors)
       when is_list(query_vector) and is_map(tool_vectors) do
    case Map.fetch(tool_vectors, tool.name) do
      {:ok, vector} -> max(0.0, Embeddings.cosine(query_vector, vector))
      :error -> nil
    end
  end

  defp embedding_score(_tool, _query, _vectors), do: nil

  # Recall of the intent's terms in the tool document: how much of what the user
  # is asking about this tool covers. Empty intent scores 0 for everyone, which
  # is fine — the deterministic name tiebreak still yields a stable set.
  defp lexical_score(intent_tokens, tool_tokens) do
    count = MapSet.size(intent_tokens)

    if count == 0 do
      0.0
    else
      overlap = MapSet.size(MapSet.intersection(intent_tokens, tool_tokens))
      overlap / count
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp reachable(tools, %Reach.Caller{} = caller),
    do: Enum.filter(tools, &Reach.reachable?(&1, caller))

  defp reachable(tools, nil), do: tools

  defp tag_filtered(tools, nil), do: tools

  defp tag_filtered(tools, tags) do
    wanted = tags |> List.wrap() |> Enum.map(&String.downcase(to_string(&1))) |> MapSet.new()

    if MapSet.size(wanted) == 0 do
      tools
    else
      Enum.filter(tools, fn tool ->
        not MapSet.disjoint?(Doc.tags(tool), wanted)
      end)
    end
  end

  defp ensure_always_included(selected, ranked, always_include) do
    selected_names = MapSet.new(selected, & &1.name)

    extras =
      always_include
      |> Enum.reject(&MapSet.member?(selected_names, &1))
      |> Enum.flat_map(fn name ->
        case Enum.find(ranked, &(&1.name == name)) do
          nil -> []
          tool -> [tool]
        end
      end)

    selected ++ extras
  end

  defp default_top_k do
    :openagents
    |> Application.get_env(:tool_discovery, [])
    |> Keyword.get(:top_k, 12)
  end
end
