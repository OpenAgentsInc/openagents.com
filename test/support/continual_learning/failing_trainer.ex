defmodule OpenAgents.ContinualLearningStubs.FailingTrainer do
  @moduledoc false

  @behaviour OpenAgents.ContinualLearning.Trainer

  @impl true
  def train_round(_context), do: {:error, :trainer_unavailable}
end
