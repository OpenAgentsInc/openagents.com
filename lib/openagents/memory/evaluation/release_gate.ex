defmodule OpenAgents.Memory.Evaluation.ReleaseGate do
  @moduledoc "Rejects incomplete, stale, altered, or below-threshold recall evidence."

  alias OpenAgents.Memory.Evaluation.{Corpus, Report}
  alias OpenAgents.Provenance.Canonical

  @spec validate(map(), map()) :: :ok | {:error, term()}
  def validate(corpus, report) when is_map(corpus) and is_map(report) do
    expected = Report.build(corpus, report["results"] || [])

    with :ok <- Corpus.validate(Map.delete(corpus, "digest")),
         true <- report["report_digest"] == Canonical.digest!(Map.delete(report, "report_digest")),
         true <- report == expected,
         true <- report["passed"] do
      :ok
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :recall_release_evidence_rejected}
    end
  end

  def validate(_corpus, _report), do: {:error, :invalid_release_evidence}
end
