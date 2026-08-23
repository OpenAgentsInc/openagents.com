defmodule OpenAgents.Stacks.Operation do
  @moduledoc """
  One durable server-side stack operation.

  The row is the recovery record: it carries the request, the snapshot the
  worker took before touching anything, the planned result, and — for a
  paused rebase — the conflict workspace. A worker crash leaves the row
  claimable again after its lease expires, so the operation resumes instead
  of vanishing.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(create append restructure rebase merge queue unstack dissolve repair)
  @states ~w(pending running waiting_for_conflict_resolution waiting_for_checks succeeded partially_succeeded failed cancelled)
  @active_states ~w(pending running waiting_for_conflict_resolution)

  schema "stack_operations" do
    belongs_to :stack, OpenAgents.Stacks.Stack
    field :kind, :string
    field :state, :string, default: "pending"
    field :target_position, :integer
    field :expected_stack_version, :integer
    field :idempotency_key, :string

    field :request, :map, default: %{}
    field :snapshot, :map
    field :planned_result, :map
    field :conflict, :map
    field :error, :map

    belongs_to :created_by_user, OpenAgents.Accounts.User

    field :attempt_count, :integer, default: 0
    field :retry_at, :utc_datetime_usec
    field :claimed_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds
  def states, do: @states
  def active_states, do: @active_states

  def changeset(operation, attrs) do
    operation
    |> cast(attrs, [
      :kind,
      :state,
      :target_position,
      :expected_stack_version,
      :idempotency_key,
      :request,
      :retry_at
    ])
    |> put_change(:stack_id, Map.fetch!(attrs, :stack_id))
    |> put_change(:created_by_user_id, Map.get(attrs, :created_by_user_id))
    |> validate_required([:stack_id, :kind, :state, :expected_stack_version, :idempotency_key])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:state, @states)
    |> validate_number(:expected_stack_version, greater_than_or_equal_to: 1)
    |> validate_length(:idempotency_key, min: 1, max: 255)
    |> unique_constraint([:stack_id, :idempotency_key])
    |> unique_constraint(:stack_id, name: :stack_operations_active_stack_index)
    |> check_constraint(:kind, name: :stack_operations_kind_check)
    |> check_constraint(:state, name: :stack_operations_state_check)
    |> foreign_key_constraint(:stack_id)
    |> foreign_key_constraint(:created_by_user_id)
  end

  def transition_changeset(operation, attrs) do
    operation
    |> cast(attrs, [
      :state,
      :snapshot,
      :planned_result,
      :conflict,
      :error,
      :attempt_count,
      :retry_at,
      :claimed_at,
      :started_at,
      :completed_at
    ])
    |> validate_required([:state])
    |> validate_inclusion(:state, @states)
    |> check_constraint(:state, name: :stack_operations_state_check)
  end
end
