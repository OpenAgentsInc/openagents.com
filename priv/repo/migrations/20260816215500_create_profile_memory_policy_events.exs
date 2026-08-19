defmodule Sarah.Repo.Migrations.CreateProfileMemoryPolicyEvents do
  use Ecto.Migration

  def up do
    alter table(:profile_memory_records) do
      add :policy_version, :string, null: false, default: "sarah.memory.policy.v1"
    end

    create constraint(:profile_memory_records, :profile_memory_records_policy_version_check,
             check: "octet_length(policy_version) BETWEEN 1 AND 100"
           )

    execute("""
    CREATE FUNCTION protect_profile_memory_policy_version()
    RETURNS trigger AS $$
    BEGIN
      IF NEW.policy_version IS DISTINCT FROM OLD.policy_version OR
         NEW.redaction_policy IS DISTINCT FROM OLD.redaction_policy THEN
        RAISE EXCEPTION 'profile memory policy identities are immutable';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER profile_memory_policy_version_trigger
    BEFORE UPDATE ON profile_memory_records
    FOR EACH ROW EXECUTE FUNCTION protect_profile_memory_policy_version();
    """)

    create table(:profile_memory_policy_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :owner_visitor_id,
          references(:visitors, type: :binary_id, on_delete: :delete_all),
          null: false

      add :policy_version, :string, null: false
      add :outcome, :string, null: false
      add :reason_code, :string, null: false
      add :category, :string, null: false
      add :input_size_bucket, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create constraint(:profile_memory_policy_events, :profile_memory_policy_events_version_check,
             check: "policy_version = 'sarah.memory.policy.v1'"
           )

    create constraint(:profile_memory_policy_events, :profile_memory_policy_events_outcome_check,
             check: "outcome = 'rejected'"
           )

    create constraint(:profile_memory_policy_events, :profile_memory_policy_events_reason_check,
             check:
               "reason_code IN ('credential_material', 'api_token', 'wallet_seed_material', " <>
                 "'payment_material', 'authentication_secret', 'local_path', 'encoded_secret_material')"
           )

    create constraint(:profile_memory_policy_events, :profile_memory_policy_events_category_check,
             check: "category IN ('name', 'role', 'project', 'preference', 'constraint', 'other')"
           )

    create constraint(:profile_memory_policy_events, :profile_memory_policy_events_size_check,
             check: "input_size_bucket IN ('1-64', '65-128', '129-256', '257-500', 'over-500')"
           )

    create index(:profile_memory_policy_events, [:owner_visitor_id, :inserted_at, :id],
             name: :profile_memory_policy_events_owner_index
           )
  end

  def down do
    drop table(:profile_memory_policy_events)
    execute("DROP TRIGGER profile_memory_policy_version_trigger ON profile_memory_records")
    execute("DROP FUNCTION protect_profile_memory_policy_version()")
    drop constraint(:profile_memory_records, :profile_memory_records_policy_version_check)

    alter table(:profile_memory_records) do
      remove :policy_version
    end
  end
end
