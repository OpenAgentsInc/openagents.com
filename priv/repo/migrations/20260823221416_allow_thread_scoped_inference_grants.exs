defmodule OpenAgents.Repo.Migrations.AllowThreadScopedInferenceGrants do
  @moduledoc """
  A grant is the only way a client reaches a model without holding a provider
  key, and `conversation_id` was `NOT NULL`. So no execution outside the
  account's single conversation could buy a token, and a coding session had to
  submit through the chat lane to reach a model at all. The conversation was
  never the binding constraint; the grant was.

  This is the same move
  `priv/repo/migrations/20260819080000_allow_machineless_inference_grants.exs`
  made for `machine_id` when a coding job needed a machine-less grant: drop one
  `NOT NULL` and make the immutability guard NULL-safe, so a grant cannot
  silently acquire the column it was minted without.

  What is added here beyond that shape is the fence itself. A grant names a
  thread or a conversation, never both and never neither, and at most one
  active grant may name a thread — so a thread's authority is singular and its
  spend is attributable.
  """

  use Ecto.Migration

  def up do
    execute("ALTER TABLE inference_grants ALTER COLUMN conversation_id DROP NOT NULL")

    alter table(:inference_grants) do
      add :thread_id, references(:threads, type: :binary_id, on_delete: :delete_all)
    end

    create index(:inference_grants, [:thread_id])

    create unique_index(:inference_grants, [:thread_id],
             where: "status = 'active' AND thread_id IS NOT NULL",
             name: :inference_grants_one_active_thread_index
           )

    create constraint(:inference_grants, :inference_grant_exactly_one_fence,
             check: "(conversation_id IS NULL) <> (thread_id IS NULL)"
           )

    execute("""
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

    drop constraint(:inference_grants, :inference_grant_exactly_one_fence)
    drop index(:inference_grants, [:thread_id], name: :inference_grants_one_active_thread_index)
    drop index(:inference_grants, [:thread_id])

    execute("DELETE FROM inference_grants WHERE conversation_id IS NULL")

    alter table(:inference_grants) do
      remove :thread_id
    end

    execute("ALTER TABLE inference_grants ALTER COLUMN conversation_id SET NOT NULL")
  end
end
