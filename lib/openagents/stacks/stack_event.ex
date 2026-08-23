defmodule OpenAgents.Stacks.StackEvent do
  @moduledoc """
  A transactional outbox row for one stack mutation.

  Every explicit stack mutation writes an event inside the same metadata
  transaction, so consumers replay the mutation history without racing the
  request handler. Consumers deduplicate by event ID.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @event_types ~w(
    pull_request_stack.created
    pull_request_stack.appended
    pull_request_stack.restructured
    pull_request_stack.dissolved
    pull_request_stack.rebase_started
    pull_request_stack.rebase_conflicted
    pull_request_stack.rebase_completed
    pull_request_stack.merge_started
    pull_request_stack.merge_queued
    pull_request_stack.merge_partially_completed
    pull_request_stack.merge_completed
    pull_request_stack.merge_failed
    pull_request.stacked
    pull_request.unstacked
    pull_request.stack_position_changed
    pull_request.synchronize
  )

  schema "pull_request_stack_events" do
    belongs_to :stack, OpenAgents.Stacks.Stack
    field :event_type, :string
    field :stack_version, :integer
    belongs_to :actor_user, OpenAgents.Accounts.User
    field :payload, :map, default: %{}
    field :delivered_at, :utc_datetime_usec
    timestamps()
  end

  @doc "The full event type catalog (docs/stacked-prs.md section 16)."
  def event_types, do: @event_types

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:event_type, :stack_version, :payload])
    |> put_change(:stack_id, Map.fetch!(attrs, :stack_id))
    |> put_change(:actor_user_id, Map.get(attrs, :actor_user_id))
    |> validate_required([:stack_id, :event_type, :stack_version, :payload])
    |> validate_inclusion(:event_type, @event_types)
    |> validate_number(:stack_version, greater_than_or_equal_to: 1)
    |> check_constraint(:stack_version, name: :pull_request_stack_events_version_check)
    |> foreign_key_constraint(:stack_id)
    |> foreign_key_constraint(:actor_user_id)
  end

  @doc "Marks one outbox row delivered."
  def delivered_changeset(event, delivered_at) do
    change(event, delivered_at: delivered_at)
  end
end
