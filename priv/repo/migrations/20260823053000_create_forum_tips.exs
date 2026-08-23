defmodule OpenAgents.Repo.Migrations.CreateForumTips do
  use Ecto.Migration

  def up do
    create table(:forum_tip_destinations, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      # The destination belongs to the account. The forum stores where to send
      # sats and never a key, seed, channel, or node credential, so it cannot
      # spend or hold what it routes.
      add :kind, :string, null: false
      add :destination, :text, null: false
      add :fingerprint, :string, null: false
      add :label, :string

      add :state, :string, null: false, default: "active"
      add :accepting_tips, :boolean, null: false, default: true
      add :retired_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:forum_tip_destinations, [:user_id],
             where: "state = 'active'",
             name: :forum_tip_destinations_one_active_per_user_index
           )

    create constraint(:forum_tip_destinations, :forum_tip_destinations_kind_check,
             check: "kind IN ('bolt12', 'lnurl', 'onchain')"
           )

    create constraint(:forum_tip_destinations, :forum_tip_destinations_state_check,
             check: "state IN ('active', 'retired')"
           )

    create table(:forum_tip_intents, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :post_id, references(:forum_posts, type: :uuid, on_delete: :restrict), null: false
      add :topic_id, references(:forum_topics, type: :uuid, on_delete: :restrict), null: false

      add :payer_user_id, references(:users, type: :binary_id, on_delete: :restrict), null: false
      add :payer_actor_ref, :string, null: false

      add :recipient_user_id, references(:users, type: :binary_id, on_delete: :restrict),
        null: false

      add :destination_id,
          references(:forum_tip_destinations, type: :uuid, on_delete: :restrict),
          null: false

      add :idempotency_key, :string, null: false
      add :amount_sats, :bigint, null: false

      # What ranking is allowed to see. The policy sets it once at settlement
      # and refunds return it to zero, so a payment and its ranking weight
      # stay separate facts.
      add :counted_sats, :bigint, null: false, default: 0
      add :exclusion_reason, :string

      add :state, :string, null: false, default: "created"
      add :failure_code, :string
      add :settled_at, :utc_datetime_usec
      add :failed_at, :utc_datetime_usec
      add :refunded_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:forum_tip_intents, [:idempotency_key])
    create index(:forum_tip_intents, [:post_id, :state])
    create index(:forum_tip_intents, [:payer_user_id, :state, :settled_at])
    create index(:forum_tip_intents, [:recipient_user_id, :state])

    create constraint(:forum_tip_intents, :forum_tip_intents_amount_check,
             check: "amount_sats > 0 AND amount_sats <= 1000000"
           )

    create constraint(:forum_tip_intents, :forum_tip_intents_counted_check,
             check: "counted_sats >= 0 AND counted_sats <= amount_sats"
           )

    create constraint(:forum_tip_intents, :forum_tip_intents_state_check,
             check: "state IN ('created', 'settled', 'failed', 'refunded')"
           )

    create table(:forum_tip_receipts, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :intent_id, references(:forum_tip_intents, type: :uuid, on_delete: :restrict),
        null: false

      add :kind, :string, null: false
      add :amount_sats, :bigint, null: false
      add :fee_sats, :bigint, null: false, default: 0

      # The payment hash proves the payment in the recipient's own wallet. It
      # is not a credential, and it reaches only the two accounts on the tip.
      add :payment_hash, :string
      add :failure_code, :string
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:forum_tip_receipts, [:intent_id, :kind])
    create index(:forum_tip_receipts, [:occurred_at])

    create constraint(:forum_tip_receipts, :forum_tip_receipts_kind_check,
             check: "kind IN ('settled', 'failed', 'refunded')"
           )

    execute("""
    CREATE FUNCTION reject_forum_tip_receipt_mutation()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'forum tip receipts are append-only';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER forum_tip_receipts_append_only
    BEFORE UPDATE OR DELETE ON forum_tip_receipts
    FOR EACH ROW EXECUTE FUNCTION reject_forum_tip_receipt_mutation();
    """)

    alter table(:forum_posts) do
      add :tip_sats_total, :bigint, null: false, default: 0
      add :tip_sats_counted, :bigint, null: false, default: 0
      add :tip_count, :bigint, null: false, default: 0
    end

    alter table(:forum_topics) do
      add :tip_sats_total, :bigint, null: false, default: 0
      add :tip_sats_counted, :bigint, null: false, default: 0
      add :tip_count, :bigint, null: false, default: 0
    end
  end

  def down do
    alter table(:forum_topics) do
      remove :tip_sats_total
      remove :tip_sats_counted
      remove :tip_count
    end

    alter table(:forum_posts) do
      remove :tip_sats_total
      remove :tip_sats_counted
      remove :tip_count
    end

    execute("DROP TRIGGER IF EXISTS forum_tip_receipts_append_only ON forum_tip_receipts")
    execute("DROP FUNCTION IF EXISTS reject_forum_tip_receipt_mutation()")

    drop table(:forum_tip_receipts)
    drop table(:forum_tip_intents)
    drop table(:forum_tip_destinations)
  end
end
