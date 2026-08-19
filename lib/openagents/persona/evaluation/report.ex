defmodule OpenAgents.Persona.Evaluation.Report do
  @moduledoc "Builds a bounded, revision-identifying report from deterministic case scores."

  alias OpenAgents.Persona
  alias OpenAgents.Provenance.Canonical

  @schema "sarah.persona.eval_report.v1"

  @spec build(map(), Persona.t(), String.t(), [map()]) :: map()
  def build(corpus, %Persona{} = persona, model_id, results)
      when is_binary(model_id) and model_id != "" and is_list(results) do
    scores = Enum.map(results, & &1["score"])
    score = if scores == [], do: 0.0, else: Enum.sum(scores) / length(scores)
    expected_case_ids = MapSet.new(corpus["cases"], & &1["id"])
    actual_case_ids = MapSet.new(results, & &1["case_id"])

    passed =
      expected_case_ids == actual_case_ids and
        Enum.all?(results, & &1["passed"]) and
        score >= corpus["minimum_score"]

    report = %{
      "schema" => @schema,
      "corpus_id" => corpus["id"],
      "corpus_revision" => corpus["revision"],
      "corpus_digest" => corpus["digest"],
      "persona_id" => persona.id,
      "persona_version" => persona.version,
      "persona_digest" => persona.digest,
      "source_manifest_id" => persona.source_manifest_id,
      "source_manifest_digest" => persona.source_manifest_digest,
      "model_id" => model_id,
      "minimum_score" => corpus["minimum_score"],
      "score" => score,
      "passed" => passed,
      "results" => results
    }

    Map.put(report, "report_digest", Canonical.digest!(report))
  end
end
