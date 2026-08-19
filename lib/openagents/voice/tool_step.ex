defmodule OpenAgents.Voice.ToolStep do
  @moduledoc "Ordered durable evidence for one governed Realtime function call."

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(requested running succeeded failed refused cancelled unavailable interrupted)
  @terminal_statuses ~w(succeeded failed refused cancelled unavailable interrupted)
  @digest_regex ~r/\A[0-9a-f]{64}\z/

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "voice_tool_steps" do
    belongs_to :voice_session, OpenAgents.Voice.Session
    belongs_to :voice_response_receipt, OpenAgents.Voice.ResponseReceipt
    field :generation, :integer
    field :sequence, :integer
    field :provider_call_id, :string
    field :provider_item_id, :string
    field :provider_response_id, :string
    field :tool_name, :string
    field :tool_version, :integer
    field :module_id, :string
    field :catalog_digest, :string
    field :raw_arguments, :string
    field :argument_digest, :string
    field :status, :string, default: "requested"
    field :outcome_digest, :string
    field :result, :map
    field :error, :map
    field :executor_id, :string
    field :executor_disclosure, :string
    field :target_receipt_refs, {:array, :string}, default: []
    field :attribution_refs, {:array, :string}, default: []
    field :requested_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    timestamps()
  end

  def requested_changeset(step, attributes) do
    step
    |> cast(attributes, [
      :voice_session_id,
      :voice_response_receipt_id,
      :generation,
      :sequence,
      :provider_call_id,
      :provider_item_id,
      :provider_response_id,
      :tool_name,
      :tool_version,
      :module_id,
      :catalog_digest,
      :raw_arguments,
      :argument_digest,
      :status,
      :requested_at
    ])
    |> validate_required([
      :voice_session_id,
      :voice_response_receipt_id,
      :generation,
      :sequence,
      :provider_call_id,
      :provider_item_id,
      :provider_response_id,
      :tool_name,
      :tool_version,
      :module_id,
      :catalog_digest,
      :argument_digest,
      :status,
      :requested_at
    ])
    |> common_validations()
    |> foreign_key_constraint(:voice_session_id)
    |> foreign_key_constraint(:voice_response_receipt_id)
    |> unique_constraint([:voice_session_id, :generation, :sequence],
      name: :voice_tool_steps_sequence_index
    )
    |> unique_constraint([:voice_session_id, :generation, :provider_call_id],
      name: :voice_tool_steps_provider_call_index
    )
  end

  def running_changeset(step, attributes) do
    step
    |> cast(attributes, [:status, :started_at])
    |> validate_required([:status, :started_at])
    |> validate_inclusion(:status, ["running"])
    |> common_validations()
  end

  def terminal_changeset(step, attributes) do
    step
    |> cast(attributes, [
      :status,
      :outcome_digest,
      :result,
      :error,
      :executor_id,
      :executor_disclosure,
      :target_receipt_refs,
      :attribution_refs,
      :completed_at
    ])
    |> validate_required([
      :status,
      :outcome_digest,
      :executor_id,
      :executor_disclosure,
      :completed_at
    ])
    |> validate_inclusion(:status, @terminal_statuses)
    |> common_validations()
    |> validate_terminal_payload()
  end

  defp common_validations(changeset) do
    changeset
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:generation, greater_than: 0)
    |> validate_number(:sequence, greater_than: 0, less_than_or_equal_to: 32)
    |> validate_number(:tool_version, greater_than: 0)
    |> validate_length(:provider_call_id, min: 1, max: 256)
    |> validate_length(:provider_item_id, min: 1, max: 256)
    |> validate_length(:provider_response_id, min: 1, max: 512)
    |> validate_length(:tool_name, min: 1, max: 128)
    |> validate_length(:module_id, min: 1, max: 128)
    |> validate_format(:catalog_digest, @digest_regex)
    |> validate_raw_arguments_bytes(16_384)
    |> validate_format(:argument_digest, @digest_regex)
    |> validate_optional_digest(:outcome_digest)
    |> validate_length(:executor_id, max: 128)
    |> validate_length(:executor_disclosure, max: 256)
    |> validate_refs(:target_receipt_refs)
    |> validate_refs(:attribution_refs)
    |> validate_payload(:result, 65_536)
    |> validate_payload(:error, 2_048)
  end

  defp validate_raw_arguments_bytes(changeset, maximum_bytes) do
    validate_change(changeset, :raw_arguments, fn :raw_arguments, value ->
      if is_binary(value) and byte_size(value) <= maximum_bytes,
        do: [],
        else: [{:raw_arguments, "must be a bounded string"}]
    end)
  end

  defp validate_optional_digest(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_binary(value) and Regex.match?(@digest_regex, value),
        do: [],
        else: [{field, "must be a SHA-256 digest"}]
    end)
  end

  defp validate_refs(changeset, field) do
    validate_change(changeset, field, fn ^field, refs ->
      if is_list(refs) and length(refs) <= 64 and
           Enum.all?(refs, &(is_binary(&1) and byte_size(&1) in 1..256)),
         do: [],
         else: [{field, "must contain bounded references"}]
    end)
  end

  defp validate_payload(changeset, field, maximum_bytes) do
    validate_change(changeset, field, fn ^field, value ->
      case Jason.encode(value) do
        {:ok, encoded} when byte_size(encoded) <= maximum_bytes -> []
        _invalid -> [{field, "is too large or invalid"}]
      end
    end)
  end

  defp validate_terminal_payload(changeset) do
    status = get_field(changeset, :status)
    result = get_field(changeset, :result)
    error = get_field(changeset, :error)

    cond do
      status == "succeeded" and is_map(result) and is_nil(error) ->
        changeset

      status in @terminal_statuses and status != "succeeded" and is_nil(result) and is_map(error) ->
        changeset

      true ->
        add_error(changeset, :status, "does not match terminal result/error payload")
    end
  end
end
