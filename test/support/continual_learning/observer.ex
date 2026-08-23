defmodule OpenAgents.ContinualLearningStubs.Observer do
  @moduledoc false

  @key :continual_learning_test_observer

  def watch(pid), do: Application.put_env(:openagents, @key, pid)

  def pid, do: Application.get_env(:openagents, @key)

  def forget, do: Application.delete_env(:openagents, @key)
end
