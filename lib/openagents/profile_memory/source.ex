defmodule OpenAgents.ProfileMemory.Source do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  schema "profile_memory_sources" do
    belongs_to :memory_record, OpenAgents.ProfileMemory.Record, primary_key: true
    belongs_to :message, OpenAgents.Conversations.Message, primary_key: true
    field :source_kind, :string
    field :inserted_at, :utc_datetime_usec
  end

  def changeset(source, attributes) do
    source
    |> cast(attributes, [:memory_record_id, :message_id, :source_kind, :inserted_at])
    |> validate_required([:memory_record_id, :message_id, :source_kind, :inserted_at])
    |> validate_inclusion(:source_kind, ["owner_statement", "owner_confirmation"])
    |> foreign_key_constraint(:memory_record_id)
    |> foreign_key_constraint(:message_id)
    |> unique_constraint([:memory_record_id, :message_id],
      name: :profile_memory_sources_pkey
    )
  end
end
