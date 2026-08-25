defmodule OpenAgents.Voice.Session do
  @moduledoc "Durable admission and lifecycle record for one fenced voice generation."

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.ContentVault

  @statuses ~w(connecting listening responding interrupted reconnecting ended failed)
  @digest_regex ~r/\A[0-9a-f]{64}\z/
  @compaction_summary_scope "voice_sessions.compaction_summary"

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "voice_sessions" do
    belongs_to :conversation, OpenAgents.Conversations.Conversation
    belongs_to :release_control, OpenAgents.Voice.ReleaseControl
    field :generation, :integer
    field :status, :string
    field :architecture, :string
    field :provider_id, :string
    field :model_id, :string
    field :voice_artifact_id, :string
    field :provider_session_id, :string
    field :persona_id, :string
    field :persona_digest, :string
    field :role_id, :string
    field :role_digest, :string
    field :role_selection, :map
    field :instruction_digest, :string
    field :instructions, :string
    field :tool_catalog_digest, :string
    field :tool_catalog, :map
    field :blueprint_revision, :string
    field :blueprint_digest, :string
    field :program_artifact_id, :string
    field :program_artifact_digest, :string
    field :program_artifact_receipt, :map
    field :event_sequence, :integer, default: 0
    field :usage, :map, default: %{}
    field :compaction_summary, :string, redact: true
    field :compaction_summary_ciphertext, :binary, redact: true
    field :compaction_count, :integer, default: 0
    field :started_at, :utc_datetime_usec
    field :connected_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :termination_reason, :string
    field :failure_code, :string
    field :operational_purged_at, :utc_datetime_usec
    has_many :events, OpenAgents.Voice.PersistedEvent, foreign_key: :voice_session_id
    has_many :response_receipts, OpenAgents.Voice.ResponseReceipt, foreign_key: :voice_session_id
    has_many :response_contexts, OpenAgents.Voice.ResponseContext, foreign_key: :voice_session_id
    has_many :transcript_items, OpenAgents.Voice.TranscriptItem, foreign_key: :voice_session_id
    has_many :tool_steps, OpenAgents.Voice.ToolStep, foreign_key: :voice_session_id
    has_one :recording, OpenAgents.Voice.Recording, foreign_key: :voice_session_id
    timestamps()
  end

  def create_changeset(session, attributes) do
    session
    |> cast(attributes, [
      :conversation_id,
      :release_control_id,
      :generation,
      :status,
      :architecture,
      :provider_id,
      :model_id,
      :voice_artifact_id,
      :persona_id,
      :persona_digest,
      :role_id,
      :role_digest,
      :role_selection,
      :instruction_digest,
      :instructions,
      :tool_catalog_digest,
      :tool_catalog,
      :blueprint_revision,
      :blueprint_digest,
      :program_artifact_id,
      :program_artifact_digest,
      :program_artifact_receipt,
      :started_at
    ])
    |> validate_required([
      :conversation_id,
      :release_control_id,
      :generation,
      :status,
      :architecture,
      :provider_id,
      :model_id,
      :voice_artifact_id,
      :persona_id,
      :persona_digest,
      :role_id,
      :role_digest,
      :role_selection,
      :instruction_digest,
      :instructions,
      :tool_catalog_digest,
      :tool_catalog,
      :program_artifact_receipt,
      :started_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:generation, greater_than: 0)
    |> validate_format(:persona_digest, @digest_regex)
    |> validate_format(:role_digest, @digest_regex)
    |> validate_format(:instruction_digest, @digest_regex)
    |> validate_format(:tool_catalog_digest, @digest_regex)
    |> validate_optional_digest(:blueprint_digest)
    |> validate_optional_digest(:program_artifact_digest)
    |> validate_length(:instructions, min: 1, max: 65_536)
    |> validate_map(:tool_catalog, 65_536)
    |> validate_map(:program_artifact_receipt, 4_096)
    |> validate_tool_catalog_identity()
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:release_control_id)
    |> unique_constraint([:conversation_id, :generation])
    |> unique_constraint(:conversation_id,
      name: :voice_sessions_one_active_per_conversation_index
    )
  end

  def lifecycle_changeset(session, attributes) do
    session
    |> cast(attributes, [
      :status,
      :provider_session_id,
      :event_sequence,
      :usage,
      :connected_at,
      :ended_at,
      :termination_reason,
      :failure_code
    ])
    |> validate_required([:status, :event_sequence, :usage])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:event_sequence, greater_than_or_equal_to: 0)
    |> unique_constraint(:provider_session_id)
  end

  @doc """
  Records one bounded in-call compaction summary. The summary is continuity
  evidence for a long call; it never rewrites transcript or message authority.
  """
  def compaction_changeset(session, attributes) do
    session
    |> cast(attributes, [:compaction_summary, :compaction_count])
    |> validate_required([:compaction_summary, :compaction_count])
    |> validate_number(:compaction_count, greater_than_or_equal_to: 0)
    |> validate_length(:compaction_summary, min: 1, max: 8_192, count: :bytes)
    |> seal_compaction_summary()
  end

  @doc "The column this schema's sealed summary belongs to."
  @spec compaction_summary_scope() :: String.t()
  def compaction_summary_scope, do: @compaction_summary_scope

  @doc """
  The in-call compaction summary, opened from the seal.

  Falls back to the plaintext column for a row an un-replaced node wrote during
  a rolling replacement, and is `nil` once retention has purged it.
  """
  @spec compaction_summary(%__MODULE__{}) :: String.t() | nil
  def compaction_summary(%__MODULE__{compaction_summary_ciphertext: sealed} = session)
      when is_binary(sealed),
      do:
        ContentVault.text(sealed, @compaction_summary_scope, compaction_summary_binding(session))

  def compaction_summary(%__MODULE__{compaction_summary: summary}), do: summary

  @doc "The row identity a sealed compaction summary is bound to."
  @spec compaction_summary_binding(%__MODULE__{}) :: ContentVault.binding()
  def compaction_summary_binding(%__MODULE__{} = session), do: [session.id, session.generation]

  # Sealed in the changeset so no update path reaches this column with the
  # words still readable. Retention nulls both halves together, which is why
  # this only ever runs on a change.
  defp seal_compaction_summary(%Ecto.Changeset{valid?: true} = changeset) do
    case get_change(changeset, :compaction_summary) do
      nil ->
        changeset

      summary ->
        binding = [get_field(changeset, :id), get_field(changeset, :generation)]

        case ContentVault.seal(summary, @compaction_summary_scope, binding) do
          {:ok, sealed} ->
            changeset
            |> put_change(:compaction_summary_ciphertext, sealed)
            |> force_change(:compaction_summary, nil)

          {:error, reason} ->
            add_error(changeset, :compaction_summary, "cannot be sealed", reason: reason)
        end
    end
  end

  defp seal_compaction_summary(changeset), do: changeset

  defp validate_map(changeset, field, maximum_bytes) do
    validate_change(changeset, field, fn ^field, value ->
      case Jason.encode(value) do
        {:ok, encoded} when byte_size(encoded) <= maximum_bytes -> []
        _invalid -> [{field, "is invalid or too large"}]
      end
    end)
  end

  defp validate_optional_digest(changeset, field) do
    case get_field(changeset, field) do
      nil -> changeset
      _digest -> validate_format(changeset, field, @digest_regex)
    end
  end

  defp validate_tool_catalog_identity(changeset) do
    validate_change(changeset, :tool_catalog, fn :tool_catalog, catalog ->
      if catalog["schema"] == "sarah.realtime_tool_catalog.v1" and
           catalog["digest"] == get_field(changeset, :tool_catalog_digest) and
           is_list(catalog["tools"]),
         do: [],
         else: [tool_catalog: "does not match the captured catalog identity"]
    end)
  end
end
