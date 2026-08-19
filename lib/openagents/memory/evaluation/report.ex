defmodule OpenAgents.Memory.Evaluation.Report do
  @moduledoc "Builds the deterministic, revision-bound recall release report."

  alias OpenAgents.Provenance.Canonical

  @schema "sarah.recall.eval_report.v1"

  @spec build(map(), [map()]) :: map()
  def build(corpus, results) when is_map(corpus) and is_list(results) do
    metrics = metrics(corpus["cases"], results)
    thresholds = corpus["thresholds"]
    expected_case_ids = MapSet.new(corpus["cases"], & &1["id"])
    actual_case_ids = MapSet.new(results, & &1["case_id"])

    complete? =
      expected_case_ids == actual_case_ids and length(results) == MapSet.size(actual_case_ids)

    report = %{
      "schema" => @schema,
      "corpus_id" => corpus["id"],
      "corpus_revision" => corpus["revision"],
      "corpus_digest" => corpus["digest"],
      "thresholds" => thresholds,
      "metrics" => metrics,
      "passed" =>
        complete? and thresholds_met?(metrics, thresholds) and
          Enum.all?(results, & &1["case_passed"]),
      "results" => results
    }

    Map.put(report, "report_digest", Canonical.digest!(report))
  end

  defp metrics(cases, results) do
    case_index = Map.new(cases, &{&1["id"], &1})
    {relevant_3, returned_3} = precision_counts(results, case_index, "retrieved_at_3")
    {relevant_10, returned_10} = precision_counts(results, case_index, "retrieved_at_10")

    claims =
      Enum.flat_map(cases, fn evaluation_case ->
        Enum.map(evaluation_case["answer"]["claims"], fn claim ->
          {claim, evaluation_case["answer"]["used_labels"]}
        end)
      end)

    supported_claims = Enum.count(claims, &supported_claim?/1)
    unsupported_claims = length(claims) - supported_claims

    %{
      "precision_at_3" => ratio(relevant_3, returned_3),
      "precision_at_10" => ratio(relevant_10, returned_10),
      "grounded_answer_rate" => ratio(supported_claims, length(claims)),
      "unsupported_memory_claims" => unsupported_claims,
      "correction_recognition" => journey_rate(cases, "current_correction", "current_correction"),
      "no_result_honesty" => journey_rate(cases, "no_result", "no_result_honest"),
      "cross_scope_leakage" => Enum.sum(Enum.map(results, & &1["foreign_ref_count"])),
      "degradation_honesty" => journey_rate(cases, "lexical_degradation", "degraded_honest")
    }
  end

  defp precision_counts(results, case_index, key) do
    Enum.reduce(results, {0, 0}, fn result, {relevant, returned} ->
      expected = MapSet.new(case_index[result["case_id"]]["relevant_labels"])

      if MapSet.size(expected) == 0 do
        {relevant, returned}
      else
        retrieved = result[key]
        hits = Enum.count(retrieved, &MapSet.member?(expected, &1))
        {relevant + hits, returned + length(retrieved)}
      end
    end)
  end

  defp supported_claim?({%{"uncertain" => true}, _used_labels}), do: true

  defp supported_claim?({%{"source_labels" => source_labels}, used_labels}) do
    source_labels != [] and
      MapSet.subset?(MapSet.new(source_labels), MapSet.new(used_labels))
  end

  defp journey_rate(cases, journey, property) do
    selected = Enum.filter(cases, &(&1["journey"] == journey))
    ratio(Enum.count(selected, & &1["answer"][property]), length(selected))
  end

  defp ratio(_numerator, 0), do: 1.0
  defp ratio(numerator, denominator), do: numerator / denominator

  defp thresholds_met?(metrics, thresholds) do
    Enum.all?(thresholds, fn
      {key, threshold} when key in ["unsupported_memory_claims", "cross_scope_leakage"] ->
        metrics[key] <= threshold

      {key, threshold} ->
        metrics[key] >= threshold
    end)
  end
end
