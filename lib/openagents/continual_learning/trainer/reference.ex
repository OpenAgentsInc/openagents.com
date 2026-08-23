defmodule OpenAgents.ContinualLearning.Trainer.Reference do
  @moduledoc """
  The reference trainer for the first bounded workflow.

  The round is deterministic in its inputs: the state is the canonical digest
  chain over the admitted objective, the base model, the licensed dataset
  digests, the configuration, and the parent state, and the metrics improve
  along a fixed schedule. Two jobs admitted under identical inputs therefore
  produce identical checkpoints and an identical artifact digest, which is what
  makes the reproducibility canary a test rather than a claim.

  A production trainer replaces this module through the `:trainer` setting; the
  durable contract around it does not change.
  """

  @behaviour OpenAgents.ContinualLearning.Trainer

  @impl true
  def train_round(%{job: job, round: round} = context) do
    state = %{
      "round" => round,
      "objective_version" => job.objective_version,
      "base_model_digest" => job.base_model_digest,
      "training_code_digest" => job.training_code_digest,
      "configuration_digest" => job.configuration_digest,
      "dataset_digests" => Enum.map(context.datasets, & &1["artifact_digest"]),
      "parent_digest" => context.parent_digest
    }

    {:ok,
     %{
       state: state,
       metrics: metrics(round),
       usage: %{
         "input_tokens" => 1_000 * round,
         "output_tokens" => 250 * round,
         "total_tokens" => 1_250 * round,
         "records_seen" => 100 * round
       },
       duration_ms: 1_000
     }}
  end

  defp metrics(round) do
    loss = Float.round(1.0 / (round + 1), 6)

    %{
      "round" => round,
      "loss" => loss,
      "score" => Float.round(1.0 - loss, 6)
    }
  end
end
