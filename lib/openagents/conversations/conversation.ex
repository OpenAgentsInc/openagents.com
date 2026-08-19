defmodule OpenAgents.Conversations.Conversation do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "conversations" do
    belongs_to :visitor, OpenAgents.Conversations.Visitor
    has_many :messages, OpenAgents.Conversations.Message
    has_many :turns, OpenAgents.Conversations.Turn
    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          visitor_id: Ecto.UUID.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  def changeset(conversation, attributes) do
    conversation
    |> cast(attributes, [:visitor_id])
    |> validate_required([:visitor_id])
    |> foreign_key_constraint(:visitor_id)
    |> unique_constraint(:visitor_id)
  end
end
