defmodule OpenAgents.SCV.Execution do
  @moduledoc "Durable authority and terminal receipt for one Codex-backed SCV run."

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.SCV.DriverAccount
  alias OpenAgents.SCV.ExecutionEvent

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]
  @terminal_statuses ~w(succeeded failed cancelled uncertain)

  schema "scv_runs" do
    belongs_to :driver_account, DriverAccount
    field :driver, :string, default: "codex_app_server"
    field :principal, :string
    field :repository_revision, :string
    field :objective, :string, redact: true
    field :permission_profile, :string, default: "read_only"
    field :model, :string, default: "gpt-5.6-luna"
    field :reasoning_effort, :string, default: "low"
    field :status, :string, default: "running"
    field :owner_node, :string
    field :generation, :integer
    field :lease_expires_at, :utc_datetime_usec
    field :driver_thread_id, :string
    field :driver_turn_id, :string
    field :report, :string, redact: true
    field :report_digest, :string
    field :event_count, :integer, default: 0
    field :usage, :map
    field :resources, :map
    field :error_code, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    has_many :events, ExecutionEvent, foreign_key: :run_id
    timestamps()
  end

  @type t :: %__MODULE__{}

  def terminal?(%__MODULE__{status: status}), do: status in @terminal_statuses

  @doc false
  def claim_changeset(execution, attributes) do
    execution
    |> cast(attributes, [
      :id,
      :driver_account_id,
      :principal,
      :repository_revision,
      :objective,
      :reasoning_effort,
      :owner_node,
      :generation,
      :lease_expires_at,
      :started_at
    ])
    |> validate_required([
      :driver_account_id,
      :principal,
      :repository_revision,
      :objective,
      :owner_node,
      :generation,
      :lease_expires_at,
      :started_at
    ])
    |> validate_length(:objective, min: 1, max: 32_768, count: :bytes)
    |> validate_format(:repository_revision, ~r/\A[0-9a-f]{40}\z/)
    |> validate_inclusion(:reasoning_effort, ~w(none low))
    |> put_change(:driver, "codex_app_server")
    |> put_change(:permission_profile, "read_only")
    |> put_change(:model, "gpt-5.6-luna")
    |> put_change(:status, "running")
    |> foreign_key_constraint(:driver_account_id)
    |> unique_constraint(:driver_account_id, name: :scv_runs_one_active_account_index)
    |> unique_constraint([:driver_account_id, :generation])
    |> check_constraint(:driver, name: :scv_runs_driver_check)
    |> check_constraint(:permission_profile, name: :scv_runs_permission_profile_check)
    |> check_constraint(:reasoning_effort, name: :scv_runs_reasoning_effort_check)
    |> check_constraint(:status, name: :scv_runs_status_check)
    |> check_constraint(:repository_revision, name: :scv_runs_repository_revision_check)
    |> check_constraint(:objective, name: :scv_runs_objective_bound_check)
  end

  @doc false
  def session_changeset(execution, attributes) do
    execution
    |> cast(attributes, [:driver_thread_id, :driver_turn_id])
    |> validate_length(:driver_thread_id, max: 256)
    |> validate_length(:driver_turn_id, max: 256)
  end

  @doc false
  def terminal_changeset(execution, attributes) do
    execution
    |> cast(attributes, [
      :status,
      :report,
      :report_digest,
      :usage,
      :resources,
      :error_code,
      :completed_at
    ])
    |> validate_required([:status, :report, :report_digest, :completed_at])
    |> validate_inclusion(:status, @terminal_statuses)
    |> validate_length(:report, min: 1, max: 32_768, count: :bytes)
    |> validate_format(:report_digest, ~r/\Asha256:[0-9a-f]{64}\z/)
    |> validate_length(:error_code, max: 80)
    |> check_constraint(:status, name: :scv_runs_status_check)
    |> check_constraint(:report, name: :scv_runs_report_bound_check)
  end
end
