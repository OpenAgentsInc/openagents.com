defmodule OpenAgents.Voice.ResponseReceipt do
  @moduledoc "Durable lifecycle and usage receipt for one provider voice response."

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(responding completed interrupted failed)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "voice_response_receipts" do
    belongs_to :voice_session, OpenAgents.Voice.Session
    belongs_to :response_context, OpenAgents.Voice.ResponseContext
    belongs_to :assistant_message, OpenAgents.Conversations.Message
    field :generation, :integer
    field :provider_response_id, :string
    field :status, :string
    field :started_event_sequence, :integer
    field :terminal_event_sequence, :integer
    field :usage, :map, default: %{}
    field :used_source_refs, {:array, :string}, default: []
    field :used_tool_step_refs, {:array, :string}, default: []

    field :used_memory_evidence, :map,
      default: %{"schema" => "sarah.memory_evidence_usage.v1", "items" => []}

    has_many :tool_steps, OpenAgents.Voice.ToolStep, foreign_key: :voice_response_receipt_id
    timestamps()
  end

  def create_changeset(receipt, attributes) do
    receipt
    |> cast(attributes, [
      :voice_session_id,
      :response_context_id,
      :generation,
      :provider_response_id,
      :status,
      :started_event_sequence,
      :usage
    ])
    |> validate_required([
      :voice_session_id,
      :generation,
      :provider_response_id,
      :status,
      :started_event_sequence,
      :usage
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:generation, greater_than: 0)
    |> validate_number(:started_event_sequence, greater_than: 0)
    |> validate_length(:provider_response_id, max: 512)
    |> foreign_key_constraint(:voice_session_id)
    |> foreign_key_constraint(:response_context_id)
    |> unique_constraint([:voice_session_id, :generation, :provider_response_id],
      name: :voice_response_provider_id_index
    )
  end

  def terminal_changeset(receipt, attributes) do
    receipt
    |> cast(attributes, [:status, :terminal_event_sequence, :usage, :assistant_message_id])
    |> validate_required([:status, :terminal_event_sequence, :usage])
    |> validate_inclusion(:status, ~w(completed interrupted failed))
    |> validate_number(:terminal_event_sequence,
      greater_than_or_equal_to: receipt.started_event_sequence
    )
    |> foreign_key_constraint(:assistant_message_id)
  end

  def usage_changeset(receipt, usage) do
    receipt
    |> cast(%{usage: usage}, [:usage])
    |> validate_required([:usage])
  end

  def assistant_message_changeset(receipt, message_id) do
    receipt
    |> cast(%{assistant_message_id: message_id}, [:assistant_message_id])
    |> validate_required([:assistant_message_id])
    |> foreign_key_constraint(:assistant_message_id)
  end

  def evidence_changeset(receipt, attributes) do
    receipt
    |> cast(attributes, [:used_source_refs, :used_tool_step_refs, :used_memory_evidence])
    |> validate_refs(:used_source_refs)
    |> validate_refs(:used_tool_step_refs)
    |> validate_memory_evidence()
  end

  defp validate_refs(changeset, field) do
    validate_change(changeset, field, fn ^field, refs ->
      if is_list(refs) and length(refs) <= 100 and
           Enum.all?(refs, &(is_binary(&1) and byte_size(&1) in 1..256)) and
           length(refs) == MapSet.size(MapSet.new(refs)),
         do: [],
         else: [{field, "must contain unique bounded references"}]
    end)
  end

  defp validate_memory_evidence(changeset) do
    validate_change(changeset, :used_memory_evidence, fn :used_memory_evidence, ledger ->
      if OpenAgents.Memory.Evidence.valid_usage_ledger?(ledger),
        do: [],
        else: [used_memory_evidence: "is invalid"]
    end)
  end
end
