defmodule OpenAgents.Repo.Migrations.CreateReputationAttestations do
  use Ecto.Migration

  def change do
    create table(:reputation_verifier_policies, primary_key: false) do
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

    create unique_index(:reputation_verifier_policies, [:policy_id, :version])
    create unique_index(:reputation_verifier_policies, [:approval_receipt_ref])

    # Only public keys live here. A private key stays runtime-only (RELEASE-002),
    # so the table a skeptical client reads carries verification material and
    # nothing that can mint an attestation.
    create table(:reputation_signing_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :key_id, :string, null: false
      add :algorithm, :string, null: false
      add :public_key, :string, null: false
      add :issuer, :string, null: false
      add :activated_at, :utc_datetime_usec, null: false
      add :retired_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:reputation_signing_keys, [:key_id])
    create unique_index(:reputation_signing_keys, [:public_key])

    create table(:reputation_attestations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repository_id, references(:repositories, type: :binary_id, on_delete: :restrict),
        null: false

      add :issue_number, :integer, null: false
      add :event_type, :string, null: false
      add :subject_id, :string, null: false
      add :issuer_key_id, :string, null: false
      add :outcome_kind, :string, null: false
      add :outcome_ref, :string, null: false
      add :outcome_digest, :string, null: false
      add :revision, :string, null: false
      add :artifact_digest, :string, null: false
      add :policy_id, :string, null: false
      add :policy_version, :integer, null: false
      add :policy_digest, :string, null: false
      add :confidence_ppm, :integer, null: false
      add :transparency_tier, :string, null: false
      add :attested_at, :utc_datetime_usec, null: false
      add :nonce, :string, null: false
      add :claim, :map, null: false
      add :claim_digest, :string, null: false
      add :signature, :text, null: false
      add :signature_algorithm, :string, null: false
      add :supersedes_digest, :string

      add :revokes_id,
          references(:reputation_attestations, type: :binary_id, on_delete: :restrict)

      add :revoked_at, :utc_datetime_usec
      add :revocation_reason_code, :string
      add :revoked_by_id, :binary_id
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # The claim digest is the attestation's identity. A replayed claim collides
    # here instead of becoming a second attestation.
    create unique_index(:reputation_attestations, [:claim_digest])

    # One outcome-bound event per issuer, subject, and outcome. A second
    # completion claim for the same accepted outcome is a duplicate, not
    # additional reputation. Invalidating events are excluded: each one is
    # already unique through `revokes_id`.
    create unique_index(
             :reputation_attestations,
             [:issuer_key_id, :subject_id, :outcome_kind, :outcome_ref, :event_type],
             name: :reputation_attestations_outcome_event_index,
             where: "event_type not in ('reversal','revocation')"
           )

    create index(:reputation_attestations, [:repository_id, :issue_number])
    create index(:reputation_attestations, [:subject_id])
    create unique_index(:reputation_attestations, [:revokes_id])

    create constraint(:reputation_attestations, :reputation_attestations_confidence_range,
             check: "confidence_ppm >= 0 and confidence_ppm <= 1000000"
           )

    create constraint(:reputation_attestations, :reputation_attestations_event_type,
             check:
               "event_type in ('completion','verification','review','payment','reversal','revocation')"
           )

    create constraint(:reputation_attestations, :reputation_attestations_transparency_tier,
             check: "transparency_tier in ('public','repository','private')"
           )

    # Append-only. Revocation is the one field a later event may set, and it
    # may only be set once, from null.
    execute(
      """
      CREATE OR REPLACE FUNCTION reputation_attestations_append_only()
      RETURNS trigger AS $$
      BEGIN
        IF row_to_json(NEW)::text <> row_to_json(OLD)::text THEN
          IF (OLD.revoked_at IS NOT NULL) OR
             (NEW.id <> OLD.id) OR
             (NEW.claim_digest <> OLD.claim_digest) OR
             (NEW.claim::text <> OLD.claim::text) OR
             (NEW.signature <> OLD.signature) THEN
            RAISE EXCEPTION 'reputation attestations are append-only';
          END IF;
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION IF EXISTS reputation_attestations_append_only();"
    )

    execute(
      """
      CREATE TRIGGER reputation_attestations_append_only
      BEFORE UPDATE ON reputation_attestations
      FOR EACH ROW EXECUTE FUNCTION reputation_attestations_append_only();
      """,
      "DROP TRIGGER IF EXISTS reputation_attestations_append_only ON reputation_attestations;"
    )
  end
end
