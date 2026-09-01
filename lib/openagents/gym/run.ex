defmodule OpenAgents.Gym.Run do
  @moduledoc """
  One benchmark run of an agent against a suite, alive or graded.

  A run is a record of measurement, never of execution: the Harbor harness
  (`docs/2026-08-24-harbor-terminal-bench-plan.md`) runs the trials and this
  row holds what came back — how many tasks the suite graded, how many
  passed, what it cost, and the digest of the exact recipe (CLI version,
  model catalog revision, plugin set, dataset version) that produced it.

  A run moves through a small status ladder. `running` is a run the harness
  registered at suite start; its grade columns are still empty. `graded` is
  the terminal state the one-shot ingest has always written and the state a
  finalize reaches; it requires the task counts and a `completed_at`.
  `abandoned` is the terminal state for a run that died without a grade —
  declared by the harness or applied by the lazy staleness sweep — so the
  scoreboard never shows a forever-running row. `cancelled` is the terminal
  state for a run an operator stopped on purpose: gradeless like `abandoned`,
  but a decision rather than a death, and never applied by the sweep.

  `recipe_digest` is unique: submitting the same run twice replays the first
  row rather than duplicating it, so a trend line never counts a run twice.
  A run registered before its recipe is pinned carries a generated
  `pending:` placeholder until finalize supplies the real digest. The
  bounded `report` map carries per-task rows and anything else the harness
  wants to keep beside the headline numbers; it is data about the run, not a
  second transcript store. Per-trial rows with their thread links live in
  `OpenAgents.Gym.Trial`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias OpenAgents.Gym.Trial

  @primary_key {:id, :binary_id, autogenerate: true}

  @statuses ~w(running graded abandoned cancelled)
  @bounded_fields [:suite, :agent, :model, :recipe_digest]
  @maximum_report_bytes 262_144

  schema "gym_runs" do
    field :suite, :string
    field :agent, :string
    field :agent_version, :string
    field :model, :string
    field :lane, :string
    field :status, :string, default: "graded"
    field :tasks_total, :integer
    field :tasks_passed, :integer
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :cost_microusd, :integer
    field :duration_seconds, :integer
    field :recipe_digest, :string
    field :report, :map, default: %{}
    field :completed_at, :utc_datetime_usec
    field :recorded_by_user_id, :binary_id

    has_many :trials, Trial, foreign_key: :run_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def statuses, do: @statuses

  @doc """
  The one-shot graded row `POST /api/v1/gym/runs` has always written.

  The caller supplies the grades with the identity; the context stamps
  `completed_at`, and `status` keeps its `graded` default.
  """
  def changeset(run, attributes) do
    run
    |> cast(attributes, [
      :suite,
      :agent,
      :agent_version,
      :model,
      :lane,
      :tasks_total,
      :tasks_passed,
      :input_tokens,
      :output_tokens,
      :cost_microusd,
      :duration_seconds,
      :recipe_digest,
      :report
    ])
    |> validate_required([:suite, :agent, :model, :tasks_total, :tasks_passed, :recipe_digest])
    |> validate_bounded_fields()
    |> validate_number(:tasks_total, greater_than_or_equal_to: 0)
    |> validate_number(:tasks_passed, greater_than_or_equal_to: 0)
    |> validate_passed_within_total()
    |> validate_report_bound()
    |> check_constraint(:tasks_passed, name: :gym_runs_task_counts_check)
    |> unique_constraint(:recipe_digest)
  end

  @doc """
  Registration at suite start: identity without grades.

  A run registered before its recipe is pinned has no digest yet, and the
  column is unique and required, so an absent digest takes a generated
  `pending:` placeholder that finalize later replaces.
  """
  def start_changeset(run, attributes) do
    run
    |> cast(attributes, [
      :suite,
      :agent,
      :agent_version,
      :model,
      :lane,
      :tasks_total,
      :recipe_digest
    ])
    |> validate_required([:suite, :agent, :model])
    |> put_placeholder_digest()
    |> put_change(:status, "running")
    |> validate_bounded_fields()
    |> validate_number(:tasks_total, greater_than_or_equal_to: 0)
    |> check_constraint(:status, name: :gym_runs_status_check)
    |> unique_constraint(:recipe_digest)
  end

  @doc "Finalization: fold the grades in and close the run as `graded`."
  def finalize_changeset(run, attributes, now) do
    run
    |> cast(attributes, [
      :agent_version,
      :model,
      :tasks_total,
      :tasks_passed,
      :input_tokens,
      :output_tokens,
      :cost_microusd,
      :duration_seconds,
      :recipe_digest,
      :report
    ])
    |> put_change(:status, "graded")
    |> put_change(:completed_at, now)
    |> validate_required([:model, :tasks_total, :tasks_passed, :recipe_digest])
    |> validate_bounded_fields()
    |> validate_number(:tasks_total, greater_than_or_equal_to: 0)
    |> validate_number(:tasks_passed, greater_than_or_equal_to: 0)
    |> validate_passed_within_total()
    |> validate_report_bound()
    |> check_constraint(:tasks_passed, name: :gym_runs_task_counts_check)
    |> check_constraint(:status, name: :gym_runs_status_check)
    |> unique_constraint(:recipe_digest)
  end

  @doc "The gradeless terminal state, declared by the harness or swept."
  def abandon_changeset(run, now) do
    run
    |> change(%{status: "abandoned", completed_at: now})
    |> check_constraint(:status, name: :gym_runs_status_check)
  end

  @doc "The operator-declared gradeless terminal state. Never applied by the sweep."
  def cancel_changeset(run, now) do
    run
    |> change(%{status: "cancelled", completed_at: now})
    |> check_constraint(:status, name: :gym_runs_status_check)
  end

  @doc """
  Pass rate in [0.0, 1.0]; nil for an empty suite rather than a fake 1.0,
  and nil for a run that has no grades yet.
  """
  def score(%__MODULE__{tasks_total: nil}), do: nil
  def score(%__MODULE__{tasks_passed: nil}), do: nil
  def score(%__MODULE__{tasks_total: 0}), do: nil
  def score(%__MODULE__{tasks_total: total, tasks_passed: passed}), do: passed / total

  defp put_placeholder_digest(changeset) do
    case get_field(changeset, :recipe_digest) do
      nil -> put_change(changeset, :recipe_digest, "pending:" <> Ecto.UUID.generate())
      _present -> changeset
    end
  end

  defp validate_bounded_fields(changeset) do
    Enum.reduce(@bounded_fields, changeset, fn field, acc ->
      validate_length(acc, field, min: 1, max: 200, count: :bytes)
    end)
  end

  defp validate_passed_within_total(changeset) do
    total = get_field(changeset, :tasks_total)
    passed = get_field(changeset, :tasks_passed)

    if is_integer(total) and is_integer(passed) and passed > total do
      add_error(changeset, :tasks_passed, "cannot exceed tasks_total")
    else
      changeset
    end
  end

  defp validate_report_bound(changeset) do
    report = get_field(changeset, :report)

    case report do
      map when is_map(map) ->
        if byte_size(Jason.encode!(map)) > @maximum_report_bytes do
          add_error(changeset, :report, "is larger than #{@maximum_report_bytes} bytes")
        else
          changeset
        end

      _other ->
        add_error(changeset, :report, "must be an object")
    end
  end
end
