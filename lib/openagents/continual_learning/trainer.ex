defmodule OpenAgents.ContinualLearning.Trainer do
  @moduledoc """
  The trainer contract: one bounded training round over admitted licensed data.

  A trainer never resolves data itself. It receives the exact dataset bindings
  the admission already authorized, the surviving checkpoint state, and the
  round number, and returns the next state with the metrics, usage, and runtime
  the round spent. Everything durable — the checkpoint, the receipts, the
  stopping decision — belongs to `OpenAgents.ContinualLearning.Runner`.
  """

  @type context :: %{
          job: OpenAgents.ContinualLearning.Job.t(),
          round: pos_integer(),
          datasets: [map()],
          configuration: map(),
          parent_state: map(),
          parent_digest: String.t() | nil
        }

  @type round_result :: %{
          state: map(),
          metrics: map(),
          usage: map(),
          duration_ms: non_neg_integer()
        }

  @callback train_round(context()) :: {:ok, round_result()} | {:error, atom()}
end
