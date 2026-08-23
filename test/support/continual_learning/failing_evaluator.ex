defmodule OpenAgents.ContinualLearningStubs.FailingEvaluator do
  @moduledoc false

  @behaviour OpenAgents.ContinualLearning.Evaluator

  @impl true
  def evaluate(_context), do: {:error, :evaluator_unavailable}
end
