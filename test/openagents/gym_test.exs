defmodule OpenAgents.GymTest do
  use OpenAgents.DataCase, async: true

  import Ecto.Query
  import OpenAgentsWeb.ConnCase, only: [github_user: 1]

  alias OpenAgents.Gym
  alias OpenAgents.Gym.Run
  alias OpenAgents.Gym.Trial
  alias OpenAgents.Repo
  alias OpenAgents.Threads

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

  defp start_attributes(overrides \\ %{}) do
    Map.merge(
      %{
        "suite" => "terminal-bench@2.0",
        "agent" => "openagents-coder",
        "model" => "ox-alpha",
        "lane" => "proxy",
        "tasks_total" => 5
      },
      overrides
    )
  end

  describe "start_run/1" do
    test "registers a running run with a placeholder digest and broadcasts it" do
      :ok = Gym.subscribe()

      assert {:ok, %Run{} = run, false} = Gym.start_run(start_attributes())

      assert run.status == "running"
      assert run.tasks_passed == nil
      assert run.completed_at == nil
      assert String.starts_with?(run.recipe_digest, "pending:")
      assert Run.score(run) == nil

      run_id = run.id
      assert_receive {:gym_run, %Run{id: ^run_id, status: "running"}}
    end

    test "a resubmitted digest replays the running row" do
      digest = "sha256:" <> String.duplicate("f", 64)

      {:ok, first, false} = Gym.start_run(start_attributes(%{"recipe_digest" => digest}))
      {:ok, second, true} = Gym.start_run(start_attributes(%{"recipe_digest" => digest}))

      assert second.id == first.id
      assert length(Gym.list_runs()) == 1
    end

    test "identity is required" do
      assert {:error, changeset} = Gym.start_run(%{"suite" => "terminal-bench@2.0"})
      assert %{agent: [_agent], model: [_model]} = errors_on(changeset)
    end
  end

  describe "finalize_run/2 and abandon_run/1" do
    test "folds the grades in, pins the digest, and broadcasts" do
      {:ok, run, false} = Gym.start_run(start_attributes())
      :ok = Gym.subscribe_run(run.id)

      digest = "sha256:" <> String.duplicate("1", 64)

      assert {:ok, graded} =
               Gym.finalize_run(run, %{
                 "tasks_total" => 5,
                 "tasks_passed" => 4,
                 "duration_seconds" => 90,
                 "recipe_digest" => digest
               })

      assert graded.status == "graded"
      assert graded.recipe_digest == digest
      assert graded.completed_at != nil
      assert Run.score(graded) == 4 / 5

      run_id = run.id
      assert_receive {:gym_run, %Run{id: ^run_id, status: "graded"}}
    end

    test "a graded run refuses a second finalize and an abandonment" do
      {:ok, run, false} = Gym.record_run(attributes())

      assert {:error, :already_graded, ^run} =
               Gym.finalize_run(run, %{"tasks_total" => 1, "tasks_passed" => 1})

      assert {:error, :already_graded, ^run} = Gym.abandon_run(run)
    end

    test "a digest that names another run is a conflict carrying that run" do
      {:ok, existing, false} = Gym.record_run(attributes())
      {:ok, run, false} = Gym.start_run(start_attributes())

      assert {:error, :digest_conflict, conflicting} =
               Gym.finalize_run(run, %{
                 "tasks_total" => 5,
                 "tasks_passed" => 5,
                 "recipe_digest" => existing.recipe_digest
               })

      assert conflicting.id == existing.id
    end

    test "abandoning a running run is terminal, broadcast, and idempotent" do
      {:ok, run, false} = Gym.start_run(start_attributes())
      :ok = Gym.subscribe()

      assert {:ok, abandoned} = Gym.abandon_run(run)
      assert abandoned.status == "abandoned"
      assert abandoned.completed_at != nil

      run_id = run.id
      assert_receive {:gym_run, %Run{id: ^run_id, status: "abandoned"}}

      assert {:ok, %Run{status: "abandoned"}} = Gym.abandon_run(abandoned)
    end
  end

  describe "record_trial/3" do
    defp running_run do
      {:ok, run, false} = Gym.start_run(start_attributes())
      run
    end

    test "upserts by task and broadcasts each report" do
      bearer = github_user("gym-trial-bearer")
      run = running_run()
      :ok = Gym.subscribe_run(run.id)

      assert {:ok, trial} =
               Gym.record_trial(bearer, run, %{"task" => "hello-world", "state" => "running"})

      assert trial.state == "running"

      assert {:ok, updated} =
               Gym.record_trial(bearer, run, %{"task" => "hello-world", "state" => "passed"})

      assert updated.id == trial.id
      assert updated.state == "passed"
      assert Gym.list_trials(run) |> length() == 1

      trial_id = trial.id
      assert_receive {:gym_trial, %Trial{id: ^trial_id, state: "running"}}
      assert_receive {:gym_trial, %Trial{id: ^trial_id, state: "passed"}}
    end

    test "a report that omits the thread keeps an existing link" do
      bearer = github_user("gym-trial-keeper")
      {:ok, thread} = Threads.open(bearer, "Run the hello-world trial")
      run = running_run()

      {:ok, linked} =
        Gym.record_trial(bearer, run, %{
          "task" => "hello-world",
          "state" => "running",
          "thread_id" => thread.id
        })

      assert linked.thread_id == thread.id

      {:ok, graded} =
        Gym.record_trial(bearer, run, %{"task" => "hello-world", "state" => "passed"})

      assert graded.thread_id == thread.id
    end

    test "an unknown thread and an unowned one refuse identically" do
      bearer = github_user("gym-trial-mine")
      stranger = github_user("gym-trial-theirs")
      {:ok, foreign} = Threads.open(stranger, "Somebody else's trial")
      run = running_run()

      assert {:error, unknown} =
               Gym.record_trial(bearer, run, %{
                 "task" => "a",
                 "state" => "running",
                 "thread_id" => Ecto.UUID.generate()
               })

      assert {:error, unowned} =
               Gym.record_trial(bearer, run, %{
                 "task" => "a",
                 "state" => "running",
                 "thread_id" => foreign.id
               })

      assert errors_on(unknown)[:thread_id] == errors_on(unowned)[:thread_id]
      assert Gym.list_trials(run) == []
    end

    test "trials per run are bounded" do
      bearer = github_user("gym-trial-bound")
      run = running_run()
      now = DateTime.utc_now()

      rows =
        for index <- 1..Gym.maximum_trials_per_run() do
          %{
            id: Ecto.UUID.generate(),
            run_id: run.id,
            task: "task-#{index}",
            state: "ungraded",
            inserted_at: now,
            updated_at: now
          }
        end

      Repo.insert_all(Trial, rows)

      assert {:error, :trial_limit} =
               Gym.record_trial(bearer, run, %{"task" => "one-too-many", "state" => "running"})

      # A task the run already holds still updates under the bound.
      assert {:ok, %Trial{state: "passed"}} =
               Gym.record_trial(bearer, run, %{"task" => "task-1", "state" => "passed"})
    end
  end

  describe "staleness" do
    test "a running run with no update for six hours is swept on read" do
      {:ok, run, false} = Gym.start_run(start_attributes())
      :ok = Gym.subscribe()

      stale = DateTime.add(DateTime.utc_now(), -7 * 60 * 60, :second)

      from(r in Run, where: r.id == ^run.id)
      |> Repo.update_all(set: [updated_at: stale])

      assert [%Run{status: "abandoned", completed_at: completed_at}] = Gym.list_runs()
      assert completed_at != nil

      run_id = run.id
      assert_receive {:gym_run, %Run{id: ^run_id, status: "abandoned"}}
    end

    test "a freshly reporting run is not swept" do
      {:ok, run, false} = Gym.start_run(start_attributes())

      assert {:ok, %Run{status: "running"}} = Gym.fetch_run(run.id)
    end
  end

  describe "fetch_run/1" do
    test "loads a run with its trials in task order" do
      bearer = github_user("gym-fetch-bearer")
      run = running_run()

      {:ok, _b} = Gym.record_trial(bearer, run, %{"task" => "b-task", "state" => "passed"})
      {:ok, _a} = Gym.record_trial(bearer, run, %{"task" => "a-task", "state" => "failed"})

      assert {:ok, %Run{trials: [%Trial{task: "a-task"}, %Trial{task: "b-task"}]}} =
               Gym.fetch_run(run.id)

      assert Gym.fetch_run(Ecto.UUID.generate()) == :error
      assert Gym.fetch_run("not-a-uuid") == :error
    end
  end

  describe "fetch_trial_thread/1" do
    test "reads a thread only through a stored, verified linkage" do
      bearer = github_user("gym-thread-reader")
      {:ok, thread} = Threads.open(bearer, "Run the linked trial")
      run = running_run()

      {:ok, linked} =
        Gym.record_trial(bearer, run, %{
          "task" => "linked",
          "state" => "running",
          "thread_id" => thread.id
        })

      assert {:ok, fetched} = Gym.fetch_trial_thread(linked.id)
      assert fetched.id == thread.id
    end

    test "a trial without a linkage is refused" do
      bearer = github_user("gym-thread-unlinked")
      run = running_run()

      {:ok, unlinked} =
        Gym.record_trial(bearer, run, %{"task" => "local-lane", "state" => "running"})

      assert Gym.fetch_trial_thread(unlinked.id) == :error
    end

    test "an unknown trial id is refused, however it is spelled" do
      assert Gym.fetch_trial_thread(Ecto.UUID.generate()) == :error
      assert Gym.fetch_trial_thread("not-a-uuid") == :error
    end

    test "a linkage whose thread was deleted with its account is refused" do
      bearer = github_user("gym-thread-deleted")
      {:ok, thread} = Threads.open(bearer, "Run then delete")
      run = running_run()

      {:ok, linked} =
        Gym.record_trial(bearer, run, %{
          "task" => "deleted",
          "state" => "running",
          "thread_id" => thread.id
        })

      {:ok, _deleted} = Repo.delete(thread)

      assert Gym.fetch_trial_thread(linked.id) == :error
    end
  end
end
