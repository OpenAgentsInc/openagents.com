defmodule Sarah.Repo.Migrations.CreateShadowProgramRuns do
  use Ecto.Migration

  def up do
    create table(:shadow_program_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :turn_receipt_id,
          references(:turn_receipts, type: :binary_id, on_delete: :delete_all),
          null: false

      add :signature_id, :string, null: false
      add :signature_version, :integer, null: false
      add :artifact_id, :string
      add :artifact_digest, :string
      add :input_digest, :string, null: false
      add :baseline_output, :map, null: false
      add :candidate_output, :map, null: false
      add :candidate_output_digest, :string, null: false
      add :status, :string, null: false
      add :comparison, :map, null: false
      add :provider_id, :string, null: false
      add :provider_response_id, :string
      add :usage, :map, null: false, default: %{}
      add :latency_ms, :bigint, null: false
      add :failure_code, :string
      add :completed_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:shadow_program_runs, [:turn_receipt_id, :signature_id, :inserted_at])

    create constraint(:shadow_program_runs, :shadow_program_runs_status_check,
             check: "status IN ('completed', 'degraded', 'malformed', 'failed', 'timed_out')"
           )

    create constraint(:shadow_program_runs, :shadow_program_runs_artifact_pair_check,
             check:
               "(artifact_id IS NULL) = (artifact_digest IS NULL) AND " <>
                 "(artifact_digest IS NULL OR artifact_digest ~ '^[0-9a-f]{64}$')"
           )

    create constraint(:shadow_program_runs, :shadow_program_runs_digest_check,
             check:
               "input_digest ~ '^[0-9a-f]{64}$' AND candidate_output_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:shadow_program_runs, :shadow_program_runs_bounds_check,
             check:
               "signature_version > 0 AND latency_ms >= 0 AND " <>
                 "octet_length(baseline_output::text) <= 16384 AND " <>
                 "octet_length(candidate_output::text) <= 16384 AND " <>
                 "octet_length(comparison::text) <= 4096 AND " <>
                 "octet_length(usage::text) <= 4096"
           )

    execute("""
    CREATE FUNCTION reject_shadow_program_run_mutation()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'terminal shadow-program receipts are immutable';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER protect_shadow_program_runs
    BEFORE UPDATE OR DELETE ON shadow_program_runs
    FOR EACH ROW EXECUTE FUNCTION reject_shadow_program_run_mutation();
    """)
  end

  def down do
    drop table(:shadow_program_runs)
    execute("DROP FUNCTION reject_shadow_program_run_mutation()")
  end
end
