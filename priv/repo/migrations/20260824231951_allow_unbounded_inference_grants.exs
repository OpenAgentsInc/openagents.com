defmodule OpenAgents.Repo.Migrations.AllowUnboundedInferenceGrants do
  use Ecto.Migration

  @moduledoc """
  Let a grant have no ceiling.

  A thread was minted for 256 calls, a million tokens, and two dollars. A
  coding session reaches all three in an afternoon, and the reply it gets is
  that the thread spent its budget and a new session is needed — the same
  interruption the clock used to cause, arriving by a different route.

  Each of the three ceilings becomes nullable, and nil means unbounded. A grant
  that sets one is still held to it, which is what a computer-bound delegation
  needs: its budget is a security bound, not a convenience.

  The database still refuses a ceiling that is present and meaningless. The
  positivity checks become `IS NULL OR > 0` rather than being dropped, so a
  zero or negative ceiling — a grant that could never buy a single call — is
  as impossible as it was before.
  """

  def up do
    alter table(:inference_grants) do
      modify :max_total_tokens, :integer, null: true
      modify :max_calls, :integer, null: true
      modify :max_cost_microusd, :integer, null: true
    end

    execute("""
    ALTER TABLE inference_grants
      ADD CONSTRAINT inference_grant_positive_ceilings CHECK (
        (max_total_tokens IS NULL OR max_total_tokens > 0)
        AND (max_calls IS NULL OR max_calls > 0)
        AND (max_cost_microusd IS NULL OR max_cost_microusd > 0)
      )
    """)

    execute(guard("IS DISTINCT FROM"))
  end

  def down do
    execute("ALTER TABLE inference_grants DROP CONSTRAINT inference_grant_positive_ceilings")

    execute("""
    UPDATE inference_grants
       SET max_total_tokens = COALESCE(max_total_tokens, 1000000),
           max_calls = COALESCE(max_calls, 256),
           max_cost_microusd = COALESCE(max_cost_microusd, 2000000)
     WHERE max_total_tokens IS NULL
        OR max_calls IS NULL
        OR max_cost_microusd IS NULL
    """)

    alter table(:inference_grants) do
      modify :max_total_tokens, :integer, null: false
      modify :max_calls, :integer, null: false
      modify :max_cost_microusd, :integer, null: false
    end

    execute(guard("<>"))
  end

  # The update guard reads these three columns, and `<>` is NULL when either
  # side is NULL — a NULL predicate is not true, so an unbounded grant's
  # ceilings would have become quietly mutable. `IS DISTINCT FROM` is the
  # null-safe comparison, the same fix `expires_at` needed when it became
  # nullable.
  defp guard(ceiling_comparison) do
    """
    CREATE OR REPLACE FUNCTION sarah_guard_inference_grant_update()
    RETURNS trigger AS $$
    BEGIN
      IF OLD.status <> 'active' THEN
        RAISE EXCEPTION 'inference_grants row % is terminal (%), no update permitted', OLD.id, OLD.status;
      END IF;

      IF NEW.id <> OLD.id
         OR NEW.owner_visitor_id <> OLD.owner_visitor_id
         OR NEW.conversation_id IS DISTINCT FROM OLD.conversation_id
         OR NEW.thread_id IS DISTINCT FROM OLD.thread_id
         OR NEW.machine_id IS DISTINCT FROM OLD.machine_id
         OR NEW.model_id <> OLD.model_id
         OR NEW.token_digest <> OLD.token_digest
         OR NEW.max_total_tokens #{ceiling_comparison} OLD.max_total_tokens
         OR NEW.max_calls #{ceiling_comparison} OLD.max_calls
         OR NEW.max_cost_microusd #{ceiling_comparison} OLD.max_cost_microusd
         OR NEW.expires_at IS DISTINCT FROM OLD.expires_at THEN
        RAISE EXCEPTION 'inference_grants row % has immutable identity/budget fields', OLD.id;
      END IF;

      IF NEW.call_count < OLD.call_count THEN
        RAISE EXCEPTION 'inference_grants row % call_count cannot decrease', OLD.id;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """
  end
end
