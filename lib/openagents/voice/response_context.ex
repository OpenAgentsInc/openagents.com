defmodule OpenAgents.Voice.ResponseContext do
  @moduledoc "Immutable evidence and program capture for one spoken user response cycle."

  use Ecto.Schema
  import Ecto.Changeset

  @digest_regex ~r/\A[0-9a-f]{64}\z/
  @memory_snapshot_regex ~r/\Amessage:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @profile_memory_snapshot_regex ~r/\Aprofile-memory-snapshot:v1:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "voice_response_contexts" do
    belongs_to :voice_session, OpenAgents.Voice.Session
    belongs_to :user_message, OpenAgents.Conversations.Message
    field :generation, :integer
    field :provider_input_item_id, :string
    field :instructions, :string
    field :instruction_digest, :string
    field :memory_snapshot_ref, :string
    field :profile_memory_snapshot_ref, :string
    field :selected_evidence, :map
    field :selected_source_refs, {:array, :string}, default: []
    field :program_artifact_id, :string
    field :program_artifact_digest, :string
    field :program_artifact_receipt, :map
    field :captured_at, :utc_datetime_usec
    timestamps(updated_at: false)
  end

  def create_changeset(context, attributes) do
    context
    |> cast(attributes, [
      :voice_session_id,
      :user_message_id,
      :generation,
      :provider_input_item_id,
      :instructions,
      :instruction_digest,
      :memory_snapshot_ref,
      :profile_memory_snapshot_ref,
      :selected_evidence,
      :selected_source_refs,
      :program_artifact_id,
      :program_artifact_digest,
      :program_artifact_receipt,
      :captured_at
    ])
    |> validate_required([
      :voice_session_id,
      :user_message_id,
      :generation,
      :provider_input_item_id,
      :instructions,
      :instruction_digest,
      :memory_snapshot_ref,
      :profile_memory_snapshot_ref,
      :selected_evidence,
      :selected_source_refs,
      :program_artifact_receipt,
      :captured_at
    ])
    |> validate_number(:generation, greater_than: 0)
    |> validate_length(:provider_input_item_id, min: 1, max: 512)
    |> validate_length(:instructions, min: 1, max: 65_536)
    |> validate_format(:instruction_digest, @digest_regex)
    |> validate_format(:memory_snapshot_ref, @memory_snapshot_regex)
    |> validate_format(:profile_memory_snapshot_ref, @profile_memory_snapshot_regex)
    |> validate_optional_digest(:program_artifact_digest)
    |> validate_refs()
    |> validate_map(:selected_evidence, 65_536)
    |> validate_map(:program_artifact_receipt, 4_096)
    |> foreign_key_constraint(:voice_session_id)
    |> foreign_key_constraint(:user_message_id)
    |> unique_constraint([:voice_session_id, :generation, :provider_input_item_id],
      name: :voice_response_context_input_item_index
    )
    |> unique_constraint(:user_message_id)
  end

  defp validate_optional_digest(changeset, field) do
    case get_field(changeset, field) do
      nil -> changeset
      _digest -> validate_format(changeset, field, @digest_regex)
    end
  end

  defp validate_refs(changeset) do
    validate_change(changeset, :selected_source_refs, fn :selected_source_refs, refs ->
      if is_list(refs) and length(refs) <= 100 and
           Enum.all?(refs, &(is_binary(&1) and byte_size(&1) in 1..256)) and
           length(refs) == MapSet.size(MapSet.new(refs)),
         do: [],
         else: [selected_source_refs: "must contain unique bounded references"]
    end)
  end

  defp validate_map(changeset, field, maximum_bytes) do
    validate_change(changeset, field, fn ^field, value ->
      case Jason.encode(value) do
        {:ok, encoded} when byte_size(encoded) <= maximum_bytes -> []
        _invalid -> [{field, "is invalid or too large"}]
      end
    end)
  end
end
