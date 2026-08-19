defmodule OpenAgents.Voice.TranscriptItem do
  @moduledoc "Final or explicitly interrupted transcript evidence from one voice generation."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "voice_transcript_items" do
    belongs_to :voice_session, OpenAgents.Voice.Session
    belongs_to :message, OpenAgents.Conversations.Message
    field :generation, :integer
    field :provider_item_id, :string
    field :provider_response_id, :string
    field :role, :string
    field :content, :string
    field :status, :string
    field :observed_at, :utc_datetime_usec
    timestamps()
  end

  def create_changeset(item, attributes) do
    item
    |> cast(attributes, [
      :voice_session_id,
      :message_id,
      :generation,
      :provider_item_id,
      :provider_response_id,
      :role,
      :content,
      :status,
      :observed_at
    ])
    |> validate_required([
      :voice_session_id,
      :generation,
      :provider_item_id,
      :role,
      :content,
      :status,
      :observed_at
    ])
    |> validate_inclusion(:role, ~w(user assistant))
    |> validate_inclusion(:status, ~w(final interrupted))
    |> validate_length(:provider_item_id, max: 512)
    |> validate_length(:provider_response_id, max: 512)
    |> validate_length(:content, min: 1, max: 16_000)
    |> foreign_key_constraint(:voice_session_id)
    |> foreign_key_constraint(:message_id)
    |> unique_constraint(:message_id)
    |> unique_constraint([:voice_session_id, :generation, :provider_item_id, :role],
      name: :voice_transcript_provider_item_role_index
    )
  end
end
