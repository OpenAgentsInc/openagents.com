defmodule OpenAgents.GymTest do
  use OpenAgents.DataCase, async: true

  alias OpenAgents.Gym
  alias OpenAgents.Gym.Run

  defp attributes(overrides \\ %{}) do
    Map.merge(
      %{
        "suite" => "terminal-bench@2.0",
        "agent" => "openagents-coder",
        "agent_version" => "0.3.5",
        "model" => "ox-alpha",
        "lane" => "proxy",
        "tasks_total" => 20,
        "tasks_passed" => 13,
        "input_tokens" => 1_200_000,
        "output_tokens" => 240_000,
        "cost_microusd" => 1_850_000,
        "duration_seconds" => 3_600,
        "recipe_digest" => "sha256:" <> String.duplicate("a", 64)
      },
      overrides
    )
  end

  test "records a run and derives its score" do
    assert {:ok, %Run{} = run, false} = Gym.record_run(attributes())
    assert run.tasks_passed == 13
    assert Run.score(run) == 13 / 20
  end

  test "an empty suite has no score rather than a perfect one" do
    {:ok, run, false} =
      Gym.record_run(attributes(%{"tasks_total" => 0, "tasks_passed" => 0}))

    assert Run.score(run) == nil
  end

  test "a resubmitted recipe digest replays the first row" do
    {:ok, first, false} = Gym.record_run(attributes())

    {:ok, second, true} =
      Gym.record_run(attributes(%{"tasks_passed" => 1}))

    assert second.id == first.id
    assert second.tasks_passed == 13
    assert length(Gym.list_runs()) == 1
  end

  test "passed cannot exceed total" do
    assert {:error, changeset} =
             Gym.record_run(attributes(%{"tasks_passed" => 21}))

    assert %{tasks_passed: [_message]} = errors_on(changeset)
  end

  test "listing filters by suite and bounds the page" do
    {:ok, _one, false} = Gym.record_run(attributes())

    {:ok, _two, false} =
      Gym.record_run(
        attributes(%{
          "suite" => "swebench@lite",
          "recipe_digest" => "sha256:" <> String.duplicate("b", 64)
        })
      )

    assert [%Run{suite: "swebench@lite"}] = Gym.list_runs(suite: "swebench@lite")
    assert length(Gym.list_runs()) == 2
    assert Gym.suites() == ["swebench@lite", "terminal-bench@2.0"]
    assert [_only] = Gym.list_runs(limit: 1)
  end

  test "an oversized report is refused" do
    huge = %{"rows" => String.duplicate("x", 300_000)}

    assert {:error, changeset} = Gym.record_run(attributes(%{"report" => huge}))
    assert %{report: [_message]} = errors_on(changeset)
  end
end
