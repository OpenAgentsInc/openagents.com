defmodule OpenAgents.ContinualLearningStubs.ForeignEvaluator do
  @moduledoc false

  @behaviour OpenAgents.ContinualLearning.Evaluator

  @impl true
  def evaluate(%{job: job, policy: policy}) do
    {:ok,
     %{
       verifier: %{
         "id" => "verifier:never-admitted",
         "admitted" => true,
         "independent_of_producer" => true
       },
       falsifier: "a checkpoint below the admitted target fails",
       terminal_result: :passed,
       criteria: [
         %{
           "criterion" => List.first(policy["acceptance_criteria"]),
           "receipt" => "continual-learning-evaluation:#{job.id}:stub",
           "visibility" => "restricted"
         }
       ],
       metrics: %{"score" => 1.0},
       usage: %{"total_tokens" => 10},
       duration_ms: 10
     }}
  end
end
