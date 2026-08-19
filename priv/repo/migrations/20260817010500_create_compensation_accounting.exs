defmodule Sarah.Repo.Migrations.CreateCompensationAccounting do
  use Ecto.Migration

  def up do
    create table(:compensation_policy_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :policy_id, :string, null: false
      add :version, :integer, null: false
      add :policy_digest, :string, null: false
      add :rules, :map, null: false
      add :actor_id, :string, null: false
      add :auth_method, :string, null: false
      add :approval_receipt_ref, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:compensation_policy_receipts, [:policy_id, :version])
    create unique_index(:compensation_policy_receipts, [:approval_receipt_ref])

    create table(:compensation_module_allocations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :policy_receipt_id,
          references(:compensation_policy_receipts, type: :binary_id, on_delete: :restrict),
          null: false

      add :module_id, :string, null: false
      add :module_version, :integer, null: false
      add :artifact_digest, :string, null: false
      add :contribution_ref, :string, null: false
      add :allocation_ppm, :integer, null: false
      add :lineage_digest, :string, null: false
      add :actor_id, :string, null: false
      add :approval_receipt_ref, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(
             :compensation_module_allocations,
             [:policy_receipt_id, :module_id, :module_version, :contribution_ref],
             name: :compensation_module_allocation_identity
           )

    create table(:compensation_outcome_decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tool_step_id, references(:turn_tool_steps, type: :binary_id, on_delete: :restrict),
        null: false

      add :invocation_key, :string, null: false
      add :outcome_receipt_ref, :string, null: false
      add :outcome_digest, :string, null: false
      add :decision, :string, null: false
      add :reason_code, :string, null: false
      add :actor_id, :string, null: false
      add :auth_method, :string, null: false
      add :decision_receipt_ref, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:compensation_outcome_decisions, [:tool_step_id])
    create unique_index(:compensation_outcome_decisions, [:outcome_receipt_ref])
    create unique_index(:compensation_outcome_decisions, [:decision_receipt_ref])

    create table(:compensation_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tool_step_id, references(:turn_tool_steps, type: :binary_id, on_delete: :restrict),
        null: false

      add :policy_receipt_id,
          references(:compensation_policy_receipts, type: :binary_id, on_delete: :restrict),
          null: false

      add :outcome_decision_id,
          references(:compensation_outcome_decisions, type: :binary_id, on_delete: :restrict),
          null: false

      add :module_id, :string, null: false
      add :module_version, :integer, null: false
      add :artifact_digest, :string, null: false
      add :invocation_key, :string, null: false
      add :outcome_receipt_ref, :string, null: false
      add :technical_units, :integer, null: false
      add :eligible_units, :integer, null: false
      add :classification, :string, null: false
      add :reason_code, :string, null: false
      add :event_digest, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:compensation_events, [:tool_step_id])
    create unique_index(:compensation_events, [:invocation_key])
    create unique_index(:compensation_events, [:outcome_receipt_ref])

    create table(:compensation_shares, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :event_id, references(:compensation_events, type: :binary_id, on_delete: :restrict),
        null: false

      add :contribution_ref, :string, null: false
      add :allocation_ppm, :integer, null: false
      add :allocated_units, :integer, null: false
      add :share_digest, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:compensation_shares, [:event_id, :contribution_ref])

    create table(:compensation_adjustments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :event_id, references(:compensation_events, type: :binary_id, on_delete: :restrict),
        null: false

      add :policy_receipt_id,
          references(:compensation_policy_receipts, type: :binary_id, on_delete: :restrict),
          null: false

      add :contribution_ref, :string, null: false
      add :kind, :string, null: false
      add :delta_units, :integer, null: false
      add :reason_code, :string, null: false
      add :actor_id, :string, null: false
      add :auth_method, :string, null: false
      add :adjustment_receipt_ref, :string, null: false
      add :adjustment_digest, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:compensation_adjustments, [:adjustment_receipt_ref])

    create table(:compensation_statements, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :policy_receipt_id,
          references(:compensation_policy_receipts, type: :binary_id, on_delete: :restrict),
          null: false

      add :contribution_ref, :string, null: false
      add :cutoff_at, :utc_datetime_usec, null: false
      add :gross_units, :bigint, null: false
      add :adjustment_units, :bigint, null: false
      add :net_units, :bigint, null: false
      add :event_count, :integer, null: false
      add :state, :string, null: false
      add :statement_digest, :string, null: false
      add :actor_id, :string, null: false
      add :statement_receipt_ref, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:compensation_statements, [:statement_receipt_ref])

    for table <-
          ~w(compensation_policy_receipts compensation_module_allocations compensation_outcome_decisions compensation_events compensation_shares compensation_adjustments compensation_statements)a do
      append_only(table)
    end

    execute(
      "ALTER TABLE compensation_policy_receipts ADD CONSTRAINT compensation_policy_no_payout CHECK ((rules->>'payout_authority')::boolean = false)"
    )

    execute(
      "ALTER TABLE compensation_policy_receipts ADD CONSTRAINT compensation_policy_digest_check CHECK (policy_digest ~ '^[0-9a-f]{64}$')"
    )

    execute(
      "ALTER TABLE compensation_module_allocations ADD CONSTRAINT compensation_allocation_bounds CHECK (allocation_ppm > 0 AND allocation_ppm <= 1000000)"
    )

    execute(
      "ALTER TABLE compensation_module_allocations ADD CONSTRAINT compensation_allocation_digest_check CHECK (artifact_digest ~ '^[0-9a-f]{64}$' AND lineage_digest ~ '^[0-9a-f]{64}$')"
    )

    execute(
      "ALTER TABLE compensation_outcome_decisions ADD CONSTRAINT compensation_outcome_decision_check CHECK (decision IN ('accepted','rejected') AND invocation_key ~ '^[0-9a-f]{64}$' AND outcome_digest ~ '^[0-9a-f]{64}$')"
    )

    execute(
      "ALTER TABLE compensation_events ADD CONSTRAINT compensation_event_shape CHECK ((classification = 'eligible' AND eligible_units = technical_units AND eligible_units > 0) OR (classification = 'ineligible' AND eligible_units = 0))"
    )

    execute(
      "ALTER TABLE compensation_events ADD CONSTRAINT compensation_event_digest_check CHECK (artifact_digest ~ '^[0-9a-f]{64}$' AND invocation_key ~ '^[0-9a-f]{64}$' AND event_digest ~ '^[0-9a-f]{64}$')"
    )

    execute(
      "ALTER TABLE compensation_shares ADD CONSTRAINT compensation_share_shape CHECK (allocation_ppm > 0 AND allocation_ppm <= 1000000 AND allocated_units >= 0 AND share_digest ~ '^[0-9a-f]{64}$')"
    )

    execute(
      "ALTER TABLE compensation_adjustments ADD CONSTRAINT compensation_adjustment_nonzero CHECK (delta_units <> 0)"
    )

    execute(
      "ALTER TABLE compensation_adjustments ADD CONSTRAINT compensation_adjustment_kind_check CHECK (kind IN ('refund','chargeback','fraud_hold','dispute_resolution','policy_migration') AND adjustment_digest ~ '^[0-9a-f]{64}$')"
    )

    execute(
      "ALTER TABLE compensation_statements ADD CONSTRAINT compensation_statement_shape CHECK (gross_units >= 0 AND net_units >= 0 AND net_units = gross_units + adjustment_units AND state IN ('reconciled','disputed') AND statement_digest ~ '^[0-9a-f]{64}$')"
    )
  end

  def down do
    for table <-
          ~w(compensation_policy_receipts compensation_module_allocations compensation_outcome_decisions compensation_events compensation_shares compensation_adjustments compensation_statements) do
      execute("DROP FUNCTION IF EXISTS reject_#{table}_mutation() CASCADE")
    end

    drop table(:compensation_statements)
    drop table(:compensation_adjustments)
    drop table(:compensation_shares)
    drop table(:compensation_events)
    drop table(:compensation_outcome_decisions)
    drop table(:compensation_module_allocations)
    drop table(:compensation_policy_receipts)
  end

  defp append_only(table) do
    function = "reject_#{table}_mutation"

    execute(
      "CREATE FUNCTION #{function}() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION '#{table} is append-only'; END; $$ LANGUAGE plpgsql;"
    )

    execute(
      "CREATE TRIGGER #{table}_append_only BEFORE UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION #{function}();"
    )
  end
end
