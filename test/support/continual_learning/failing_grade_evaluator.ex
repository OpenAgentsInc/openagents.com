defmodule OpenAgents.ContinualLearningStubs.FailingGradeEvaluator do
  @moduledoc false

  @behaviour OpenAgents.ContinualLearning.Evaluator

  @impl true
  def evaluate(%{job: job, policy: policy}) do
    {:ok,
     %{
       verifier: policy["verifier"],
       falsifier: "a checkpoint above the admitted target passes",
       terminal_result: :failed,
       criteria: [
         %{
           "criterion" => List.first(policy["acceptance_criteria"]),
           "receipt" => "continual-learning-evaluation:#{job.id}:stub",
           "visibility" => "restricted"
         }
       ],
       metrics: %{"score" => 0.0},
       usage: %{"total_tokens" => 10},
       duration_ms: 10
     }}
  end
end
