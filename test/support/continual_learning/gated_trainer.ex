defmodule OpenAgents.ContinualLearningStubs.GatedTrainer do
  @moduledoc false

  @behaviour OpenAgents.ContinualLearning.Trainer

  alias OpenAgents.ContinualLearning.Trainer.Reference
  alias OpenAgents.ContinualLearningStubs.Observer

  @impl true
  def train_round(context) do
    send(Observer.pid(), {:round_started, context.round, self()})

    receive do
      :proceed -> Reference.train_round(context)
    after
      10_000 -> {:error, :gate_timeout}
    end
  end
end
