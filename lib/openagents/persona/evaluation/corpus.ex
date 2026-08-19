defmodule OpenAgents.Persona.Evaluation.Corpus do
  @moduledoc "Loads and validates the committed, source-labeled persona regression corpus."

  alias OpenAgents.Persona.SourceManifest
  alias OpenAgents.Provenance.Canonical

  @path "sarah/evals/persona/corpus.v1.json"
  @schema "sarah.persona.eval_corpus.v1"
  @required_journeys ~w(greeting identity malformed_input correction capability_boundary)
  @properties ~w(
    ai_disclosure
    answer_first
    calibrated_uncertainty
    capability_honesty
    correction_acknowledgement
    executor_disclosure
    historical_evidence_boundary
    one_question
    openagent_identity
    restrained_humor
    source_state_grammar
  )

  @type reason :: atom() | tuple()

  @spec load() :: {:ok, map()} | {:error, reason()}
  def load do
    with {:ok, path} <- corpus_path(),
         {:ok, contents} <- File.read(path),
         {:ok, corpus} <- Jason.decode(contents),
         {:ok, manifest} <- SourceManifest.load(),
         :ok <- validate(corpus, manifest) do
      {:ok, Map.put(corpus, "digest", Canonical.digest!(corpus))}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_corpus_json}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec load!() :: map()
  def load! do
    case load() do
      {:ok, corpus} ->
        corpus

      {:error, reason} ->
        raise ArgumentError, "invalid persona regression corpus: #{inspect(reason)}"
    end
  end

  @spec validate(term(), term()) :: :ok | {:error, reason()}
  def validate(%{"schema" => @schema, "cases" => cases} = corpus, %{"sources" => sources})
      when is_list(cases) and is_list(sources) do
    source_index = Map.new(sources, &{&1["id"], &1})

    with :ok <- validate_top_level(corpus),
         :ok <- validate_cases(cases, source_index),
         :ok <- validate_required_journeys(cases),
         :ok <- validate_unique_case_ids(cases) do
      :ok
    end
  end

  def validate(_corpus, _manifest), do: {:error, :invalid_corpus_shape}

  defp validate_top_level(corpus) do
    cond do
      corpus["id"] != "sarah.persona.regression.v1" ->
        {:error, :invalid_corpus_id}

      corpus["revision"] != 1 ->
        {:error, :invalid_corpus_revision}

      not is_number(corpus["minimum_score"]) ->
        {:error, :invalid_minimum_score}

      corpus["minimum_score"] < 0.0 or corpus["minimum_score"] > 1.0 ->
        {:error, :invalid_minimum_score}

      true ->
        :ok
    end
  end

  defp validate_cases(cases, source_index) when length(cases) in 5..100 do
    Enum.reduce_while(cases, :ok, fn regression_case, :ok ->
      case validate_case(regression_case, source_index) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_cases(_cases, _source_index), do: {:error, :invalid_case_count}

  defp validate_case(regression_case, source_index) when is_map(regression_case) do
    case_id = regression_case["id"]

    cond do
      not bounded_string?(case_id, 80) ->
        {:error, :invalid_case_id}

      not bounded_string?(regression_case["journey"], 80) ->
        {:error, {:invalid_case_journey, case_id}}

      not bounded_string?(regression_case["prompt"], 2_000) ->
        {:error, {:invalid_case_prompt, case_id}}

      not valid_string_list?(regression_case["required_properties"], @properties, 20) ->
        {:error, {:invalid_required_properties, case_id}}

      not valid_terms?(regression_case["forbidden_terms"]) ->
        {:error, {:invalid_forbidden_terms, case_id}}

      true ->
        validate_evidence(regression_case["evidence"], case_id, source_index)
    end
  end

  defp validate_case(_case, _source_index), do: {:error, :invalid_case}

  defp validate_evidence(evidence, case_id, source_index)
       when is_list(evidence) and length(evidence) in 1..8 do
    Enum.reduce_while(evidence, :ok, fn label, :ok ->
      if is_map(label) do
        source = source_index[label["source_id"]]

        cond do
          is_nil(source) ->
            {:halt, {:error, {:unknown_evidence_source, case_id, label["source_id"]}}}

          label["status"] != source["status"] ->
            {:halt, {:error, {:evidence_status_mismatch, case_id, label["source_id"]}}}

          label["use"] not in source["admitted_uses"] ->
            {:halt, {:error, {:evidence_use_not_admitted, case_id, label["source_id"]}}}

          true ->
            {:cont, :ok}
        end
      else
        {:halt, {:error, {:invalid_evidence_label, case_id}}}
      end
    end)
  end

  defp validate_evidence(_evidence, case_id, _source_index),
    do: {:error, {:invalid_evidence, case_id}}

  defp validate_required_journeys(cases) do
    journeys = MapSet.new(cases, & &1["journey"])

    case Enum.find(@required_journeys, &(not MapSet.member?(journeys, &1))) do
      nil -> :ok
      journey -> {:error, {:missing_required_journey, journey}}
    end
  end

  defp validate_unique_case_ids(cases) do
    ids = Enum.map(cases, & &1["id"])
    if length(ids) == length(Enum.uniq(ids)), do: :ok, else: {:error, :duplicate_case_id}
  end

  defp valid_string_list?(values, allowed, maximum)
       when is_list(values) and length(values) > 0 and length(values) <= maximum do
    Enum.all?(values, &(&1 in allowed)) and length(values) == length(Enum.uniq(values))
  end

  defp valid_string_list?(_values, _allowed, _maximum), do: false

  defp valid_terms?(terms) when is_list(terms) and length(terms) in 1..30 do
    Enum.all?(terms, &bounded_string?(&1, 100))
  end

  defp valid_terms?(_terms), do: false

  defp bounded_string?(value, maximum),
    do: is_binary(value) and value != "" and byte_size(value) <= maximum

  defp corpus_path do
    case :code.priv_dir(:sarah) do
      path when is_list(path) -> {:ok, Path.join(List.to_string(path), @path)}
      {:error, reason} -> {:error, {:priv_dir_unavailable, reason}}
    end
  end
end
