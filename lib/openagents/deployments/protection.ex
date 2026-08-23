defmodule OpenAgents.Deployments.Protection do
  @moduledoc """
  One environment's protection policy, stored as a typed embedded document.

  The policy is data rather than code so an environment can tighten without a
  release, but it is a schema rather than a free map so an unknown key or an
  impossible window cannot reach evaluation. Every field answers one question
  the policy evaluator asks about an exact commit and artifact.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @concurrency ~w(queue cancel reject supersede)
  @weekdays 1..7

  @type t :: %__MODULE__{}

  @primary_key false
  embedded_schema do
    field :required_checks, {:array, :string}, default: []
    field :required_approvals, :integer, default: 0
    field :separation_of_duties, :boolean, default: true
    field :approver_roles, {:array, :string}, default: ["owner", "maintainer"]
    field :allowed_branches, {:array, :string}, default: []
    field :allowed_tags, {:array, :string}, default: []
    field :allowed_workflows, {:array, :string}, default: []
    field :window_weekdays, {:array, :integer}, default: []
    field :window_start_minute, :integer
    field :window_end_minute, :integer
    field :frozen, :boolean, default: false
    field :freeze_reason, :string
    field :concurrency, :string, default: "queue"
    field :maximum_artifact_age_seconds, :integer
    field :check_validity_seconds, :integer
  end

  @doc false
  def changeset(protection, attrs) do
    protection
    |> cast(attrs, [
      :required_checks,
      :required_approvals,
      :separation_of_duties,
      :approver_roles,
      :allowed_branches,
      :allowed_tags,
      :allowed_workflows,
      :window_weekdays,
      :window_start_minute,
      :window_end_minute,
      :frozen,
      :freeze_reason,
      :concurrency,
      :maximum_artifact_age_seconds,
      :check_validity_seconds
    ])
    |> validate_number(:required_approvals,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 10
    )
    |> validate_inclusion(:concurrency, @concurrency)
    |> validate_length(:freeze_reason, max: 200)
    |> validate_bounded_names(:required_checks)
    |> validate_subset(:approver_roles, ~w(owner maintainer contributor))
    |> validate_length(:approver_roles, min: 1)
    |> validate_bounded_names(:allowed_branches)
    |> validate_bounded_names(:allowed_tags)
    |> validate_bounded_names(:allowed_workflows)
    |> validate_weekdays()
    |> validate_minute(:window_start_minute)
    |> validate_minute(:window_end_minute)
    |> validate_window_pair()
    |> validate_number(:maximum_artifact_age_seconds, greater_than: 0)
    |> validate_number(:check_validity_seconds, greater_than: 0)
  end

  @doc "Whether the policy admits deployment at any hour of any day."
  @spec unrestricted_window?(t()) :: boolean()
  def unrestricted_window?(%__MODULE__{} = protection) do
    protection.window_weekdays == [] and is_nil(protection.window_start_minute) and
      is_nil(protection.window_end_minute)
  end

  @doc """
  Whether the policy admits deployment at `date_time`, in UTC.

  A window that wraps midnight is legal: `window_start_minute` above
  `window_end_minute` means the window runs from the start minute through the
  end minute on the following day.
  """
  @spec within_window?(t(), DateTime.t()) :: boolean()
  def within_window?(%__MODULE__{} = protection, %DateTime{} = date_time) do
    weekday_admitted?(protection, date_time) and minute_admitted?(protection, date_time)
  end

  defp weekday_admitted?(%__MODULE__{window_weekdays: []}, _date_time), do: true

  defp weekday_admitted?(%__MODULE__{window_weekdays: weekdays}, date_time),
    do: Date.day_of_week(DateTime.to_date(date_time)) in weekdays

  defp minute_admitted?(%__MODULE__{window_start_minute: nil, window_end_minute: nil}, _time),
    do: true

  defp minute_admitted?(%__MODULE__{} = protection, date_time) do
    minute = date_time.hour * 60 + date_time.minute
    start_minute = protection.window_start_minute || 0
    end_minute = protection.window_end_minute || 1_439

    if start_minute <= end_minute do
      minute >= start_minute and minute <= end_minute
    else
      minute >= start_minute or minute <= end_minute
    end
  end

  defp validate_bounded_names(changeset, field) do
    changeset
    |> validate_change(field, fn ^field, values ->
      cond do
        length(values) > 20 -> [{field, "admits at most 20 entries"}]
        Enum.any?(values, &(not valid_name?(&1))) -> [{field, "contains an invalid entry"}]
        true -> []
      end
    end)
  end

  defp valid_name?(value) when is_binary(value),
    do: byte_size(value) in 1..120 and String.printable?(value)

  defp valid_name?(_value), do: false

  defp validate_weekdays(changeset) do
    validate_change(changeset, :window_weekdays, fn :window_weekdays, weekdays ->
      if Enum.all?(weekdays, &(&1 in @weekdays)) and
           length(Enum.uniq(weekdays)) == length(weekdays) do
        []
      else
        [window_weekdays: "must be unique ISO weekday numbers"]
      end
    end)
  end

  defp validate_minute(changeset, field),
    do:
      validate_number(changeset, field, greater_than_or_equal_to: 0, less_than_or_equal_to: 1_439)

  defp validate_window_pair(changeset) do
    start_minute = get_field(changeset, :window_start_minute)
    end_minute = get_field(changeset, :window_end_minute)

    case {start_minute, end_minute} do
      {nil, nil} ->
        changeset

      {nil, _end} ->
        add_error(changeset, :window_start_minute, "is required with a window end")

      {_start, nil} ->
        add_error(changeset, :window_end_minute, "is required with a window start")

      {same, same} ->
        add_error(changeset, :window_end_minute, "must differ from the window start")

      {_start, _end} ->
        changeset
    end
  end
end
