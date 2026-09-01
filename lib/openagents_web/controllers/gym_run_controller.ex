defmodule OpenAgentsWeb.GymRunController do
  @moduledoc """
  The door the bench harness reports runs through — one-shot and live.

  Authority is the fleet-promotion shape without the privileged scope: an
  ordinary `forge:write` bearer plus live operator standing, rechecked on
  every request through `OpenAgents.Accounts.admin?/1`. Recording a
  benchmark row is operator work, but it moves no money and deploys
  nothing, so it does not need a scope of its own the way promotion does —
  the recheck, not the scope, is what keeps it operator-only.

  Idempotent by recipe digest: a retried upload answers `200` with the
  existing row where the first answered `201`, so harness retry policy
  needs no special casing. The lifecycle routes add the live half: `start`
  registers a run as `running`, `create_trial` upserts one task's state
  (optionally linked to the thread carrying its transcript, verified
  against the bearer's account), and `update` closes the run — `graded`
  with the totals, `abandoned` without them, or `cancelled` when an
  operator says stop. The `409` refusals carry the colliding run beside
  the envelope so a harness can read what it lost to.

  The read half serves the CLI's frozen rendering contract: `show` and
  `index` answer in `openagents.gym.run_status.v1` — the exact document
  `openagents gym run status|list` deserializes — with grades computed
  from the run's trial rows. The write paths keep their original `run`
  envelope, which registration and finalization already parse.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.Accounts
  alias OpenAgents.Gym
  alias OpenAgents.Gym.Run
  alias OpenAgents.Gym.Trial
  alias OpenAgentsWeb.ApiError

  def create(conn, params) do
    with :ok <- operator(conn) do
      case Gym.record_run(params, conn.assigns.current_user) do
        {:ok, run, replayed?} ->
          conn
          |> put_status(if(replayed?, do: :ok, else: :created))
          |> json(%{"run" => run_view(run), "replayed" => replayed?})

        {:error, changeset} ->
          ApiError.changeset(conn, changeset)
      end
    end
  end

  def start(conn, params) do
    with :ok <- operator(conn) do
      case Gym.start_run(params, conn.assigns.current_user) do
        {:ok, run, replayed?} ->
          conn
          |> put_status(if(replayed?, do: :ok, else: :created))
          |> json(%{"run" => run_view(run), "replayed" => replayed?})

        {:error, changeset} ->
          ApiError.changeset(conn, changeset)
      end
    end
  end

  def create_trial(conn, %{"id" => run_id} = params) do
    with :ok <- operator(conn) do
      case Gym.get_run(run_id) do
        %Run{} = run ->
          case Gym.record_trial(conn.assigns.current_user, run, Map.delete(params, "id")) do
            {:ok, trial} ->
              json(conn, %{"trial" => trial_view(trial)})

            {:error, :trial_limit} ->
              ApiError.validation_failed(conn, %{
                "task" => ["this run already holds the maximum number of trials"]
              })

            {:error, changeset} ->
              ApiError.changeset(conn, changeset)
          end

        nil ->
          ApiError.not_found(conn)
      end
    end
  end

  def update(conn, %{"id" => run_id} = params) do
    with :ok <- operator(conn) do
      case Gym.get_run(run_id) do
        %Run{} = run -> close(conn, run, params)
        nil -> ApiError.not_found(conn)
      end
    end
  end

  defp close(conn, run, %{"status" => "graded"} = params) do
    case Gym.finalize_run(run, Map.drop(params, ["id", "status"])) do
      {:ok, updated} ->
        json(conn, %{"run" => run_view(updated)})

      {:error, :already_graded, graded} ->
        ApiError.refuse(conn, "run_already_graded", legacy: %{"run" => run_view(graded)})

      {:error, :cancelled, cancelled} ->
        ApiError.refuse(conn, "run_cancelled", legacy: %{"run" => run_view(cancelled)})

      {:error, :digest_conflict, existing} ->
        ApiError.refuse(conn, "recipe_digest_conflict", legacy: %{"run" => run_view(existing)})

      {:error, changeset} ->
        ApiError.changeset(conn, changeset)
    end
  end

  defp close(conn, run, %{"status" => "abandoned"}) do
    case Gym.abandon_run(run) do
      {:ok, updated} ->
        json(conn, %{"run" => run_view(updated)})

      {:error, :already_graded, graded} ->
        ApiError.refuse(conn, "run_already_graded", legacy: %{"run" => run_view(graded)})

      {:error, :cancelled, cancelled} ->
        ApiError.refuse(conn, "run_cancelled", legacy: %{"run" => run_view(cancelled)})
    end
  end

  defp close(conn, run, %{"status" => "cancelled"}) do
    case Gym.cancel_run(run) do
      {:ok, updated} ->
        json(conn, %{"run" => run_view(updated)})

      {:error, :already_graded, graded} ->
        ApiError.refuse(conn, "run_already_graded", legacy: %{"run" => run_view(graded)})

      {:error, :already_abandoned, abandoned} ->
        ApiError.refuse(conn, "run_already_abandoned", legacy: %{"run" => run_view(abandoned)})
    end
  end

  defp close(conn, _run, _params) do
    ApiError.validation_failed(conn, %{"status" => ["must be graded, abandoned, or cancelled"]})
  end

  def show(conn, %{"id" => run_id}) do
    with :ok <- operator(conn) do
      case Gym.fetch_run(run_id) do
        {:ok, run} -> json(conn, %{"run" => status_view(run)})
        :error -> ApiError.not_found(conn)
      end
    end
  end

  def index(conn, params) do
    with :ok <- operator(conn) do
      runs =
        Gym.list_runs(
          suite: params["suite"],
          recorded_by: if(params["mine"] in ["true", "1", true], do: conn.assigns.current_user),
          trials: true
        )

      json(conn, %{"runs" => Enum.map(runs, &status_view/1)})
    end
  end

  defp operator(conn) do
    if Accounts.admin?(conn.assigns.current_user) do
      :ok
    else
      ApiError.refuse(conn, "not_operator")
    end
  end

  defp run_view(%Run{} = run) do
    %{
      "id" => run.id,
      "suite" => run.suite,
      "agent" => run.agent,
      "agent_version" => run.agent_version,
      "model" => run.model,
      "lane" => run.lane,
      "status" => run.status,
      "tasks_total" => run.tasks_total,
      "tasks_passed" => run.tasks_passed,
      "score" => Run.score(run),
      "input_tokens" => run.input_tokens,
      "output_tokens" => run.output_tokens,
      "cost_microusd" => run.cost_microusd,
      "duration_seconds" => run.duration_seconds,
      "recipe_digest" => run.recipe_digest,
      "recorded_at" => run.inserted_at,
      "completed_at" => run.completed_at
    }
  end

  defp trial_view(%Trial{} = trial) do
    %{
      "id" => trial.id,
      "run_id" => trial.run_id,
      "task" => trial.task,
      "state" => trial.state,
      "thread_id" => trial.thread_id,
      "recorded_at" => trial.inserted_at,
      "updated_at" => trial.updated_at
    }
  end

  # The CLI's frozen rendering contract, `openagents.gym.run_status.v1`
  # (`crates/openagents-cli/src/gym/schemas.rs` in the monorepo). Every key
  # below is deserialized by `openagents gym run status|list`, so this shape
  # only ever gains keys.
  @run_status_schema "openagents.gym.run_status.v1"

  defp status_view(%Run{} = run) do
    trials = run.trials
    {accepted, rejected, ungraded, graded, tasks_total} = grades(run, trials)

    %{
      "schema" => @run_status_schema,
      "run_id" => run.id,
      "suite_id" => run.suite,
      "lane" => run.lane || "unknown",
      "model" => run.model,
      "state" => run.status,
      "started_at" => run.inserted_at,
      "updated_at" => run.updated_at,
      "tasks_total" => tasks_total,
      "accepted" => accepted,
      "rejected" => rejected,
      "ungraded" => ungraded,
      "graded" => graded,
      "summary" =>
        "#{accepted} accepted, #{rejected} rejected, #{ungraded} ungraded; " <>
          "#{graded} of #{tasks_total} tasks graded",
      "trials" => Enum.map(trials, &trial_status_view/1)
    }
  end

  # Grades mirror the CLI's local rules: a trial the verifier never graded is
  # `ungraded`, a graded trial is `accepted` (reward) or `rejected` (none),
  # and `graded` counts verdicts, so a still-running trial lands in no bucket.
  # A run with no trial rows — the one-shot ingest — answers from its
  # headline columns instead, where `tasks_passed` already is the accepted
  # count over a fully graded suite.
  defp grades(%Run{status: "graded", tasks_total: total, tasks_passed: passed}, [])
       when is_integer(total) and is_integer(passed) do
    {passed, total - passed, 0, total, total}
  end

  defp grades(%Run{} = run, trials) do
    accepted = Enum.count(trials, &(&1.state == "passed"))
    rejected = Enum.count(trials, &(&1.state == "failed"))
    ungraded = Enum.count(trials, &(&1.state == "ungraded"))
    {accepted, rejected, ungraded, accepted + rejected, run.tasks_total || length(trials)}
  end

  defp trial_status_view(%Trial{} = trial) do
    {state, outcome} =
      case trial.state do
        "passed" -> {"accepted", "accepted"}
        "failed" -> {"rejected", "rejected"}
        other -> {other, nil}
      end

    %{
      "task" => trial.task,
      "state" => state,
      "outcome" => outcome,
      "started_at" => trial.inserted_at,
      "finished_at" => if(trial.state == "running", do: nil, else: trial.updated_at),
      "transcript_ref" => trial.thread_id && "thread:" <> trial.thread_id,
      "cost_usd" => nil
    }
  end
end
