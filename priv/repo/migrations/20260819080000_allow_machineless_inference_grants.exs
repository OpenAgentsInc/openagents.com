defmodule Sarah.Repo.Migrations.AllowMachinelessInferenceGrants do
  @moduledoc """
  A coding job (#122) meters its own inference usage into the same grant
  ledger as probe delegations, but it has no paired machine — the executor
  is Sarah's own runtime. Make `machine_id` nullable for these internal
  grants, and tighten the immutability guard to be NULL-safe so a
  machineless grant cannot silently acquire (or change) a machine later.
  """

  use Ecto.Migration

  def up do
    execute("ALTER TABLE inference_grants ALTER COLUMN machine_id DROP NOT NULL")

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
         OR NEW.machine_id IS DISTINCT FROM OLD.machine_id
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
  end

  def down do
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

    execute("ALTER TABLE inference_grants ALTER COLUMN machine_id SET NOT NULL")
  end
end
