defmodule OpenAgents.Conversations.ToolStep do
  @moduledoc "Ordered durable evidence for one provider-requested tool call."

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(requested running succeeded failed refused cancelled unavailable interrupted)
  @terminal_statuses ~w(succeeded failed refused cancelled unavailable interrupted)
  @digest_regex ~r/\A[0-9a-f]{64}\z/

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "turn_tool_steps" do
    belongs_to :turn, OpenAgents.Conversations.Turn
    belongs_to :turn_receipt, OpenAgents.Conversations.TurnReceipt
    belongs_to :routing_receipt, OpenAgents.Modules.RouteReceipt
    field :sequence, :integer
    field :provider_call_id, :string
    field :provider_item_id, :string
    field :provider_response_id, :string
    field :tool_name, :string
    field :tool_version, :integer
    field :module_id, :string
    field :module_artifact_digest, :string
    field :executor_implementation_digest, :string
    field :side_effect_class, :string
    field :invocation_key, :string
    field :attribution_policy_id, :string
    field :attribution_policy_version, :integer
    field :attribution_policy_digest, :string
    field :billable, :boolean, default: false
    field :billable_attribution_key, :string
    field :cost_units, :integer, default: 0
    field :catalog_digest, :string
    field :raw_arguments, :string
    field :argument_digest, :string
    field :status, :string, default: "requested"
    field :outcome_digest, :string
    field :outcome_receipt_ref, :string
    field :usage, :map
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
      :turn_id,
      :turn_receipt_id,
      :sequence,
      :provider_call_id,
      :provider_item_id,
      :provider_response_id,
      :tool_name,
      :tool_version,
      :module_id,
      :module_artifact_digest,
      :executor_implementation_digest,
      :routing_receipt_id,
      :side_effect_class,
      :invocation_key,
      :attribution_policy_id,
      :attribution_policy_version,
      :attribution_policy_digest,
      :billable,
      :billable_attribution_key,
      :cost_units,
      :catalog_digest,
      :raw_arguments,
      :argument_digest,
      :status,
      :requested_at
    ])
    |> validate_required([
      :turn_id,
      :turn_receipt_id,
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
    |> validate_module_identity()
    |> foreign_key_constraint(:turn_id)
    |> foreign_key_constraint(:turn_receipt_id)
    |> foreign_key_constraint(:routing_receipt_id)
    |> unique_constraint([:turn_id, :sequence])
    |> unique_constraint([:turn_id, :provider_call_id])
    |> unique_constraint(:invocation_key)
    |> unique_constraint(:billable_attribution_key)
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
      :outcome_receipt_ref,
      :usage,
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
      :outcome_receipt_ref,
      :usage,
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
    |> validate_inclusion(:side_effect_class, ~w(read_only reversible_write external_effect))
    |> validate_number(:sequence, greater_than: 0, less_than_or_equal_to: 32)
    |> validate_number(:tool_version, greater_than: 0)
    |> validate_number(:attribution_policy_version, greater_than: 0)
    |> validate_number(:cost_units, greater_than_or_equal_to: 0)
    |> validate_length(:provider_call_id, min: 1, max: 256)
    |> validate_length(:provider_item_id, min: 1, max: 256)
    |> validate_length(:provider_response_id, min: 1, max: 512)
    |> validate_length(:tool_name, min: 1, max: 128)
    |> validate_length(:module_id, min: 1, max: 128)
    |> validate_format(:catalog_digest, @digest_regex)
    |> validate_raw_arguments_bytes(262_144)
    |> validate_format(:argument_digest, @digest_regex)
    |> validate_optional_digest(:module_artifact_digest)
    |> validate_optional_digest(:executor_implementation_digest)
    |> validate_optional_digest(:invocation_key)
    |> validate_optional_digest(:attribution_policy_digest)
    |> validate_optional_digest(:billable_attribution_key)
    |> validate_optional_digest(:outcome_digest)
    |> validate_length(:executor_id, max: 128)
    |> validate_length(:executor_disclosure, max: 256)
    |> validate_length(:side_effect_class, max: 64)
    |> validate_length(:attribution_policy_id, max: 128)
    |> validate_length(:outcome_receipt_ref, max: 256)
    |> validate_refs(:target_receipt_refs)
    |> validate_refs(:attribution_refs)
    |> validate_payload(:result, 65_536)
    |> validate_payload(:error, 2_048)
    |> validate_payload(:usage, 4_096)
    |> validate_billing_identity()
  end

  defp validate_billing_identity(changeset) do
    billable = get_field(changeset, :billable)
    key = get_field(changeset, :billable_attribution_key)
    cost_units = get_field(changeset, :cost_units)

    cond do
      billable == true and is_binary(key) and is_integer(cost_units) and cost_units > 0 ->
        changeset

      billable == false and is_nil(key) and cost_units == 0 ->
        changeset

      true ->
        add_error(changeset, :billable, "must match cost and attribution identity")
    end
  end

  defp validate_module_identity(changeset) do
    if get_field(changeset, :module_id) == "sarah.host" do
      validate_required(changeset, [:invocation_key, :side_effect_class, :cost_units])
    else
      validate_required(changeset, [
        :module_artifact_digest,
        :executor_implementation_digest,
        :routing_receipt_id,
        :side_effect_class,
        :invocation_key,
        :attribution_policy_id,
        :attribution_policy_version,
        :attribution_policy_digest,
        :billable,
        :cost_units
      ])
    end
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
