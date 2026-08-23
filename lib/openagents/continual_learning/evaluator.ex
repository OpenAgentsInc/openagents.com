defmodule OpenAgents.ContinualLearning.Evaluator do
  @moduledoc """
  The evaluator contract: grade one trained checkpoint against the admitted
  evaluation corpus.

  The evaluator receives the exact evaluation inputs the admission authorized
  and returns a terminal result with per-criterion evidence. It reports its own
  identity and whether it is independent of the trainer, and
  `OpenAgents.ContinualLearning.Runner` refuses a result whose reported identity
  does not match the admitted evaluator policy, so separation is checked against
  the policy rather than asserted by the evaluator.
  """

  @type context :: %{
          job: OpenAgents.ContinualLearning.Job.t(),
          corpus: [map()],
          checkpoint: OpenAgents.ContinualLearning.Checkpoint.t(),
          policy: map()
        }

  @type result :: %{
          verifier: map(),
          falsifier: String.t(),
          terminal_result: :passed | :failed,
          criteria: [map()],
          metrics: map(),
          usage: map(),
          duration_ms: non_neg_integer()
        }

  @callback evaluate(context()) :: {:ok, result()} | {:error, atom()}
end
