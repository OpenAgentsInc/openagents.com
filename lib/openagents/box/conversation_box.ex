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
    field :label, :string
    field :state, :string, default: "provisioning"
    field :setup_status, :string, default: "pending"
    field :stopped_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(conversation_box, attrs) do
    conversation_box
    |> cast(attrs, [:state, :setup_status, :stopped_at, :label])
    |> put_programmatic_change(attrs, :conversation_id)
    |> put_programmatic_change(attrs, :box_id)
    |> put_default_label()
    |> validate_required([:conversation_id, :box_id, :label, :state, :setup_status])
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:setup_status, @setup_statuses)
    |> unique_constraint(:box_id)
    |> unique_constraint(:label, name: :conversation_boxes_active_label_index)
    |> foreign_key_constraint(:conversation_id)
  end

  defp put_programmatic_change(changeset, attrs, field) do
    case Map.fetch(attrs, field) do
      {:ok, value} -> put_change(changeset, field, value)
      :error -> changeset
    end
  end

  defp put_default_label(changeset) do
    case get_field(changeset, :label) do
      label when is_binary(label) and label != "" ->
        changeset

      _missing ->
        case get_field(changeset, :box_id) do
          box_id when is_binary(box_id) ->
            put_change(changeset, :label, "box-" <> String.slice(box_id, 0, 64))

          _missing_box_id ->
            changeset
        end
    end
  end

  @spec states() :: [String.t()]
  def states, do: @states
end
