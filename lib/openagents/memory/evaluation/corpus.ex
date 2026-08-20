defmodule OpenAgents.Memory.Evaluation.Corpus do
  @moduledoc "Loads and validates the committed, synthetic recall evaluation corpus."

  alias OpenAgents.Provenance.Canonical

  @path "sarah/evals/recall/corpus.v1.json"
  @schema "sarah.recall.eval_corpus.v1"
  @required_journeys ~w(
    outside_provider_window dated_paraphrase no_result current_correction ambiguity
    truncated_context two_browser_isolation status_exclusion snapshot_freezing lexical_degradation
  )
  @metric_keys ~w(
    precision_at_3 precision_at_10 grounded_answer_rate unsupported_memory_claims
    correction_recognition no_result_honesty cross_scope_leakage degradation_honesty
  )

  @spec load() :: {:ok, map()} | {:error, term()}
  def load do
    with path when is_list(path) <- :code.priv_dir(:openagents),
         {:ok, contents} <- File.read(Path.join(List.to_string(path), @path)),
         {:ok, corpus} <- Jason.decode(contents),
         :ok <- validate(corpus) do
      {:ok, Map.put(corpus, "digest", Canonical.digest!(corpus))}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_corpus_json}
      {:error, reason} -> {:error, reason}
      _unavailable -> {:error, :priv_dir_unavailable}
    end
  end

  @spec load!() :: map()
  def load! do
    case load() do
      {:ok, corpus} -> corpus
      {:error, reason} -> raise ArgumentError, "invalid recall corpus: #{inspect(reason)}"
    end
  end

  @spec validate(term()) :: :ok | {:error, term()}
  def validate(%{"schema" => @schema, "cases" => cases, "thresholds" => thresholds} = corpus)
      when is_list(cases) and is_map(thresholds) do
    with :ok <- validate_identity(corpus),
         :ok <- validate_thresholds(thresholds),
         :ok <- validate_cases(cases),
         :ok <- validate_journeys(cases) do
      :ok
    end
  end

  def validate(_corpus), do: {:error, :invalid_corpus_shape}

  defp validate_identity(corpus) do
    if corpus["id"] == "sarah.recall.regression.v1" and corpus["revision"] == 1,
      do: :ok,
      else: {:error, :invalid_corpus_identity}
  end

  defp validate_thresholds(thresholds) do
    valid_keys? = Map.keys(thresholds) |> Enum.sort() == Enum.sort(@metric_keys)

    valid_values? =
      Enum.all?(thresholds, fn
        {key, value} when key in ["unsupported_memory_claims", "cross_scope_leakage"] ->
          is_integer(value) and value >= 0

        {_key, value} ->
          is_number(value) and value >= 0.0 and value <= 1.0
      end)

    if valid_keys? and valid_values?, do: :ok, else: {:error, :invalid_thresholds}
  end

  defp validate_cases(cases) when length(cases) in 9..50 do
    ids = Enum.map(cases, & &1["id"])

    cond do
      length(ids) != length(Enum.uniq(ids)) -> {:error, :duplicate_case_id}
      Enum.all?(cases, &valid_case?/1) -> :ok
      true -> {:error, :invalid_case}
    end
  end

  defp validate_cases(_cases), do: {:error, :invalid_case_count}

  defp valid_case?(evaluation_case) when is_map(evaluation_case) do
    bounded_string?(evaluation_case["id"], 80) and
      bounded_string?(evaluation_case["journey"], 80) and
      bounded_string?(evaluation_case["query"], 512) and
      is_integer(evaluation_case["first"]) and evaluation_case["first"] in 1..10 and
      is_integer(evaluation_case["filler_count"]) and evaluation_case["filler_count"] in 0..64 and
      valid_messages?(evaluation_case["messages"]) and
      valid_messages?(evaluation_case["foreign_messages"]) and
      valid_labels?(evaluation_case["relevant_labels"]) and
      is_boolean(evaluation_case["expect_empty"]) and
      is_boolean(evaluation_case["expect_truncated"]) and
      is_boolean(evaluation_case["expect_excerpt_truncated"]) and
      is_boolean(evaluation_case["insert_match_after_snapshot"]) and
      valid_answer?(evaluation_case["answer"])
  end

  defp valid_case?(_case), do: false

  defp valid_messages?(messages) when is_list(messages) and length(messages) <= 64 do
    labels = Enum.map(messages, & &1["label"])

    length(labels) == length(Enum.uniq(labels)) and
      Enum.all?(messages, fn message ->
        is_map(message) and bounded_string?(message["label"], 80) and
          message["role"] in ["user", "assistant"] and
          message["status"] in ["complete", "failed", "streaming"] and
          bounded_string?(message["content"], 8_000) and
          is_integer(message["age_seconds"]) and message["age_seconds"] >= 0
      end)
  end

  defp valid_messages?(_messages), do: false

  defp valid_labels?(labels) when is_list(labels) and length(labels) <= 20,
    do:
      Enum.all?(labels, &bounded_string?(&1, 80)) and length(labels) == length(Enum.uniq(labels))

  defp valid_labels?(_labels), do: false

  defp valid_answer?(answer) when is_map(answer) do
    valid_labels?(answer["used_labels"]) and is_list(answer["claims"]) and
      Enum.all?(answer["claims"], fn claim ->
        is_map(claim) and bounded_string?(claim["text"], 800) and
          valid_labels?(claim["source_labels"]) and is_boolean(claim["uncertain"])
      end) and
      Enum.all?(~w(current_correction no_result_honest degraded_honest), fn key ->
        is_boolean(answer[key])
      end)
  end

  defp valid_answer?(_answer), do: false

  defp validate_journeys(cases) do
    journeys = MapSet.new(cases, & &1["journey"])

    case Enum.find(@required_journeys, &(not MapSet.member?(journeys, &1))) do
      nil -> :ok
      journey -> {:error, {:missing_required_journey, journey}}
    end
  end

  defp bounded_string?(value, maximum),
    do: is_binary(value) and value != "" and byte_size(value) <= maximum
end
