defmodule OpenAgents.Conversations.Turn do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(queued streaming completed failed cancelled)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "turns" do
    belongs_to :conversation, OpenAgents.Conversations.Conversation
    belongs_to :user_message, OpenAgents.Conversations.Message
    belongs_to :assistant_message, OpenAgents.Conversations.Message
    has_one :receipt, OpenAgents.Conversations.TurnReceipt
    has_many :tool_steps, OpenAgents.Conversations.ToolStep
    field :status, :string, default: "queued"
    field :error_message, :string
    # The real machine-readable failure reason (task_exit:…, invalid_provider_event,
    # …), distinct from the user-facing error_message. Populated on failed turns.
    field :error_code, :string
    field :provider_response_id, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(turn, attributes) do
    turn
    |> cast(attributes, [
      :conversation_id,
      :user_message_id,
      :assistant_message_id,
      :status,
      :error_message,
      :error_code,
      :provider_response_id,
      :started_at,
      :completed_at
    ])
    |> validate_required([:conversation_id, :user_message_id, :assistant_message_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:user_message_id)
    |> foreign_key_constraint(:assistant_message_id)
    |> unique_constraint(:conversation_id,
      name: :turns_one_active_per_conversation_index,
      message: "already has an active turn"
    )
  end
end
