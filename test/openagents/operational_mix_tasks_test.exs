defmodule OpenAgents.OperationalMixTasksTest do
  use ExUnit.Case, async: true

  @tasks ~w(
    openagents.atif.export
    openagents.eval.persona
    openagents.eval.recall
    openagents.icons.vendor
    openagents.persona.verify_promotion
    openagents.voice.load_probe
    openagents.voice.release_control
    openagents.voice.report
    openagents.voice.retention
  )

  test "every Sarah production operation has an OpenAgents task" do
    Enum.each(@tasks, fn task_name ->
      assert module = Mix.Task.get(task_name), "missing Mix task #{task_name}"
      assert function_exported?(module, :run, 1)
    end)
  end
end
