defmodule OpenAgents.Conversations.Message do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(user assistant system)
  @statuses ~w(streaming complete failed cancelled)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "messages" do
    belongs_to :conversation, OpenAgents.Conversations.Conversation
    field :role, :string
    field :content, :string, default: ""
    field :status, :string, default: "complete"
    field :provider_response_id, :string
    field :modality, :string, default: "text"
    belongs_to :voice_session, OpenAgents.Voice.Session
    field :provider_item_id, :string
    field :transcript_kind, :string
    field :interrupted, :boolean, default: false
    belongs_to :work_job, OpenAgents.Work.Job
    field :search_vector, :string, load_in_query: false
    timestamps()
  end

  def changeset(message, attributes) do
    message
    |> cast(attributes, [
      :conversation_id,
      :role,
      :content,
      :status,
      :provider_response_id,
      :modality,
      :voice_session_id,
      :provider_item_id,
      :transcript_kind,
      :interrupted,
      :work_job_id
    ])
    |> validate_required([:conversation_id, :role, :status, :modality, :interrupted])
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:modality, ~w(text voice))
    |> validate_voice_provenance()
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:voice_session_id)
    |> unique_constraint([:voice_session_id, :provider_item_id, :role],
      name: :messages_voice_item_role_index
    )
  end

  defp validate_voice_provenance(changeset) do
    modality = get_field(changeset, :modality)

    case modality do
      "text" ->
        changeset

      "voice" ->
        changeset
        |> validate_required([:voice_session_id, :provider_item_id, :transcript_kind])
        |> validate_inclusion(:transcript_kind, [
          "provider_input_transcription",
          "provider_output_transcript"
        ])

      _invalid ->
        changeset
    end
  end
end
