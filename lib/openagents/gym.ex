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

  ## Lifecycle

  A run has two ways in. The one-shot `record_run/1` writes a completed
  `graded` row, as it always has. The live lifecycle starts a run as
  `running` (`start_run/1`), upserts per-task trials against it
  (`record_trial/3`) — each optionally linked to the thread that carries
  its transcript — and closes it with `finalize_run/2` (grades, `graded`)
  or `abandon_run/1` (no grades, `abandoned`). Recipe-digest idempotency
  holds across both ways in: a resubmitted digest replays the existing row.

  A trial's thread link is verified at ingest: the thread must exist and
  belong to the bearer's account, and an unknown thread and an unowned one
  refuse identically, so the check confirms nothing about threads the
  account cannot see. The operator-gated gym surface reads a linked
  transcript back through `fetch_trial_thread/1`, which resolves only
  through that stored, verified linkage. A run still `running` whose last
  update is older than six hours is swept to `abandoned` lazily on the read
  paths, so the scoreboard never shows a forever-running row.

  ## PubSub

  `subscribe/0` joins the `"gym"` topic; `subscribe_run/1` joins
  `"gym:run:" <> run_id`. Both topics carry the same two messages:

    * `{:gym_run, %OpenAgents.Gym.Run{}}` — on record, start, finalize,
      abandon, and sweep. The struct is the run as stored, trials not
      loaded.
    * `{:gym_trial, %OpenAgents.Gym.Trial{}}` — on every trial upsert.

  Operator-only on every path for now: the Gym is a workbench for the
  people building the agent, not a public leaderboard. Widening it later is
  a deliberate act, not a default.
  """

  import Ecto.Query

  alias OpenAgents.Accounts.User
  alias OpenAgents.Gym.Run
  alias OpenAgents.Gym.Trial
  alias OpenAgents.Repo
  alias OpenAgents.Threads

  @maximum_listed 200
  @maximum_trials_per_run 500
  @staleness_seconds 6 * 60 * 60
  @topic "gym"

  @doc "The most trials one run may hold. The bound the trial upsert enforces."
  @spec maximum_trials_per_run() :: pos_integer()
  def maximum_trials_per_run, do: @maximum_trials_per_run

  @doc "Subscribe to every run and trial change, on the `\"gym\"` topic."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(OpenAgents.PubSub, @topic)

  @doc "Subscribe to one run's changes, on `\"gym:run:\" <> run_id`."
  @spec subscribe_run(String.t()) :: :ok | {:error, term()}
  def subscribe_run(run_id) when is_binary(run_id),
    do: Phoenix.PubSub.subscribe(OpenAgents.PubSub, run_topic(run_id))

  @doc """
  Record one completed run, idempotently by recipe digest.

  A resubmitted digest returns the existing row as `{:ok, run, replayed?:
  true}` rather than duplicating or refusing: the harness retries uploads,
  and a retry is not a second run.
  """
  @spec record_run(map()) :: {:ok, Run.t(), boolean()} | {:error, Ecto.Changeset.t()}
  def record_run(attributes) when is_map(attributes) do
    changeset =
      %Run{}
      |> Run.changeset(attributes)
      |> Ecto.Changeset.put_change(:completed_at, DateTime.utc_now())

    insert_or_replay(changeset)
  end

  @doc """
  Register a run at suite start, as `running`.

  Identity now, grades later: `suite`, `agent`, and `model` are required;
  `tasks_total` may carry the planned count. A digest given here replays an
  existing run the same way `record_run/1` does; an absent digest takes a
  generated `pending:` placeholder that `finalize_run/2` replaces.
  """
  @spec start_run(map()) :: {:ok, Run.t(), boolean()} | {:error, Ecto.Changeset.t()}
  def start_run(attributes) when is_map(attributes) do
    insert_or_replay(Run.start_changeset(%Run{}, attributes))
  end

  @doc """
  Fold the grades into a run and close it as `graded`.

  Accepts the same optional fields as `record_run/1`; a digest given here
  replaces the start-time placeholder. Refusals are typed for the door:
  `{:error, :already_graded, run}` for a run that is already terminalized
  with grades — a grade is written once — and `{:error, :digest_conflict,
  existing}` when the new digest already names a different run.
  """
  @spec finalize_run(Run.t(), map()) ::
          {:ok, Run.t()}
          | {:error, :already_graded, Run.t()}
          | {:error, :digest_conflict, Run.t()}
          | {:error, Ecto.Changeset.t()}
  def finalize_run(%Run{status: "graded"} = run, _attributes), do: {:error, :already_graded, run}

  def finalize_run(%Run{} = run, attributes) when is_map(attributes) do
    changeset = Run.finalize_changeset(run, attributes, DateTime.utc_now())

    case Repo.update(changeset) do
      {:ok, updated} ->
        broadcast_run(updated)
        {:ok, updated}

      {:error, %Ecto.Changeset{errors: errors} = failed} ->
        with {_message, options} <- Keyword.get(errors, :recipe_digest),
             true <- options[:constraint] == :unique,
             %Run{} = existing <-
               Repo.get_by(Run,
                 recipe_digest: Ecto.Changeset.get_field(changeset, :recipe_digest)
               ) do
          {:error, :digest_conflict, existing}
        else
          _other -> {:error, failed}
        end
    end
  end

  @doc """
  Close a run without grades, as `abandoned`.

  Idempotent for an already-abandoned run; a graded run refuses, because a
  grade on record outranks a late abandonment.
  """
  @spec abandon_run(Run.t()) :: {:ok, Run.t()} | {:error, :already_graded, Run.t()}
  def abandon_run(%Run{status: "graded"} = run), do: {:error, :already_graded, run}
  def abandon_run(%Run{status: "abandoned"} = run), do: {:ok, run}

  def abandon_run(%Run{} = run) do
    {:ok, updated} = run |> Run.abandon_changeset(DateTime.utc_now()) |> Repo.update()
    broadcast_run(updated)
    {:ok, updated}
  end

  @doc """
  Upsert one trial of a run, by `(run_id, task)`.

  `bearer` is the account behind the request: a `thread_id`, when given, is
  admitted only if `OpenAgents.Threads.get_for_user/2` resolves it for that
  account, and an unknown thread and an unowned one refuse with the same
  `thread_id` error. A report that omits `thread_id` keeps an existing
  link rather than clearing it. Trials per run are bounded; a report for a
  task the run does not hold yet refuses once the bound is reached with
  `{:error, :trial_limit}`.
  """
  @spec record_trial(User.t(), Run.t(), map()) ::
          {:ok, Trial.t()} | {:error, :trial_limit} | {:error, Ecto.Changeset.t()}
  def record_trial(%User{} = bearer, %Run{} = run, attributes) when is_map(attributes) do
    changeset =
      %Trial{}
      |> Trial.changeset(attributes)
      |> Ecto.Changeset.put_change(:run_id, run.id)
      |> verify_thread(bearer)

    with {:ok, valid} <- applied(changeset),
         :ok <- within_trial_bound(run, valid.task) do
      {:ok, trial} =
        Repo.insert(changeset,
          on_conflict: {:replace, replaced_columns(attributes)},
          conflict_target: [:run_id, :task],
          returning: true
        )

      touch(run)
      broadcast_trial(trial)
      {:ok, trial}
    end
  end

  @doc "A run by id with its trials loaded, task order. Sweeps staleness first."
  @spec fetch_run(String.t()) :: {:ok, Run.t()} | :error
  def fetch_run(run_id) when is_binary(run_id) do
    with {:ok, id} <- Ecto.UUID.cast(run_id) do
      sweep_stale()

      case Repo.get(Run, id) do
        %Run{} = run -> {:ok, Repo.preload(run, trials: trials_query())}
        nil -> :error
      end
    end
  end

  @doc "A run by id without trials, for the write paths. No sweep."
  @spec get_run(String.t()) :: Run.t() | nil
  def get_run(run_id) when is_binary(run_id) do
    case Ecto.UUID.cast(run_id) do
      {:ok, id} -> Repo.get(Run, id)
      :error -> nil
    end
  end

  @doc "A run's trials, task order."
  @spec list_trials(Run.t()) :: [Trial.t()]
  def list_trials(%Run{id: run_id}) do
    trials_query() |> where([t], t.run_id == ^run_id) |> Repo.all()
  end

  @doc """
  The thread a trial's transcript lives on, read through the trial linkage.

  This is the read path for the operator-gated gym surface. The `/gym`
  viewer is any operator, not necessarily the thread's owner, so it cannot
  read through the account-scoped `OpenAgents.Threads.fetch_readable/2`.
  Reading here is sound because the linkage is the authority:
  `record_trial/3` admitted the `thread_id` only after
  `OpenAgents.Threads.get_for_user/2` resolved it for the reporting
  bearer's account (INVARIANTS THREAD-001, ADMIN-001), so every stored
  linkage names a thread its reporter owned and deliberately attached to a
  benchmark trial. The trial row is the only key — an arbitrary thread id
  has no path in — and the function reads; it never writes to the thread,
  mints for it, or returns a grant.

  Returns `:error` for an unknown trial, a trial with no linkage, and a
  linked thread that no longer exists — a thread may be deleted with its
  account while the benchmark record stays.
  """
  @spec fetch_trial_thread(String.t()) :: {:ok, Threads.Thread.t()} | :error
  def fetch_trial_thread(trial_id) when is_binary(trial_id) do
    with {:ok, id} <- Ecto.UUID.cast(trial_id),
         %Trial{thread_id: thread_id} when is_binary(thread_id) <- Repo.get(Trial, id),
         %Threads.Thread{} = thread <- Repo.get(Threads.Thread, thread_id) do
      {:ok, thread}
    else
      _no_verified_linkage -> :error
    end
  end

  @doc """
  Runs, newest first, optionally filtered by suite. Bounded.

  Sweeps staleness first, so a read never lists a run that stopped
  reporting six hours ago as still running.
  """
  @spec list_runs(keyword()) :: [Run.t()]
  def list_runs(options \\ []) do
    sweep_stale()

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

  @doc """
  Sweep runs still `running` with no update for six hours to `abandoned`.

  Lazy rather than scheduled: the read paths call it, which is enough for a
  scoreboard whose staleness only matters when somebody reads it. Each
  swept run is broadcast like any other terminal transition.
  """
  @spec sweep_stale() :: non_neg_integer()
  def sweep_stale do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -@staleness_seconds, :second)

    {count, swept} =
      from(r in Run,
        where: r.status == "running" and r.updated_at < ^cutoff,
        select: r
      )
      |> Repo.update_all(set: [status: "abandoned", completed_at: now, updated_at: now])

    Enum.each(swept, &broadcast_run/1)
    count
  end

  defp insert_or_replay(changeset) do
    case Repo.insert(changeset) do
      {:ok, run} ->
        broadcast_run(run)
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

  defp replay(digest, failed) when is_binary(digest) do
    case Repo.get_by(Run, recipe_digest: digest) do
      %Run{} = run -> {:ok, run, true}
      nil -> {:error, failed}
    end
  end

  defp replay(_digest, failed), do: {:error, failed}

  defp filter_suite(query, suite) when is_binary(suite) and suite != "",
    do: where(query, [r], r.suite == ^suite)

  defp filter_suite(query, _absent), do: query

  defp verify_thread(changeset, bearer) do
    case Ecto.Changeset.get_change(changeset, :thread_id) do
      nil ->
        changeset

      thread_id ->
        # One refusal for an unknown thread and an unowned one, so linking
        # cannot be used to probe which thread ids exist.
        if Threads.get_for_user(bearer, thread_id) do
          changeset
        else
          Ecto.Changeset.add_error(
            changeset,
            :thread_id,
            "does not name a thread this account owns"
          )
        end
    end
  end

  defp applied(changeset) do
    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, trial} -> {:ok, trial}
      {:error, _failed} -> {:error, changeset}
    end
  end

  defp within_trial_bound(%Run{id: run_id}, task) do
    known? = Repo.exists?(from(t in Trial, where: t.run_id == ^run_id and t.task == ^task))

    cond do
      known? -> :ok
      count_trials(run_id) < @maximum_trials_per_run -> :ok
      true -> {:error, :trial_limit}
    end
  end

  defp count_trials(run_id) do
    Repo.aggregate(from(t in Trial, where: t.run_id == ^run_id), :count)
  end

  # A report that names no thread keeps an existing link; one that names a
  # thread (already verified) replaces it.
  defp replaced_columns(attributes) do
    if Map.has_key?(attributes, "thread_id") or Map.has_key?(attributes, :thread_id),
      do: [:state, :thread_id, :updated_at],
      else: [:state, :updated_at]
  end

  # A reporting run is not a stale run: every trial report moves the run's
  # `updated_at`, which is the clock the staleness sweep reads.
  defp touch(%Run{id: run_id}) do
    from(r in Run, where: r.id == ^run_id)
    |> Repo.update_all(set: [updated_at: DateTime.utc_now()])
  end

  defp trials_query, do: from(t in Trial, order_by: [asc: t.task])

  defp run_topic(run_id), do: "gym:run:" <> run_id

  defp broadcast_run(%Run{} = run) do
    broadcast(run.id, {:gym_run, run})
  end

  defp broadcast_trial(%Trial{} = trial) do
    broadcast(trial.run_id, {:gym_trial, trial})
  end

  defp broadcast(run_id, message) do
    Phoenix.PubSub.broadcast(OpenAgents.PubSub, @topic, message)
    Phoenix.PubSub.broadcast(OpenAgents.PubSub, run_topic(run_id), message)
  end
end
