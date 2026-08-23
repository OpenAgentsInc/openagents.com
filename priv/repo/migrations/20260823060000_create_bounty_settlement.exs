defmodule OpenAgents.Repo.Migrations.CreateBountySettlement do
  use Ecto.Migration

  def change do
    create table(:settlement_treasury_policies, primary_key: false) do
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

    create unique_index(:settlement_treasury_policies, [:policy_id, :version])
    create unique_index(:settlement_treasury_policies, [:approval_receipt_ref])

    create table(:settlement_bounty_specs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :treasury_policy_id,
          references(:settlement_treasury_policies, type: :binary_id, on_delete: :restrict),
          null: false

      add :issue_id, references(:issues, on_delete: :restrict), null: false
      add :revision, :integer, null: false
      add :buyer_ref, :string, null: false
      add :amount_sats, :integer, null: false
      add :acceptance_criteria, {:array, :string}, null: false
      add :verification_policy, :map, null: false
      add :destination_kind, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :spec_fingerprint, :string, null: false
      add :actor_id, :string, null: false
      add :auth_method, :string, null: false
      add :approval_receipt_ref, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:settlement_bounty_specs, [:issue_id, :revision])
    create unique_index(:settlement_bounty_specs, [:spec_fingerprint])
    create unique_index(:settlement_bounty_specs, [:approval_receipt_ref])

    create table(:settlement_claims, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :bounty_spec_id,
          references(:settlement_bounty_specs, type: :binary_id, on_delete: :restrict),
          null: false

      add :spec_fingerprint, :string, null: false
      add :claimant_ref, :string, null: false
      add :work_job_ref, :string, null: false
      add :destination_kind, :string, null: false
      add :destination, :string, null: false
      add :destination_digest, :string, null: false
      add :state, :string, null: false
      add :claim_digest, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:settlement_claims, [:bounty_spec_id],
             where: "state NOT IN ('expired', 'rejected')",
             name: :settlement_claim_single_live_claim
           )

    create index(:settlement_claims, [:claimant_ref])

    create table(:settlement_verifications, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :claim_id, references(:settlement_claims, type: :binary_id, on_delete: :restrict),
        null: false

      add :spec_fingerprint, :string, null: false
      add :commit_sha, :string, null: false
      add :work_job_ref, :string, null: false
      add :verifier_ref, :string, null: false
      add :verifier_policy_digest, :string, null: false
      add :evidence_digest, :string, null: false
      add :outcome, :string, null: false
      add :reason_code, :string, null: false
      add :auth_method, :string, null: false
      add :decision_receipt_ref, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:settlement_verifications, [:claim_id, :commit_sha])
    create unique_index(:settlement_verifications, [:decision_receipt_ref])

    create table(:settlement_payment_intents, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :claim_id, references(:settlement_claims, type: :binary_id, on_delete: :restrict),
        null: false

      add :verification_id,
          references(:settlement_verifications, type: :binary_id, on_delete: :restrict),
          null: false

      add :idempotency_key, :string, null: false
      add :amount_sats, :integer, null: false
      add :commit_sha, :string, null: false
      add :destination_digest, :string, null: false
      add :spec_fingerprint, :string, null: false
      add :state, :string, null: false
      add :attempts, :integer, null: false, default: 0
      add :failure_reason_code, :string
      add :intent_digest, :string, null: false
      add :actor_id, :string, null: false
      add :auth_method, :string, null: false
      add :approval_receipt_ref, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:settlement_payment_intents, [:idempotency_key])

    create unique_index(:settlement_payment_intents, [:claim_id],
             where: "state = 'paid'",
             name: :settlement_payment_intent_single_paid
           )

    create table(:settlement_payment_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :payment_intent_id,
          references(:settlement_payment_intents, type: :binary_id, on_delete: :restrict),
          null: false

      add :claim_id, references(:settlement_claims, type: :binary_id, on_delete: :restrict),
        null: false

      add :amount_sats, :integer, null: false
      add :fee_sats, :integer, null: false
      add :payment_hash, :string, null: false
      add :preimage_digest, :string, null: false
      add :gateway_ref, :string, null: false
      add :paid_at, :utc_datetime_usec, null: false
      add :receipt_digest, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:settlement_payment_receipts, [:payment_intent_id])
    create unique_index(:settlement_payment_receipts, [:payment_hash])

    create table(:settlement_adjustments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :claim_id, references(:settlement_claims, type: :binary_id, on_delete: :restrict),
        null: false

      add :kind, :string, null: false
      add :reason_code, :string, null: false
      add :actor_id, :string, null: false
      add :auth_method, :string, null: false
      add :approval_receipt_ref, :string, null: false
      add :adjustment_digest, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:settlement_adjustments, [:claim_id, :kind, :approval_receipt_ref])
  end
end
