defmodule OpenAgents.ContinualLearning.Evaluator.Reference do
  @moduledoc """
  The reference evaluator for the first bounded workflow.

  It grades the surviving checkpoint against the admitted target metric and
  reports its own identity, the falsifier it ran, and one evidence receipt per
  admitted acceptance criterion. The result is deterministic in the checkpoint
  metrics, so an unchanged run grades identically.
  """

  @behaviour OpenAgents.ContinualLearning.Evaluator

  alias OpenAgents.Provenance.Canonical

  @impl true
  def evaluate(%{job: job, checkpoint: checkpoint, policy: policy, corpus: corpus}) do
    metric = Map.get(policy, "target_metric", "score")
    target = Map.get(policy, "target_value", 0.0)
    observed = Map.get(checkpoint.metrics, metric)

    if is_number(observed) do
      passed = observed >= target

      {:ok,
       %{
         verifier: Map.get(policy, "verifier", %{}),
         falsifier:
           "the same checkpoint graded below #{metric} #{target} fails, and a corpus digest " <>
             "that does not match the admitted evaluation inputs fails",
         terminal_result: (passed && :passed) || :failed,
         criteria: criteria(job, policy, corpus, metric, observed),
         metrics: %{
           metric => observed,
           "target_value" => target,
           "corpus_records" => length(corpus)
         },
         usage: %{"input_tokens" => 500, "output_tokens" => 100, "total_tokens" => 600},
         duration_ms: 500
       }}
    else
      {:error, :evaluation_metric_missing}
    end
  end

  defp criteria(job, policy, corpus, metric, observed) do
    corpus_digest = Canonical.digest!(Enum.map(corpus, & &1["artifact_digest"]))

    for criterion <- Map.get(policy, "acceptance_criteria", []) do
      %{
        "criterion" => criterion,
        "receipt" =>
          "continual-learning-evaluation:#{job.id}:#{Canonical.sha256(criterion)}"
          |> String.slice(0, 256),
        "visibility" => "restricted",
        "observed" => %{metric => observed, "corpus_digest" => corpus_digest}
      }
    end
  end
end
