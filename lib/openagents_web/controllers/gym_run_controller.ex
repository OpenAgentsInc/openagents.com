defmodule OpenAgentsWeb.GymRunController do
  @moduledoc """
  The door the bench harness posts graded runs through.

  Authority is the fleet-promotion shape without the privileged scope: an
  ordinary `forge:write` bearer plus live operator standing, rechecked on
  every request through `OpenAgents.Accounts.admin?/1`. Recording a
  benchmark row is operator work, but it moves no money and deploys
  nothing, so it does not need a scope of its own the way promotion does —
  the recheck, not the scope, is what keeps it operator-only.

  Idempotent by recipe digest: a retried upload answers `200` with the
  existing row where the first answered `201`, so harness retry policy
  needs no special casing.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.Accounts
  alias OpenAgents.Gym
  alias OpenAgents.Gym.Run
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
      "tasks_total" => run.tasks_total,
      "tasks_passed" => run.tasks_passed,
      "score" => Run.score(run),
      "input_tokens" => run.input_tokens,
      "output_tokens" => run.output_tokens,
      "cost_microusd" => run.cost_microusd,
      "duration_seconds" => run.duration_seconds,
      "recipe_digest" => run.recipe_digest,
      "recorded_at" => run.inserted_at
    }
  end
end
