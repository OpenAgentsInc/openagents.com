defmodule OpenAgents.Work.JobStep do
  @moduledoc """
  Ordered durable evidence for one provider-requested tool call inside a job.

  Mirrors `OpenAgents.Conversations.ToolStep` discipline: a step is committed as
  `requested` before execution, claimed `requested -> running` exactly once,
  and finished with one immutable typed `sarah.tool_outcome.v1` envelope. The
  provider continuation is constructed only from the committed terminal row.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(requested running succeeded failed refused cancelled unavailable interrupted)
  @terminal_statuses ~w(succeeded failed refused cancelled unavailable interrupted)
  @digest_regex ~r/\A[0-9a-f]{64}\z/

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "work_job_steps" do
    belongs_to :work_job, OpenAgents.Work.Job
    field :sequence, :integer
    field :provider_call_id, :string
    field :provider_item_id, :string
    field :provider_response_id, :string
    field :tool_name, :string
    field :tool_version, :integer
    field :module_id, :string
    field :module_artifact_digest, :string
    field :catalog_digest, :string
    field :argument_digest, :string
    field :status, :string, default: "requested"
    field :outcome_digest, :string
    field :result, :map
    field :error, :map
    field :usage, :map
    field :executor_id, :string
    field :executor_disclosure, :string
    field :target_receipt_refs, {:array, :string}, default: []
    field :attribution_refs, {:array, :string}, default: []
    field :requested_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    timestamps()
  end

  def statuses, do: @statuses
  def terminal_statuses, do: @terminal_statuses

  def requested_changeset(step, attributes) do
    step
    |> cast(attributes, [
      :work_job_id,
      :sequence,
      :provider_call_id,
      :provider_item_id,
      :provider_response_id,
      :tool_name,
      :tool_version,
      :module_id,
      :module_artifact_digest,
      :catalog_digest,
      :argument_digest,
      :status,
      :requested_at
    ])
    |> validate_required([
      :work_job_id,
      :sequence,
      :provider_call_id,
      :provider_item_id,
      :provider_response_id,
      :tool_name,
      :tool_version,
      :module_id,
      :catalog_digest,
      :argument_digest,
      :status,
      :requested_at
    ])
    |> common_validations()
    |> foreign_key_constraint(:work_job_id)
    |> unique_constraint([:work_job_id, :sequence])
    |> unique_constraint([:work_job_id, :provider_call_id])
  end

  def running_changeset(step, attributes) do
    step
    |> cast(attributes, [:status, :started_at])
    |> validate_required([:status, :started_at])
    |> validate_inclusion(:status, ["running"])
    |> common_validations()
  end

  def terminal_changeset(step, attributes) do
    step
    |> cast(attributes, [
      :status,
      :outcome_digest,
      :result,
      :error,
      :usage,
      :executor_id,
      :executor_disclosure,
      :target_receipt_refs,
      :attribution_refs,
      :completed_at
    ])
    |> validate_required([
      :status,
      :outcome_digest,
      :executor_id,
      :executor_disclosure,
      :completed_at
    ])
    |> validate_inclusion(:status, @terminal_statuses)
    |> common_validations()
  end

  defp common_validations(changeset) do
    changeset
    |> validate_inclusion(:status, @statuses)
    |> validate_format_when_present(:catalog_digest)
    |> validate_format_when_present(:argument_digest)
    |> validate_format_when_present(:outcome_digest)
  end

  defp validate_format_when_present(changeset, field) do
    case get_field(changeset, field) do
      nil -> changeset
      _value -> validate_format(changeset, field, @digest_regex)
    end
  end
end
