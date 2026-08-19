defmodule Sarah.Repo.Migrations.CreateInferenceGrants do
  use Ecto.Migration

  @moduledoc """
  Delegation-scoped inference grants (`sarah.inference_grant.v1`). A grant is
  authority for one paired-machine delegation to call the Sarah inference
  proxy — never a provider credential. It is budgeted, generation-fenced by
  its conversation, revocable, and metered. Terminal grants are immutable and
  usage/counters only move forward; PostgreSQL enforces both.
  """

  def up do
    create table(:inference_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :owner_visitor_id,
          references(:visitors, type: :binary_id, on_delete: :delete_all),
          null: false

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :machine_id,
          references(:machines, type: :binary_id, on_delete: :delete_all),
          null: false

      add :model_id, :string, null: false
      add :token_digest, :binary, null: false
      add :status, :string, null: false, default: "active"

      add :max_total_tokens, :bigint, null: false
      add :max_calls, :integer, null: false
      add :max_cost_microusd, :bigint, null: false

      add :call_count, :integer, null: false, default: 0
      add :usage, :map, null: false, default: %{}

      add :expires_at, :utc_datetime_usec, null: false
      add :exhausted_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:inference_grants, [:token_digest])
    create index(:inference_grants, [:conversation_id])
    create index(:inference_grants, [:machine_id])

    create constraint(:inference_grants, :inference_grant_status,
             check: "status IN ('active','exhausted','revoked','expired')"
           )

    create constraint(:inference_grants, :inference_grant_counts_nonnegative,
             check: "call_count >= 0"
           )

    # Terminal grants are frozen; from active, only status/counters/usage and
    # the terminal timestamps may move, and call_count never decreases.
    execute("""
    CREATE OR REPLACE FUNCTION sarah_guard_inference_grant_update()
    RETURNS trigger AS $$
    BEGIN
      IF OLD.status <> 'active' THEN
        RAISE EXCEPTION 'inference_grants row % is terminal (%), no update permitted', OLD.id, OLD.status;
      END IF;

      IF NEW.id <> OLD.id
         OR NEW.owner_visitor_id <> OLD.owner_visitor_id
         OR NEW.conversation_id <> OLD.conversation_id
         OR NEW.machine_id <> OLD.machine_id
         OR NEW.model_id <> OLD.model_id
         OR NEW.token_digest <> OLD.token_digest
         OR NEW.max_total_tokens <> OLD.max_total_tokens
         OR NEW.max_calls <> OLD.max_calls
         OR NEW.max_cost_microusd <> OLD.max_cost_microusd
         OR NEW.expires_at <> OLD.expires_at THEN
        RAISE EXCEPTION 'inference_grants row % has immutable identity/budget fields', OLD.id;
      END IF;

      IF NEW.call_count < OLD.call_count THEN
        RAISE EXCEPTION 'inference_grants row % call_count cannot decrease', OLD.id;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER sarah_guard_inference_grant_update
    BEFORE UPDATE ON inference_grants
    FOR EACH ROW EXECUTE FUNCTION sarah_guard_inference_grant_update();
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS sarah_guard_inference_grant_update ON inference_grants;")
    execute("DROP FUNCTION IF EXISTS sarah_guard_inference_grant_update();")
    drop table(:inference_grants)
  end
end
