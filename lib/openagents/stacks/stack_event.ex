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

  @event_types ~w(pull_request_stack.created pull_request_stack.appended)

  schema "pull_request_stack_events" do
    belongs_to :stack, OpenAgents.Stacks.Stack
    field :event_type, :string
    field :stack_version, :integer
    belongs_to :actor_user, OpenAgents.Accounts.User
    field :payload, :map, default: %{}
    timestamps()
  end

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
end
