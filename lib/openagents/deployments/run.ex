defmodule OpenAgents.Deployments.Run do
  @moduledoc """
  The admitted, immutable execution of one deployment request.

  The run carries the lifecycle state, the durable policy explanation, the lease
  a worker holds while it executes, and the provider receipt. It is the only
  record a provider ever sees, and it holds secret references rather than secret
  values so a provider crash, an event stream, or an audit export cannot spill a
  tenant credential.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @states ~w(requested checking waiting_for_approval queued deploying succeeded failed cancelled superseded)
  @terminal_states ~w(succeeded failed cancelled superseded)
  @active_states ~w(requested checking waiting_for_approval queued deploying)

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "deployment_runs" do
    field :input_digest, :string
    field :state, :string, default: "requested"
    field :result_reason, :string
    field :provider, :string
    field :provider_receipt, :map, default: %{}
    field :policy_explanation, {:array, :map}, default: []
    field :attempt_count, :integer, default: 0
    field :lease_owner, :string
    field :lease_expires_at, :utc_datetime_usec
    field :cancel_requested_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :superseded_by_run_id, :binary_id

    belongs_to :repository, OpenAgents.Repositories.Repository
    belongs_to :environment, OpenAgents.Deployments.Environment
    belongs_to :deployment_request, OpenAgents.Deployments.Request
    belongs_to :cancel_requested_by_user, OpenAgents.Accounts.User

    timestamps()
  end

  @doc false
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :state,
      :result_reason,
      :provider_receipt,
      :policy_explanation,
      :attempt_count,
      :lease_owner,
      :lease_expires_at,
      :cancel_requested_at,
      :started_at,
      :finished_at,
      :superseded_by_run_id
    ])
    |> validate_required([:input_digest, :state, :provider])
    |> validate_inclusion(:state, @states)
    |> validate_length(:result_reason, max: 80)
    |> validate_length(:lease_owner, max: 120)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> unique_constraint(:deployment_request_id)
  end

  @doc "Every legal lifecycle state."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "The states from which no further transition is legal."
  @spec terminal_states() :: [String.t()]
  def terminal_states, do: @terminal_states

  @doc "The states in which a run still holds or awaits work."
  @spec active_states() :: [String.t()]
  def active_states, do: @active_states

  @doc "Whether the run reached a terminal state."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{state: state}), do: state in @terminal_states
end
