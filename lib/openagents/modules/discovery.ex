defmodule OpenAgents.Modules.Discovery do
  @moduledoc "Bounded, non-authorizing search over one captured admitted module registry."

  alias OpenAgents.Modules.{Artifact, Registry}
  alias OpenAgents.Tools.{Embeddings, Snapshot}
  alias OpenAgents.Tools.Discovery.Doc

  @maximum_results 20
  @allowed_filters ~w(query tags capability side_effect data_scope cost quality jurisdiction publisher compatibility include_deprecated first)

  @spec search(Snapshot.t(), map()) :: {:ok, map()} | {:error, atom()}
  def search(%Snapshot{} = snapshot, filters) when is_map(filters) do
    with :ok <- validate_filters(filters) do
      tools_by_module = tools_by_module(snapshot)

      matches =
        snapshot
        |> selectable(filters)
        |> Enum.filter(&matches?(&1, filters))
        |> filter_by_tags(filters, tools_by_module)
        |> rank_by_query(filters, tools_by_module, snapshot.digest)

      first = Map.get(filters, "first", 10)
      selected = Enum.take(matches, first)

      {:ok,
       %{
         "schema" => "sarah.module_discovery.v1",
         "registry_digest" => snapshot.digest,
         "matches" => Enum.map(selected, &projection(&1, snapshot.digest)),
         "truncated" => length(matches) > length(selected)
       }}
    end
  end

  def search(%Snapshot{}, _filters), do: {:error, :module_discovery_filters_invalid}

  # Artifacts carry no description; the Tool struct does. Map module_id → Tool so
  # tag and query matching can read the searchable document (name + description +
  # tags) rather than the brittle module_id substring.
  defp tools_by_module(%Snapshot{tools: tools}) do
    Map.new(Map.values(tools), fn tool -> {tool.module_id, tool} end)
  end

  defp filter_by_tags(artifacts, filters, tools_by_module) do
    case Map.get(filters, "tags") do
      nil ->
        artifacts

      raw ->
        wanted = raw |> parse_tags() |> MapSet.new()

        if MapSet.size(wanted) == 0 do
          artifacts
        else
          Enum.filter(artifacts, fn artifact ->
            case Map.fetch(tools_by_module, artifact.module_id) do
              {:ok, tool} -> not MapSet.disjoint?(Doc.tags(tool), wanted)
              :error -> false
            end
          end)
        end
    end
  end

  # A `query` ranks by relevance over the tool document (cosine when the
  # embedding index is warm, always plus lexical overlap) and drops zero-score
  # candidates. Without a query the artifact order is preserved.
  defp rank_by_query(artifacts, filters, tools_by_module, digest) do
    case Map.get(filters, "query") do
      query when is_binary(query) and query != "" ->
        query_vector =
          case Embeddings.embed_query(query) do
            {:ok, vector} -> vector
            _absent -> nil
          end

        vectors = Embeddings.vectors(digest)
        query_tokens = Doc.tokenize(query)

        artifacts
        |> Enum.map(fn artifact ->
          {artifact, relevance(artifact, tools_by_module, query_tokens, query_vector, vectors)}
        end)
        |> Enum.filter(fn {_artifact, score} -> score > 0.0 end)
        |> Enum.sort_by(fn {artifact, score} -> {-score, artifact.module_id} end)
        |> Enum.map(&elem(&1, 0))

      _absent ->
        artifacts
    end
  end

  defp relevance(artifact, tools_by_module, query_tokens, query_vector, vectors) do
    case Map.fetch(tools_by_module, artifact.module_id) do
      {:ok, tool} ->
        lexical =
          case MapSet.size(query_tokens) do
            0 -> 0.0
            n -> MapSet.size(MapSet.intersection(query_tokens, Doc.tokens(tool))) / n
          end

        embedding =
          case {query_vector, vectors} do
            {v, m} when is_list(v) and is_map(m) and is_map_key(m, tool.name) ->
              max(0.0, Embeddings.cosine(v, Map.fetch!(m, tool.name)))

            _absent ->
              nil
          end

        case embedding do
          nil -> lexical
          score -> 0.7 * score + 0.3 * lexical
        end

      :error ->
        0.0
    end
  end

  defp parse_tags(tags) when is_list(tags),
    do: tags |> Enum.map(&String.downcase(to_string(&1))) |> Enum.reject(&(&1 == ""))

  defp parse_tags(tags) when is_binary(tags),
    do: tags |> String.split(~r/[,\s]+/, trim: true) |> Enum.map(&String.downcase/1)

  defp parse_tags(_tags), do: []

  @spec revalidate(Snapshot.t(), map()) :: {:ok, Artifact.t()} | {:error, atom()}
  def revalidate(%Snapshot{} = snapshot, reference) when is_map(reference) do
    cond do
      reference["registry_digest"] != snapshot.digest ->
        {:error, :stale_module_registry}

      true ->
        with {:ok, artifact} <-
               Registry.fetch(snapshot, reference["module_id"], reference["version"]),
             true <- artifact.artifact_digest == reference["artifact_digest"] do
          {:ok, artifact}
        else
          false -> {:error, :stale_module_artifact}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def revalidate(%Snapshot{}, _reference), do: {:error, :module_reference_invalid}

  defp selectable(snapshot, %{"include_deprecated" => true}), do: Registry.discover(snapshot)

  defp selectable(snapshot, _filters),
    do: snapshot |> Registry.discover() |> Enum.filter(&(&1.state == "admitted"))

  defp matches?(artifact, filters) do
    Enum.all?(filters, fn
      # `query` and `tags` are handled by rank_by_query/filter_by_tags over the
      # tool document, not here.
      {"query", _value} -> true
      {"tags", _value} -> true
      {"capability", value} -> value in artifact.capability_scopes
      {"side_effect", value} -> artifact.side_effect_class == value
      {"data_scope", value} -> value in artifact.data_scopes
      {"cost", value} -> artifact.facets["cost"] == value
      {"quality", value} -> artifact.facets["quality"] == value
      {"jurisdiction", value} -> artifact.facets["jurisdiction"] == value
      {"publisher", value} -> artifact.publisher == value
      {"compatibility", value} -> compatible?(artifact, value)
      {key, _value} when key in ["include_deprecated", "first"] -> true
    end)
  end

  defp compatible?(artifact, runtime) do
    artifact.compatibility["runtime_min"] <= runtime and
      artifact.compatibility["runtime_max"] >= runtime
  end

  defp projection(artifact, registry_digest) do
    projection = %{
      "module_id" => artifact.module_id,
      "version" => artifact.version,
      "artifact_digest" => artifact.artifact_digest,
      "registry_digest" => registry_digest,
      "state" => artifact.state,
      "side_effect" => artifact.side_effect_class,
      "approval_class" => artifact.approval_class,
      "capability_scopes" => artifact.capability_scopes,
      "data_scopes" => artifact.data_scopes,
      "facets" =>
        Map.take(
          artifact.facets,
          ~w(cost cost_units quality residency privacy jurisdiction censorship_resistance)
        ),
      "publisher" => artifact.publisher,
      "compatibility" => Map.take(artifact.compatibility, ~w(runtime_min runtime_max)),
      "attribution_required" => artifact.attribution_policy["required"]
    }

    if artifact.deprecation,
      do: Map.put(projection, "deprecation", artifact.deprecation),
      else: projection
  end

  defp validate_filters(filters) do
    cond do
      map_size(filters) > length(@allowed_filters) ->
        {:error, :module_discovery_filters_invalid}

      Enum.any?(Map.keys(filters), &(&1 not in @allowed_filters)) ->
        {:error, :module_discovery_filter_unknown}

      not valid_string_filter?(filters, "query", 128) ->
        {:error, :module_discovery_query_invalid}

      Enum.any?(
        ~w(capability side_effect data_scope cost quality jurisdiction publisher),
        fn key ->
          not valid_string_filter?(filters, key, 128)
        end
      ) ->
        {:error, :module_discovery_filters_invalid}

      not valid_tags_filter?(filters) ->
        {:error, :module_discovery_filters_invalid}

      Map.has_key?(filters, "compatibility") and
          (not is_integer(filters["compatibility"]) or filters["compatibility"] < 1) ->
        {:error, :module_discovery_compatibility_invalid}

      Map.has_key?(filters, "include_deprecated") and
          not is_boolean(filters["include_deprecated"]) ->
        {:error, :module_discovery_filters_invalid}

      not is_integer(Map.get(filters, "first", 10)) or
          Map.get(filters, "first", 10) not in 1..@maximum_results ->
        {:error, :module_discovery_limit_invalid}

      true ->
        :ok
    end
  end

  # `tags` may be a comma/space-separated string or a bounded list of short
  # strings — both forms parse to the same tag set.
  defp valid_tags_filter?(filters) do
    case Map.fetch(filters, "tags") do
      :error ->
        true

      {:ok, value} when is_binary(value) ->
        byte_size(value) in 1..256

      {:ok, value} when is_list(value) ->
        length(value) in 1..16 and
          Enum.all?(value, &(is_binary(&1) and byte_size(&1) in 1..64))

      {:ok, _other} ->
        false
    end
  end

  defp valid_string_filter?(filters, key, maximum) do
    case Map.fetch(filters, key) do
      :error -> true
      {:ok, value} -> is_binary(value) and byte_size(value) in 1..maximum
    end
  end
end
