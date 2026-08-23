defmodule OpenAgents.Repo.Migrations.CreateVerifiedArtifactListings do
  use Ecto.Migration

  def change do
    create table(:verified_artifact_listings, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :artifact_type, :text, null: false
      add :state, :text, null: false, default: "active"
      add :owner_ref, :text, null: false
      add :owner_description, :text, null: false
      add :source_ref, :text, null: false
      add :artifact_digest, :text, null: false
      add :provenance_digest, :text, null: false
      add :provenance, :map, null: false, default: fragment("'{}'::jsonb")
      add :schema, :map, null: false, default: fragment("'{}'::jsonb")
      add :size_bytes, :bigint, null: false
      add :record_count, :bigint
      add :coverage, :map, null: false, default: fragment("'{}'::jsonb")
      add :redaction, :map, null: false, default: fragment("'{}'::jsonb")
      add :license_contract_ref, :text, null: false
      add :license_terms, :map, null: false, default: fragment("'{}'::jsonb")
      add :license_digest, :text, null: false
      add :license_effective_at, :utc_datetime_usec, null: false
      add :license_expires_at, :utc_datetime_usec, null: false
      add :price, :map, null: false, default: fragment("'{}'::jsonb")
      add :buyer_name, :text, null: false
      add :buyer_class, :text, null: false
      add :verification_policy, :map, null: false, default: fragment("'{}'::jsonb")
      add :evidence_fresh_at, :utc_datetime_usec, null: false
      add :listing_digest, :text, null: false
      add :publication_receipt_ref, :text, null: false
      add :removed_at, :utc_datetime_usec
      add :removal_reason, :text

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:verified_artifact_listings, :verified_artifact_listings_type,
             check: "artifact_type IN ('trace', 'dataset')"
           )

    create constraint(:verified_artifact_listings, :verified_artifact_listings_state,
             check: "state IN ('active', 'removed')"
           )

    create constraint(:verified_artifact_listings, :verified_artifact_listings_size,
             check: "size_bytes > 0 AND (record_count IS NULL OR record_count > 0)"
           )

    create constraint(:verified_artifact_listings, :verified_artifact_listings_artifact_digest,
             check: "artifact_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:verified_artifact_listings, :verified_artifact_listings_provenance_digest,
             check: "provenance_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:verified_artifact_listings, :verified_artifact_listings_license_digest,
             check: "license_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:verified_artifact_listings, :verified_artifact_listings_listing_digest,
             check: "listing_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:verified_artifact_listings, :verified_artifact_listings_license_window,
             check: "license_expires_at > license_effective_at"
           )

    create unique_index(
             :verified_artifact_listings,
             [:artifact_digest, :provenance_digest, :license_digest],
             name: :verified_artifact_listings_identity_index
           )

    create unique_index(:verified_artifact_listings, [:listing_digest])
    create unique_index(:verified_artifact_listings, [:publication_receipt_ref])
    create index(:verified_artifact_listings, [:state, :license_expires_at])
    create index(:verified_artifact_listings, [:artifact_type, :buyer_class])

    create table(:verified_artifact_receipts, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :listing_id,
          references(:verified_artifact_listings, type: :uuid, on_delete: :restrict),
          null: false

      add :action, :text, null: false
      add :status, :text, null: false
      add :receipt_ref, :text, null: false
      add :predecessor_ref, :text
      add :external_ref, :text
      add :buyer_ref, :text, null: false
      add :buyer_class, :text, null: false
      add :artifact_digest, :text, null: false
      add :provenance_digest, :text, null: false
      add :license_digest, :text, null: false
      add :listing_digest, :text, null: false
      add :metadata, :map, null: false, default: fragment("'{}'::jsonb")

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:verified_artifact_receipts, :verified_artifact_receipts_action,
             check:
               "action IN ('publication', 'offer', 'acceptance', 'delivery', 'verification', 'settlement', 'removal')"
           )

    create constraint(:verified_artifact_receipts, :verified_artifact_receipts_status,
             check: "status IN ('recorded', 'admitted', 'verified', 'settled', 'removed')"
           )

    create constraint(:verified_artifact_receipts, :verified_artifact_receipts_artifact_digest,
             check: "artifact_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:verified_artifact_receipts, :verified_artifact_receipts_provenance_digest,
             check: "provenance_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:verified_artifact_receipts, :verified_artifact_receipts_license_digest,
             check: "license_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:verified_artifact_receipts, :verified_artifact_receipts_listing_digest,
             check: "listing_digest ~ '^[0-9a-f]{64}$'"
           )

    create unique_index(:verified_artifact_receipts, [:receipt_ref])
    create index(:verified_artifact_receipts, [:listing_id, :inserted_at])
    create index(:verified_artifact_receipts, [:listing_id, :action])
  end
end
