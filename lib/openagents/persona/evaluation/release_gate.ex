defmodule OpenAgents.Persona.Evaluation.ReleaseGate do
  @moduledoc "Verifies that a candidate persona has matching source and regression evidence."

  alias OpenAgents.Persona
  alias OpenAgents.Persona.Evaluation.Corpus
  alias OpenAgents.Persona.SourceManifest
  alias OpenAgents.Provenance.Canonical

  @spec validate(Persona.t(), map(), map(), map()) :: :ok | {:error, atom() | tuple()}
  def validate(%Persona{} = persona, manifest, corpus, report) when is_map(report) do
    with {:ok, _manifest} <- SourceManifest.validate(manifest),
         :ok <- Corpus.validate(corpus, manifest),
         :ok <- validate_identity(persona, manifest, corpus, report),
         :ok <- validate_report_digest(report),
         :ok <- validate_results(corpus, report) do
      :ok
    end
  end

  def validate(_persona, _manifest, _corpus, _report), do: {:error, :invalid_release_evidence}

  defp validate_identity(persona, manifest, corpus, report) do
    expected = %{
      "schema" => "sarah.persona.eval_report.v1",
      "persona_id" => persona.id,
      "persona_version" => persona.version,
      "persona_digest" => persona.digest,
      "source_manifest_id" => manifest["id"],
      "source_manifest_digest" => manifest["manifest_sha256"],
      "corpus_id" => corpus["id"],
      "corpus_revision" => corpus["revision"],
      "corpus_digest" => corpus["digest"]
    }

    case Enum.find(expected, fn {key, value} -> report[key] != value end) do
      nil -> :ok
      {key, _value} -> {:error, {:release_identity_mismatch, key}}
    end
  end

  defp validate_report_digest(%{"report_digest" => digest} = report) when is_binary(digest) do
    if Canonical.digest!(Map.delete(report, "report_digest")) == digest,
      do: :ok,
      else: {:error, :invalid_report_digest}
  end

  defp validate_report_digest(_report), do: {:error, :missing_report_digest}

  defp validate_results(corpus, report) do
    expected_ids = corpus["cases"] |> Enum.map(& &1["id"]) |> MapSet.new()
    results = report["results"]

    cond do
      not is_binary(report["model_id"]) or report["model_id"] == "" ->
        {:error, :missing_model_id}

      not is_list(results) or length(results) > 100 ->
        {:error, :invalid_results}

      not Enum.all?(results, &valid_result?/1) ->
        {:error, :invalid_results}

      MapSet.new(results, & &1["case_id"]) != expected_ids ->
        {:error, :incomplete_results}

      not Enum.all?(results, &(&1["passed"] == true)) ->
        {:error, :regression_failed}

      not valid_aggregate?(corpus, report, results) ->
        {:error, :threshold_not_met}

      true ->
        :ok
    end
  end

  defp valid_result?(result) when is_map(result) do
    is_binary(result["case_id"]) and
      is_boolean(result["passed"]) and
      is_number(result["score"]) and result["score"] >= 0.0 and result["score"] <= 1.0 and
      is_binary(result["provider_response_id"]) and result["provider_response_id"] != "" and
      is_binary(result["response_digest"]) and
      Regex.match?(~r/\A[0-9a-f]{64}\z/, result["response_digest"])
  end

  defp valid_result?(_result), do: false

  defp valid_aggregate?(corpus, report, results) do
    calculated_score = Enum.sum(Enum.map(results, & &1["score"])) / length(results)

    report["passed"] == true and
      report["minimum_score"] == corpus["minimum_score"] and
      is_number(report["score"]) and
      abs(report["score"] - calculated_score) < 1.0e-12 and
      report["score"] >= corpus["minimum_score"]
  end
end
