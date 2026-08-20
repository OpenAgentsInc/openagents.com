defmodule OpenAgents.Repo.Migrations.CreateSarahConversations do
  use Ecto.Migration

  def up do
    create table(:visitors, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :browser_key_hash, :binary
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:visitors, [:browser_key_hash])
    create unique_index(:visitors, [:user_id], where: "user_id IS NOT NULL")

    create table(:conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :visitor_id, references(:visitors, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:conversations, [:visitor_id])

    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :role, :string, null: false
      add :content, :text, null: false, default: ""
      add :status, :string, null: false, default: "complete"
      add :provider_response_id, :string
      add :modality, :string, null: false, default: "text"
      add :voice_session_id, :binary_id
      add :provider_item_id, :string
      add :transcript_kind, :string
      add :interrupted, :boolean, null: false, default: false
      add :work_job_id, :binary_id
      add :search_vector, :text
      timestamps(type: :utc_datetime_usec)
    end

    create index(:messages, [:conversation_id, :inserted_at, :id])

    create unique_index(:messages, [:voice_session_id, :provider_item_id, :role],
             where: "voice_session_id IS NOT NULL",
             name: :messages_voice_item_role_index
           )

    create table(:turns, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_message_id, references(:messages, type: :binary_id, on_delete: :delete_all),
        null: false

      add :assistant_message_id, references(:messages, type: :binary_id, on_delete: :delete_all),
        null: false

      add :status, :string, null: false, default: "queued"
      add :error_message, :text
      add :error_code, :string
      add :provider_response_id, :string
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:turns, [:conversation_id],
             where: "status IN ('queued', 'streaming')",
             name: :turns_one_active_per_conversation_index
           )

    create index(:turns, [:conversation_id, :inserted_at])

    create table(:turn_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :turn_id, references(:turns, type: :binary_id, on_delete: :delete_all), null: false
      add :schema_version, :integer, null: false, default: 1
      add :status, :string, null: false, default: "captured"
      add :model_id, :string, null: false
      add :persona_id, :string, null: false
      add :persona_digest, :string, null: false
      add :role_id, :string, null: false
      add :role_digest, :string, null: false
      add :role_selection, :map, null: false, default: %{}
      add :instruction_digest, :string, null: false
      add :input_digest, :string, null: false
      add :input_message_count, :integer, null: false
      add :input_bytes, :integer, null: false
      add :tool_catalog_digest, :string
      add :blueprint_revision, :string
      add :blueprint_digest, :string
      add :program_artifact_id, :string
      add :program_artifact_digest, :string
      add :program_artifact_receipt, :map
      add :memory_snapshot_ref, :string
      add :profile_memory_snapshot_ref, :string
      add :preference_snapshot_ref, :string
      add :used_preferences, :map, null: false, default: %{}
      add :experience_bank_ref, :string
      add :used_experiences, :map, null: false, default: %{}
      add :used_source_refs, {:array, :string}, null: false, default: []
      add :used_tool_step_refs, {:array, :string}, null: false, default: []
      add :used_memory_evidence, :map, null: false, default: %{}
      add :usage, :map
      add :provider_started_at, :utc_datetime_usec, null: false
      add :provider_completed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:turn_receipts, [:turn_id])

    create table(:turn_provider_steps, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :turn_receipt_id, references(:turn_receipts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :sequence, :integer, null: false
      add :provider_id, :string, null: false
      add :model_id, :string, null: false
      add :status, :string, null: false, default: "started"
      add :provider_response_id, :string
      add :usage, :map
      add :error_code, :string
      add :started_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:turn_provider_steps, [:turn_receipt_id, :sequence])

    create table(:turn_tool_steps, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :turn_id, references(:turns, type: :binary_id, on_delete: :delete_all), null: false

      add :turn_receipt_id, references(:turn_receipts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :sequence, :integer, null: false
      add :provider_call_id, :string, null: false
      add :provider_item_id, :string, null: false
      add :provider_response_id, :string, null: false
      add :tool_name, :string, null: false
      add :tool_version, :integer, null: false
      add :module_id, :string, null: false
      add :module_artifact_digest, :string
      add :executor_implementation_digest, :string
      add :routing_receipt_id, :binary_id
      add :side_effect_class, :string, null: false, default: "read_only"
      add :invocation_key, :string
      add :attribution_policy_id, :string
      add :attribution_policy_version, :integer
      add :attribution_policy_digest, :string
      add :billable, :boolean, null: false, default: false
      add :billable_attribution_key, :string
      add :cost_units, :integer, null: false, default: 0
      add :catalog_digest, :string, null: false
      add :raw_arguments, :text, null: false
      add :argument_digest, :string, null: false
      add :status, :string, null: false, default: "requested"
      add :outcome_digest, :string
      add :outcome_receipt_ref, :string
      add :usage, :map
      add :result, :map
      add :error, :map
      add :executor_id, :string
      add :executor_disclosure, :string
      add :target_receipt_refs, {:array, :string}, null: false, default: []
      add :attribution_refs, {:array, :string}, null: false, default: []
      add :requested_at, :utc_datetime_usec, null: false
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:turn_tool_steps, [:turn_id, :sequence])
    create unique_index(:turn_tool_steps, [:turn_id, :provider_call_id])
    create unique_index(:turn_tool_steps, [:invocation_key], where: "invocation_key IS NOT NULL")

    create unique_index(:turn_tool_steps, [:billable_attribution_key],
             where: "billable_attribution_key IS NOT NULL"
           )
  end

  def down do
    drop table(:turn_tool_steps)
    drop table(:turn_provider_steps)
    drop table(:turn_receipts)
    drop table(:turns)
    drop table(:messages)
    drop table(:conversations)
    drop table(:visitors)
  end
end
