defmodule OpenAgents.Repo.Migrations.AllowUnexpiringInferenceGrants do
  use Ecto.Migration

  @moduledoc """
  Let a grant have no clock.

  A thread's authority expiring on a wall clock ended a coding session
  mid-sentence and told the reader to start a new one. The work was not
  finished, nothing had gone wrong, and the only thing that had happened was
  that an hour had passed. Budget still bounds a grant — calls, tokens, and
  cost — and revocation still ends one immediately. Time no longer does.

  `expires_at` becomes nullable and nil means "no clock". Grants that still
  carry one — a computer-bound delegation, whose deadline is a security bound
  rather than a convenience — are unaffected.

  The update guard has to change with it. `NEW.expires_at <> OLD.expires_at`
  is NULL when either side is NULL, and a NULL predicate is not true, so the
  column would have become quietly mutable for exactly the rows that now use
  it. `IS DISTINCT FROM` is the null-safe comparison the other nullable
  columns in this guard already use.
  """

  def up do
    alter table(:inference_grants) do
      modify :expires_at, :utc_datetime_usec, null: true
    end

    execute(guard("IS DISTINCT FROM"))
  end

  def down do
    execute("UPDATE inference_grants SET expires_at = now() WHERE expires_at IS NULL")

    alter table(:inference_grants) do
      modify :expires_at, :utc_datetime_usec, null: false
    end

    execute(guard("<>"))
  end

  defp guard(expires_at_comparison) do
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
         OR NEW.max_total_tokens <> OLD.max_total_tokens
         OR NEW.max_calls <> OLD.max_calls
         OR NEW.max_cost_microusd <> OLD.max_cost_microusd
         OR NEW.expires_at #{expires_at_comparison} OLD.expires_at THEN
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
