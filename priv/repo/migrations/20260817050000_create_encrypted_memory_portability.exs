defmodule Sarah.Repo.Migrations.CreateEncryptedMemoryPortability do
  use Ecto.Migration

  def up do
    create table(:portable_export_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :owner_visitor_id, references(:visitors, type: :binary_id, on_delete: :delete_all),
        null: false

      add :source_installation_ref, :string, null: false
      add :sequence, :bigint, null: false
      add :envelope_digest, :string, null: false
      add :profile_record_count, :integer, null: false
      add :kdf_id, :string, null: false
      add :cipher_id, :string, null: false
      add :status, :string, null: false
      add :previous_export_id, :binary_id
      add :rotated_at, :utc_datetime_usec
      add :tombstoned_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:portable_export_receipts, [:owner_visitor_id, :sequence])
    create unique_index(:portable_export_receipts, [:envelope_digest])

    create table(:portable_import_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :owner_visitor_id, references(:visitors, type: :binary_id, on_delete: :delete_all),
        null: false

      add :source_installation_ref, :string, null: false
      add :export_sequence, :bigint, null: false
      add :envelope_digest, :string, null: false
      add :confirmation_digest, :string, null: false
      add :status, :string, null: false
      add :imported_count, :integer, null: false
      add :unchanged_count, :integer, null: false
      add :conflict_count, :integer, null: false
      add :tombstone_count, :integer, null: false
      add :revoked_at, :utc_datetime_usec
      add :revocation_digest, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:portable_import_receipts, [:owner_visitor_id, :envelope_digest])

    create unique_index(
             :portable_import_receipts,
             [:owner_visitor_id, :source_installation_ref, :export_sequence],
             name: :portable_import_sequence_identity
           )

    create table(:portable_import_items, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :import_receipt_id,
          references(:portable_import_receipts, type: :binary_id, on_delete: :delete_all),
          null: false

      add :origin_record_ref, :string, null: false

      # Opaque historical reference: purging destination memory must not rewrite
      # an immutable import receipt item.
      add :destination_record_id, :binary_id

      add :source_status, :string, null: false
      add :disposition, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:portable_import_items, [:import_receipt_id, :origin_record_ref])

    create constraint(:portable_export_receipts, :portable_export_shape,
             check:
               "sequence > 0 AND source_installation_ref ~ '^[0-9a-f]{64}$' AND envelope_digest ~ '^[0-9a-f]{64}$' AND profile_record_count BETWEEN 0 AND 200 AND status IN ('active','rotated','tombstoned') AND ((status='active' AND rotated_at IS NULL AND tombstoned_at IS NULL) OR (status='rotated' AND rotated_at IS NOT NULL AND tombstoned_at IS NULL) OR (status='tombstoned' AND tombstoned_at IS NOT NULL))"
           )

    create constraint(:portable_import_receipts, :portable_import_shape,
             check:
               "export_sequence > 0 AND source_installation_ref ~ '^[0-9a-f]{64}$' AND envelope_digest ~ '^[0-9a-f]{64}$' AND confirmation_digest ~ '^[0-9a-f]{64}$' AND status IN ('active','revoked') AND imported_count >= 0 AND unchanged_count >= 0 AND conflict_count >= 0 AND tombstone_count >= 0 AND imported_count + unchanged_count + conflict_count + tombstone_count <= 200 AND ((status='active' AND revoked_at IS NULL AND revocation_digest IS NULL) OR (status='revoked' AND revoked_at IS NOT NULL AND revocation_digest ~ '^[0-9a-f]{64}$'))"
           )

    create constraint(:portable_import_items, :portable_import_item_shape,
             check:
               "origin_record_ref ~ '^[0-9a-f]{64}$' AND source_status IN ('candidate','active','superseded','forgotten','expired') AND disposition IN ('imported','unchanged','conflict','tombstone_applied','tombstone_absent')"
           )

    execute("""
    CREATE FUNCTION protect_portable_export_receipt() RETURNS trigger AS $$
    BEGIN
      IF ROW(OLD.owner_visitor_id,OLD.source_installation_ref,OLD.sequence,OLD.envelope_digest,OLD.profile_record_count,OLD.kdf_id,OLD.cipher_id,OLD.previous_export_id,OLD.inserted_at) IS DISTINCT FROM ROW(NEW.owner_visitor_id,NEW.source_installation_ref,NEW.sequence,NEW.envelope_digest,NEW.profile_record_count,NEW.kdf_id,NEW.cipher_id,NEW.previous_export_id,NEW.inserted_at)
      THEN RAISE EXCEPTION 'portable export identity is immutable'; END IF;
      IF NOT ((OLD.status='active' AND NEW.status IN ('rotated','tombstoned')) OR (OLD.status='rotated' AND NEW.status='tombstoned'))
      THEN RAISE EXCEPTION 'invalid portable export transition'; END IF;
      RETURN NEW;
    END; $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER portable_export_transition BEFORE UPDATE ON portable_export_receipts FOR EACH ROW EXECUTE FUNCTION protect_portable_export_receipt()"
    )

    execute("""
    CREATE FUNCTION protect_portable_import_receipt() RETURNS trigger AS $$
    BEGIN
      IF ROW(OLD.owner_visitor_id,OLD.source_installation_ref,OLD.export_sequence,OLD.envelope_digest,OLD.confirmation_digest,OLD.imported_count,OLD.unchanged_count,OLD.conflict_count,OLD.tombstone_count,OLD.inserted_at) IS DISTINCT FROM ROW(NEW.owner_visitor_id,NEW.source_installation_ref,NEW.export_sequence,NEW.envelope_digest,NEW.confirmation_digest,NEW.imported_count,NEW.unchanged_count,NEW.conflict_count,NEW.tombstone_count,NEW.inserted_at)
      THEN RAISE EXCEPTION 'portable import identity is immutable'; END IF;
      IF NOT (OLD.status='active' AND NEW.status='revoked')
      THEN RAISE EXCEPTION 'invalid portable import transition'; END IF;
      RETURN NEW;
    END; $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER portable_import_transition BEFORE UPDATE ON portable_import_receipts FOR EACH ROW EXECUTE FUNCTION protect_portable_import_receipt()"
    )

    execute(
      "CREATE FUNCTION reject_portable_import_item_mutation() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'portable import items are immutable'; END; $$ LANGUAGE plpgsql;"
    )

    execute(
      "CREATE TRIGGER portable_import_items_immutable BEFORE UPDATE ON portable_import_items FOR EACH ROW EXECUTE FUNCTION reject_portable_import_item_mutation()"
    )
  end

  def down do
    execute("DROP FUNCTION IF EXISTS reject_portable_import_item_mutation() CASCADE")
    execute("DROP FUNCTION IF EXISTS protect_portable_import_receipt() CASCADE")
    execute("DROP FUNCTION IF EXISTS protect_portable_export_receipt() CASCADE")
    drop table(:portable_import_items)
    drop table(:portable_import_receipts)
    drop table(:portable_export_receipts)
  end
end
