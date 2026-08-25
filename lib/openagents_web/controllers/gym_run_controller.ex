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
  with the totals, or `abandoned` without them. The two `409` refusals
  carry the colliding run beside the envelope so a harness can read what
  it lost to.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.Accounts
  alias OpenAgents.Gym
  alias OpenAgents.Gym.Run
  alias OpenAgents.Gym.Trial
  alias OpenAgentsWeb.ApiError

  def create(conn, params) do
    with :ok <- operator(conn) do
      case Gym.record_run(params) do
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
      case Gym.start_run(params) do
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
    end
  end

  defp close(conn, _run, _params) do
    ApiError.validation_failed(conn, %{"status" => ["must be graded or abandoned"]})
  end

  def index(conn, params) do
    with :ok <- operator(conn) do
      runs = Gym.list_runs(suite: params["suite"])
      json(conn, %{"runs" => Enum.map(runs, &run_view/1)})
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
end
