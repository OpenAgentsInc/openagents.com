defmodule OpenAgents.Voice.TranscriptItem do
  @moduledoc """
  Final or explicitly interrupted transcript evidence from one voice generation.

  The words rest sealed. `content_ciphertext` holds them under
  `OpenAgents.ContentVault`, and `text/1` is the only way back to them, so
  nothing reads the sentence by touching a field.

  `VOICE-012` seals call audio and calls this table the conversation record.
  Until issue #193 the record rested in plaintext beside the sealed audio, so a
  stolen dump got the words either way. That asymmetry is what this closes.

  `content` is the plaintext column this table used to keep. It is still
  declared, still loaded, and still read as a fallback, because a rolling
  replacement leaves nodes on the previous release writing into it for as long
  as the roll takes. Nothing writes it any more: the changeset nulls it in the
  same change that seals the words. The contract migration drops it once that
  release is off every node, the way `machine_pairings.user_id` was dropped a
  release after its last reader.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.ContentVault

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @scope "voice_transcript_items.content"
  @maximum_content_bytes 16_000

  schema "voice_transcript_items" do
    belongs_to :voice_session, OpenAgents.Voice.Session
    belongs_to :message, OpenAgents.Conversations.Message
    field :generation, :integer
    field :provider_item_id, :string
    field :provider_response_id, :string
    field :role, :string
    field :content, :string, redact: true
    field :content_ciphertext, :binary, redact: true
    field :status, :string
    field :observed_at, :utc_datetime_usec
    timestamps()
  end

  @doc "The column this schema's sealed text belongs to."
  @spec scope() :: String.t()
  def scope, do: @scope

  @doc """
  The transcript text, opened from the seal.

  Falls back to the plaintext column for a row an un-replaced node wrote during
  a rolling replacement, and returns `nil` when neither can be read.
  """
  @spec text(%__MODULE__{}) :: String.t() | nil
  def text(%__MODULE__{content_ciphertext: sealed} = item) when is_binary(sealed),
    do: ContentVault.text(sealed, @scope, seal_binding(item))

  def text(%__MODULE__{content: content}), do: content

  @doc "The row identity a sealed transcript is bound to: its natural key."
  @spec seal_binding(%__MODULE__{}) :: ContentVault.binding()
  def seal_binding(%__MODULE__{} = item),
    do: [item.voice_session_id, item.generation, item.provider_item_id, item.role]

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
    |> validate_length(:content, min: 1, max: @maximum_content_bytes)
    |> seal_content()
    |> foreign_key_constraint(:voice_session_id)
    |> foreign_key_constraint(:message_id)
    |> unique_constraint(:message_id)
    |> unique_constraint([:voice_session_id, :generation, :provider_item_id, :role],
      name: :voice_transcript_provider_item_role_index
    )
  end

  # The seal happens here rather than in the context, so no insert path reaches
  # this table with the words still readable. A vault that cannot seal fails
  # the changeset: writing the plaintext instead would make the column
  # `OpenAgents.Forge.AtRest` publishes as sealed a claim rather than a fact.
  defp seal_content(%Ecto.Changeset{valid?: true} = changeset) do
    binding = [
      get_field(changeset, :voice_session_id),
      get_field(changeset, :generation),
      get_field(changeset, :provider_item_id),
      get_field(changeset, :role)
    ]

    case ContentVault.seal(get_change(changeset, :content), @scope, binding) do
      {:ok, sealed} ->
        changeset
        |> put_change(:content_ciphertext, sealed)
        |> force_change(:content, nil)

      {:error, reason} ->
        add_error(changeset, :content, "cannot be sealed", reason: reason)
    end
  end

  defp seal_content(changeset), do: changeset
end
