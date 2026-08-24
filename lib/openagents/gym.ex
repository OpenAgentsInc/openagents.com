defmodule OpenAgents.Gym do
  @moduledoc """
  The Gym: graded benchmark runs of our agents, recorded so capability work
  has a scoreboard.

  The framing (`docs/2026-08-24-harbor-terminal-bench-plan.md`): Harbor and
  Terminal-Bench are not only measurement, they are the training ground —
  new coder capabilities, model-swapping policies, and plugins prove
  themselves against graded task suites, and this context holds the results
  those proofs produce. The harness runs elsewhere (the monorepo's bench
  lane); this is the record and the surface.

  Operator-only on every path for now: the Gym is a workbench for the
  people building the agent, not a public leaderboard. Widening it later is
  a deliberate act, not a default.
  """

  import Ecto.Query

  alias OpenAgents.Gym.Run
  alias OpenAgents.Repo

  @maximum_listed 200

  @doc """
  Record one run, idempotently by recipe digest.

  A resubmitted digest returns the existing row as `{:ok, run, replayed?:
  true}` rather than duplicating or refusing: the harness retries uploads,
  and a retry is not a second run.
  """
  @spec record_run(map()) :: {:ok, Run.t(), boolean()} | {:error, Ecto.Changeset.t()}
  def record_run(attributes) when is_map(attributes) do
    changeset = Run.changeset(%Run{}, attributes)

    case Repo.insert(changeset) do
      {:ok, run} ->
        {:ok, run, false}

      {:error, %Ecto.Changeset{errors: errors} = failed} ->
        case Keyword.get(errors, :recipe_digest) do
          {_message, options} ->
            if options[:constraint] == :unique,
              do: replay(Ecto.Changeset.get_field(changeset, :recipe_digest), failed),
              else: {:error, failed}

          nil ->
            {:error, failed}
        end
    end
  end

  @doc "Runs, newest first, optionally filtered by suite. Bounded."
  @spec list_runs(keyword()) :: [Run.t()]
  def list_runs(options \\ []) do
    limit = options |> Keyword.get(:limit, 50) |> min(@maximum_listed) |> max(1)

    Run
    |> filter_suite(options[:suite])
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Distinct suites present, for the surface's filter row."
  @spec suites() :: [String.t()]
  def suites do
    Run
    |> distinct(true)
    |> select([r], r.suite)
    |> order_by(asc: :suite)
    |> Repo.all()
  end

  defp filter_suite(query, suite) when is_binary(suite) and suite != "",
    do: where(query, [r], r.suite == ^suite)

  defp filter_suite(query, _absent), do: query

  defp replay(digest, failed) when is_binary(digest) do
    case Repo.get_by(Run, recipe_digest: digest) do
      %Run{} = run -> {:ok, run, true}
      nil -> {:error, failed}
    end
  end

  defp replay(_digest, failed), do: {:error, failed}
end
