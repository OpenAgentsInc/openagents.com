defmodule OpenAgents.Box.ConversationBox do
  @moduledoc "One box a conversation provisioned, with its last observed lifecycle state."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @states ~w(init provisioning provisioned cloning ready idle running archiving archived error)
  @setup_statuses ~w(pending running done failed)

  schema "conversation_boxes" do
    belongs_to :conversation, OpenAgents.Conversations.Conversation
    field :box_id, :string
    field :state, :string, default: "provisioning"
    field :setup_status, :string, default: "pending"
    field :stopped_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(conversation_box, attrs) do
    conversation_box
    |> cast(attrs, [:state, :setup_status, :stopped_at])
    |> put_programmatic_change(attrs, :conversation_id)
    |> put_programmatic_change(attrs, :box_id)
    |> validate_required([:conversation_id, :box_id, :state, :setup_status])
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:setup_status, @setup_statuses)
    |> unique_constraint(:box_id)
    |> foreign_key_constraint(:conversation_id)
  end

  defp put_programmatic_change(changeset, attrs, field) do
    case Map.fetch(attrs, field) do
      {:ok, value} -> put_change(changeset, field, value)
      :error -> changeset
    end
  end

  @spec states() :: [String.t()]
  def states, do: @states
end
