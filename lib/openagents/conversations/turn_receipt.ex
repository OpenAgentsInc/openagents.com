defmodule OpenAgents.Conversations.TurnReceipt do
  @moduledoc "Immutable artifact identity and bounded lifecycle evidence for one turn."

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(captured completed failed cancelled interrupted)
  @digest_regex ~r/\A[0-9a-f]{64}\z/
  @memory_snapshot_regex ~r/\Amessage:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @profile_memory_snapshot_regex ~r/\Aprofile-memory-snapshot:v1:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @preference_snapshot_regex ~r/\Apreference-snapshot:v1:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @experience_bank_regex ~r/\Aexperience-bank:v1:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @maximum_refs 100
  @maximum_ref_bytes 256

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "turn_receipts" do
    belongs_to :turn, OpenAgents.Conversations.Turn
    field :schema_version, :integer, default: 1
    field :status, :string, default: "captured"
    field :model_id, :string
    field :persona_id, :string
    field :persona_digest, :string
    field :role_id, :string
    field :role_digest, :string
    field :role_selection, :map
    field :instruction_digest, :string
    field :input_digest, :string
    field :input_message_count, :integer
    field :input_bytes, :integer
    field :tool_catalog_digest, :string
    field :blueprint_revision, :string
    field :blueprint_digest, :string
    field :program_artifact_id, :string
    field :program_artifact_digest, :string
    field :program_artifact_receipt, :map
    field :memory_snapshot_ref, :string
    field :profile_memory_snapshot_ref, :string
    field :preference_snapshot_ref, :string

    field :used_preferences, :map,
      default: %{"schema" => "sarah.preference_usage.v1", "applied" => [], "overridden" => []}

    field :experience_bank_ref, :string

    field :used_experiences, :map,
      default: %{
        "schema" => "sarah.experience_usage.v1",
        "record_refs" => [],
        "pattern_refs" => [],
        "bank_digest" => nil
      }

    field :used_source_refs, {:array, :string}, default: []
    field :used_tool_step_refs, {:array, :string}, default: []

    field :used_memory_evidence, :map,
      default: %{"schema" => "sarah.memory_evidence_usage.v1", "items" => []}

    field :usage, :map
    field :provider_started_at, :utc_datetime_usec
    field :provider_completed_at, :utc_datetime_usec
    timestamps()
  end

  def create_changeset(receipt, attributes) do
    receipt
    |> cast(attributes, [
      :turn_id,
      :schema_version,
      :status,
      :model_id,
      :persona_id,
      :persona_digest,
      :role_id,
      :role_digest,
      :role_selection,
      :instruction_digest,
      :input_digest,
      :input_message_count,
      :input_bytes,
      :tool_catalog_digest,
      :blueprint_revision,
      :blueprint_digest,
      :program_artifact_id,
      :program_artifact_digest,
      :program_artifact_receipt,
      :memory_snapshot_ref,
      :profile_memory_snapshot_ref,
      :preference_snapshot_ref,
      :used_preferences,
      :experience_bank_ref,
      :used_experiences,
      :used_source_refs,
      :used_tool_step_refs,
      :used_memory_evidence,
      :usage,
      :provider_started_at,
      :provider_completed_at
    ])
    |> validate_required([
      :turn_id,
      :schema_version,
      :status,
      :model_id,
      :persona_id,
      :persona_digest,
      :role_id,
      :role_digest,
      :role_selection,
      :instruction_digest,
      :input_digest,
      :input_message_count,
      :input_bytes,
      :provider_started_at
    ])
    |> common_validations()
    |> foreign_key_constraint(:turn_id)
    |> unique_constraint(:turn_id)
  end

  def lifecycle_changeset(receipt, attributes) do
    receipt
    |> cast(attributes, [
      :status,
      :used_source_refs,
      :used_tool_step_refs,
      :used_memory_evidence,
      :usage,
      :provider_completed_at
    ])
    |> common_validations()
  end

  defp common_validations(changeset) do
    changeset
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:schema_version, equal_to: 1)
    |> validate_number(:input_message_count, greater_than_or_equal_to: 0)
    |> validate_number(:input_bytes, greater_than_or_equal_to: 0)
    |> validate_digest(:persona_digest)
    |> validate_digest(:role_digest)
    |> validate_role_selection()
    |> validate_digest(:instruction_digest)
    |> validate_digest(:input_digest)
    |> validate_optional_digest(:tool_catalog_digest)
    |> validate_optional_digest(:blueprint_digest)
    |> validate_optional_digest(:program_artifact_digest)
    |> validate_program_artifact_receipt()
    |> validate_format(:memory_snapshot_ref, @memory_snapshot_regex)
    |> validate_optional_format(:profile_memory_snapshot_ref, @profile_memory_snapshot_regex)
    |> validate_optional_format(:preference_snapshot_ref, @preference_snapshot_regex)
    |> validate_preference_usage()
    |> validate_optional_format(:experience_bank_ref, @experience_bank_regex)
    |> validate_experience_usage()
    |> validate_refs(:used_source_refs)
    |> validate_refs(:used_tool_step_refs)
    |> validate_memory_evidence_usage()
    |> validate_usage()
  end

  defp validate_digest(changeset, field), do: validate_format(changeset, field, @digest_regex)

  defp validate_optional_format(changeset, field, format) do
    case get_field(changeset, field) do
      nil -> changeset
      _value -> validate_format(changeset, field, format)
    end
  end

  defp validate_role_selection(changeset) do
    validate_change(changeset, :role_selection, fn :role_selection, selection ->
      required_keys =
        ~w(schema role_id role_digest surface authority reason input_digest catalog_digest available_capabilities)

      cond do
        selection["schema"] != "sarah.role_selection.v1" ->
          [role_selection: "has an unsupported schema"]

        Enum.any?(required_keys, &(not Map.has_key?(selection, &1))) ->
          [role_selection: "is missing required provenance"]

        selection["role_id"] != get_field(changeset, :role_id) or
            selection["role_digest"] != get_field(changeset, :role_digest) ->
          [role_selection: "does not match the selected role"]

        byte_size(Jason.encode!(selection)) > 4_096 ->
          [role_selection: "is too large"]

        true ->
          []
      end
    end)
  end

  defp validate_program_artifact_receipt(changeset) do
    validate_change(changeset, :program_artifact_receipt, fn :program_artifact_receipt, receipt ->
      cond do
        receipt["schema"] != "sarah.program_capture.v1" ->
          [program_artifact_receipt: "has an unsupported schema"]

        receipt["artifact_id"] != get_field(changeset, :program_artifact_id) or
            receipt["artifact_digest"] != get_field(changeset, :program_artifact_digest) ->
          [program_artifact_receipt: "does not match artifact identity"]

        not is_boolean(receipt["degraded"]) ->
          [program_artifact_receipt: "must state degradation"]

        byte_size(Jason.encode!(receipt)) > 4_096 ->
          [program_artifact_receipt: "is too large"]

        true ->
          []
      end
    end)
  end

  defp validate_optional_digest(changeset, field) do
    case get_field(changeset, field) do
      nil -> changeset
      _digest -> validate_digest(changeset, field)
    end
  end

  defp validate_refs(changeset, field) do
    validate_change(changeset, field, fn ^field, refs ->
      cond do
        length(refs) > @maximum_refs ->
          [{field, "has too many references"}]

        Enum.any?(refs, &(not is_binary(&1) or &1 == "" or byte_size(&1) > @maximum_ref_bytes)) ->
          [{field, "contains an invalid reference"}]

        length(refs) != MapSet.size(MapSet.new(refs)) ->
          [{field, "contains duplicate references"}]

        true ->
          []
      end
    end)
  end

  defp validate_usage(changeset) do
    validate_change(changeset, :usage, fn :usage, usage ->
      if byte_size(Jason.encode!(usage)) <= 16_384,
        do: [],
        else: [usage: "is too large"]
    end)
  end

  defp validate_memory_evidence_usage(changeset) do
    validate_change(changeset, :used_memory_evidence, fn :used_memory_evidence, ledger ->
      if OpenAgents.Memory.Evidence.valid_usage_ledger?(ledger),
        do: [],
        else: [used_memory_evidence: "is invalid"]
    end)
  end

  defp validate_preference_usage(changeset) do
    validate_change(changeset, :used_preferences, fn :used_preferences, ledger ->
      applied = ledger["applied"]
      overridden = ledger["overridden"]

      valid_item? = fn item ->
        is_map(item) and
          Regex.match?(~r/\Apreference:v1:[0-9a-f-]{36}\z/, item["preference_ref"] || "") and
          Regex.match?(
            ~r/\Apreference-activation:v1:[0-9a-f-]{36}\z/,
            item["activation_receipt_ref"] || ""
          ) and Regex.match?(@digest_regex, item["effect_digest"] || "")
      end

      if ledger["schema"] == "sarah.preference_usage.v1" and is_list(applied) and
           is_list(overridden) and length(applied) <= 8 and length(overridden) <= 8 and
           Enum.all?(applied, valid_item?) and Enum.all?(overridden, valid_item?) and
           byte_size(Jason.encode!(ledger)) <= 8_192,
         do: [],
         else: [used_preferences: "is invalid"]
    end)
  end

  defp validate_experience_usage(changeset) do
    validate_change(changeset, :used_experiences, fn :used_experiences, usage ->
      records = usage["record_refs"]
      patterns = usage["pattern_refs"]
      digest = usage["bank_digest"]

      valid =
        usage["schema"] == "sarah.experience_usage.v1" and is_list(records) and
          is_list(patterns) and length(records) <= 6 and length(patterns) <= 3 and
          Enum.all?(records, &Regex.match?(~r/\Aexperience:[0-9a-f-]{36}\z/, &1)) and
          Enum.all?(patterns, &Regex.match?(~r/\Aexperience-pattern:[0-9a-f-]{36}\z/, &1)) and
          (is_nil(digest) or Regex.match?(@digest_regex, digest))

      if valid, do: [], else: [used_experiences: "is invalid"]
    end)
  end
end
