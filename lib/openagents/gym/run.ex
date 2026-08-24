defmodule OpenAgents.Gym.Run do
  @moduledoc """
  One graded benchmark run of an agent against a suite.

  A run is a record of measurement, never of execution: the Harbor harness
  (`docs/2026-08-24-harbor-terminal-bench-plan.md`) runs the trials and this
  row holds what came back — how many tasks the suite graded, how many
  passed, what it cost, and the digest of the exact recipe (CLI version,
  model catalog revision, plugin set, dataset version) that produced it.

  `recipe_digest` is unique: submitting the same run twice replays the first
  row rather than duplicating it, so a trend line never counts a run twice.
  The bounded `report` map carries per-task rows and anything else the
  harness wants to keep beside the headline numbers; it is data about the
  run, not a second transcript store.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @bounded_fields [:suite, :agent, :model, :recipe_digest]
  @maximum_report_bytes 262_144

  schema "gym_runs" do
    field :suite, :string
    field :agent, :string
    field :agent_version, :string
    field :model, :string
    field :lane, :string
    field :tasks_total, :integer
    field :tasks_passed, :integer
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :cost_microusd, :integer
    field :duration_seconds, :integer
    field :recipe_digest, :string
    field :report, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

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

  @doc "Pass rate in [0.0, 1.0]; nil for an empty suite rather than a fake 1.0."
  def score(%__MODULE__{tasks_total: 0}), do: nil
  def score(%__MODULE__{tasks_total: total, tasks_passed: passed}), do: passed / total

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
