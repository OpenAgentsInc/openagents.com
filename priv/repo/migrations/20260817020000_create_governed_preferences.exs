defmodule OpenAgents.Repo.Migrations.CreateGovernedPreferences do
  use Ecto.Migration

  def up do
    create table(:preference_scopes, primary_key: false) do
      add :owner_visitor_id,
          references(:visitors, type: :binary_id, on_delete: :delete_all),
          primary_key: true

      add :generation, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create table(:preference_observations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :owner_visitor_id,
          references(:visitors, type: :binary_id, on_delete: :delete_all),
          null: false

      add :source_message_id,
          references(:messages, type: :binary_id, on_delete: :nilify_all)

      add :source_kind, :string, null: false
      add :summary, :text, null: false
      add :evidence_digest, :string, null: false
      add :confidence_millis, :integer, null: false
      add :observed_at, :utc_datetime_usec, null: false
      add :freshness_until, :utc_datetime_usec
      add :proposer_id, :string, null: false
      add :proposer_digest, :string, null: false
      add :policy_id, :string, null: false
      add :policy_version, :integer, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create table(:preferences, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :owner_visitor_id,
          references(:visitors, type: :binary_id, on_delete: :delete_all),
          null: false

      add :observation_id,
          references(:preference_observations, type: :binary_id, on_delete: :restrict),
          null: false

      add :supersedes_preference_id,
          references(:preferences, type: :binary_id, on_delete: :nilify_all)

      add :category, :string, null: false
      add :effect_key, :string, null: false
      add :effect_value, :string, null: false
      add :proposed_effect, :map, null: false
      add :effect_digest, :string, null: false
      add :status, :string, null: false, default: "candidate"
      add :confidence_millis, :integer, null: false
      add :freshness_until, :utc_datetime_usec
      add :policy_id, :string, null: false
      add :policy_version, :integer, null: false
      add :generation, :bigint, null: false, default: 1
      add :created_generation, :bigint, null: false
      add :active_generation, :bigint
      add :terminal_generation, :bigint
      add :confirmation_ref, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:preferences, [:owner_visitor_id, :effect_key],
             where: "status = 'active'",
             name: :one_active_preference_effect
           )

    create index(:preferences, [:owner_visitor_id, :status, :id])

    create index(:preferences, [:owner_visitor_id, :active_generation, :terminal_generation],
             name: :preferences_snapshot_index
           )

    create table(:preference_review_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :preference_id, references(:preferences, type: :binary_id, on_delete: :restrict),
        null: false

      add :owner_visitor_id, :binary_id, null: false
      add :reviewer_id, :string, null: false
      add :decision, :string, null: false
      add :reason_code, :string, null: false
      add :effect_digest, :string, null: false
      add :receipt_digest, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create table(:preference_activation_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :preference_id, references(:preferences, type: :binary_id, on_delete: :restrict),
        null: false

      add :owner_visitor_id, :binary_id, null: false
      add :scope_generation, :bigint, null: false
      add :confirmation_ref, :string, null: false
      add :effect_digest, :string, null: false
      add :policy_id, :string, null: false
      add :policy_version, :integer, null: false
      add :receipt_digest, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:preference_activation_receipts, [:preference_id, :scope_generation],
             name: :preference_activation_identity
           )

    create table(:preference_confirmation_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :preference_id, references(:preferences, type: :binary_id, on_delete: :restrict),
        null: false

      add :owner_visitor_id, :binary_id, null: false
      add :kind, :string, null: false
      add :evidence_ref, :string, null: false
      add :effect_digest, :string, null: false
      add :receipt_digest, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create table(:preference_outcome_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :preference_id, references(:preferences, type: :binary_id, on_delete: :restrict),
        null: false

      add :turn_id, references(:turns, type: :binary_id, on_delete: :restrict), null: false
      add :owner_visitor_id, :binary_id, null: false

      add :activation_receipt_id,
          references(:preference_activation_receipts, type: :binary_id, on_delete: :restrict),
          null: false

      add :outcome, :string, null: false
      add :evidence_ref, :string, null: false
      add :reason_code, :string, null: false
      add :receipt_digest, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:preference_outcome_receipts, [:preference_id, :turn_id, :evidence_ref],
             name: :preference_outcome_identity
           )

    create table(:preference_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :owner_visitor_id,
          references(:visitors, type: :binary_id, on_delete: :delete_all),
          null: false

      add :scope_generation, :bigint, null: false
      add :captured_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:preference_snapshots, [:owner_visitor_id, :inserted_at, :id])

    create constraint(:preference_scopes, :preference_scope_generation, check: "generation >= 0")

    create constraint(:preference_observations, :preference_observation_shape,
             check:
               "source_kind IN ('current_user_message','correction','tool_outcome') AND octet_length(summary) BETWEEN 1 AND 500 AND evidence_digest ~ '^[0-9a-f]{64}$' AND proposer_digest ~ '^[0-9a-f]{64}$' AND confidence_millis BETWEEN 0 AND 1000 AND policy_version > 0 AND (freshness_until IS NULL OR freshness_until > observed_at)"
           )

    create constraint(:preferences, :preference_effect_shape,
             check:
               "category IN ('presentation','interaction') AND effect_key IN ('response_length','format','tone','initiative') AND ((effect_key='response_length' AND effect_value IN ('concise','detailed')) OR (effect_key='format' AND effect_value IN ('bullets','paragraphs')) OR (effect_key='tone' AND effect_value IN ('direct','gentle')) OR (effect_key='initiative' AND effect_value IN ('ask_first','suggest_next_steps'))) AND proposed_effect = jsonb_build_object('key', effect_key, 'value', effect_value) AND effect_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:preferences, :preference_lifecycle_shape,
             check:
               "status IN ('candidate','reviewed','confirmed','active','suspended','deleted') AND confidence_millis BETWEEN 0 AND 1000 AND policy_version > 0 AND generation > 0 AND created_generation > 0 AND ((status IN ('candidate','reviewed','confirmed') AND active_generation IS NULL AND terminal_generation IS NULL) OR (status='active' AND active_generation IS NOT NULL AND terminal_generation IS NULL AND confirmation_ref IS NOT NULL) OR (status IN ('suspended','deleted') AND terminal_generation IS NOT NULL))"
           )

    create constraint(:preference_review_receipts, :preference_review_receipt_shape,
             check:
               "decision IN ('accepted','rejected') AND effect_digest ~ '^[0-9a-f]{64}$' AND receipt_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:preference_activation_receipts, :preference_activation_receipt_shape,
             check:
               "scope_generation > 0 AND policy_version > 0 AND effect_digest ~ '^[0-9a-f]{64}$' AND receipt_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:preference_confirmation_receipts, :preference_confirmation_receipt_shape,
             check:
               "kind IN ('exact_confirmation','first_party_ui') AND effect_digest ~ '^[0-9a-f]{64}$' AND receipt_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:preference_outcome_receipts, :preference_outcome_receipt_shape,
             check:
               "outcome IN ('benefited','neutral','corrected','rejected') AND receipt_digest ~ '^[0-9a-f]{64}$'"
           )

    execute("""
    CREATE FUNCTION validate_preference_evidence_receipt() RETURNS trigger AS $$
    DECLARE preference_owner uuid;
    DECLARE preference_effect text;
    BEGIN
      SELECT owner_visitor_id,effect_digest INTO preference_owner,preference_effect
      FROM preferences WHERE id=NEW.preference_id;
      IF preference_owner IS NULL OR preference_owner <> NEW.owner_visitor_id OR
         preference_effect <> NEW.effect_digest THEN
        RAISE EXCEPTION 'preference receipt scope mismatch';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    for table <- [
          "preference_review_receipts",
          "preference_confirmation_receipts",
          "preference_activation_receipts"
        ] do
      execute(
        "CREATE TRIGGER #{table}_scope BEFORE INSERT ON #{table} FOR EACH ROW EXECUTE FUNCTION validate_preference_evidence_receipt()"
      )
    end

    execute("""
    CREATE FUNCTION validate_preference_outcome_scope() RETURNS trigger AS $$
    DECLARE preference_owner uuid;
    DECLARE activation_preference uuid;
    DECLARE activation_owner uuid;
    BEGIN
      SELECT owner_visitor_id INTO preference_owner FROM preferences WHERE id=NEW.preference_id;
      SELECT preference_id,owner_visitor_id INTO activation_preference,activation_owner
      FROM preference_activation_receipts WHERE id=NEW.activation_receipt_id;
      IF preference_owner IS NULL OR preference_owner <> NEW.owner_visitor_id OR
         activation_preference <> NEW.preference_id OR activation_owner <> NEW.owner_visitor_id THEN
        RAISE EXCEPTION 'preference outcome scope mismatch';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER preference_outcome_receipts_scope BEFORE INSERT ON preference_outcome_receipts FOR EACH ROW EXECUTE FUNCTION validate_preference_outcome_scope()"
    )

    execute("""
    CREATE FUNCTION validate_preference_observation_source() RETURNS trigger AS $$
    DECLARE message_owner uuid;
    DECLARE message_role text;
    DECLARE message_status text;
    BEGIN
      IF NEW.source_kind IN ('current_user_message','correction') AND NEW.source_message_id IS NULL THEN
        RAISE EXCEPTION 'preference observation source required';
      END IF;
      IF NEW.source_message_id IS NOT NULL THEN
        SELECT c.visitor_id,m.role,m.status INTO message_owner,message_role,message_status
        FROM messages m JOIN conversations c ON c.id=m.conversation_id
        WHERE m.id=NEW.source_message_id;
        IF message_owner IS NULL OR message_owner <> NEW.owner_visitor_id OR
           message_role <> 'user' OR message_status <> 'complete' THEN
          RAISE EXCEPTION 'invalid preference observation source';
        END IF;
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER preference_observation_source_scope BEFORE INSERT ON preference_observations FOR EACH ROW EXECUTE FUNCTION validate_preference_observation_source()"
    )

    execute("""
    CREATE FUNCTION protect_preference_identity_and_transition() RETURNS trigger AS $$
    BEGIN
      IF ROW(OLD.owner_visitor_id,OLD.observation_id,OLD.category,OLD.effect_key,
             OLD.effect_value,OLD.proposed_effect,OLD.effect_digest,OLD.confidence_millis,
             OLD.freshness_until,OLD.policy_id,OLD.policy_version,OLD.created_generation,
             OLD.supersedes_preference_id)
         IS DISTINCT FROM
         ROW(NEW.owner_visitor_id,NEW.observation_id,NEW.category,NEW.effect_key,
             NEW.effect_value,NEW.proposed_effect,NEW.effect_digest,NEW.confidence_millis,
             NEW.freshness_until,NEW.policy_id,NEW.policy_version,NEW.created_generation,
             NEW.supersedes_preference_id) THEN
        RAISE EXCEPTION 'preference identity is immutable; create a correction';
      END IF;
      IF NEW.generation <> OLD.generation + 1 THEN
        RAISE EXCEPTION 'preference generation must advance exactly once';
      END IF;
      IF NOT ((OLD.status='candidate' AND NEW.status IN ('reviewed','deleted')) OR
              (OLD.status='reviewed' AND NEW.status IN ('confirmed','deleted')) OR
              (OLD.status='confirmed' AND NEW.status IN ('active','deleted')) OR
              (OLD.status='active' AND NEW.status IN ('suspended','deleted')) OR
              (OLD.status='suspended' AND NEW.status='deleted')) THEN
        RAISE EXCEPTION 'invalid preference lifecycle transition';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER preference_transition_guard BEFORE UPDATE ON preferences FOR EACH ROW EXECUTE FUNCTION protect_preference_identity_and_transition()"
    )

    for table <- [
          "preference_observations",
          "preference_review_receipts",
          "preference_confirmation_receipts",
          "preference_activation_receipts",
          "preference_outcome_receipts",
          "preference_snapshots"
        ] do
      execute("""
      CREATE FUNCTION reject_#{table}_mutation() RETURNS trigger AS $$
      BEGIN RAISE EXCEPTION '#{table} is append-only'; END;
      $$ LANGUAGE plpgsql;
      """)

      execute(
        "CREATE TRIGGER #{table}_append_only BEFORE UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION reject_#{table}_mutation()"
      )
    end

    execute("""
    CREATE FUNCTION protect_turn_preference_capture() RETURNS trigger AS $$
    BEGIN
      IF OLD.preference_snapshot_ref IS DISTINCT FROM NEW.preference_snapshot_ref OR
         OLD.used_preferences IS DISTINCT FROM NEW.used_preferences THEN
        RAISE EXCEPTION 'turn preference capture is immutable';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute(
      "CREATE TRIGGER turn_preference_capture_immutable BEFORE UPDATE ON turn_receipts FOR EACH ROW EXECUTE FUNCTION protect_turn_preference_capture()"
    )
  end

  def down do
    execute("DROP TRIGGER IF EXISTS turn_preference_capture_immutable ON turn_receipts")
    execute("DROP FUNCTION IF EXISTS protect_turn_preference_capture()")
    execute("DROP TRIGGER IF EXISTS preference_transition_guard ON preferences")
    execute("DROP FUNCTION IF EXISTS protect_preference_identity_and_transition()")

    execute(
      "DROP TRIGGER IF EXISTS preference_observation_source_scope ON preference_observations"
    )

    execute("DROP FUNCTION IF EXISTS validate_preference_observation_source()")
    execute("DROP FUNCTION IF EXISTS validate_preference_evidence_receipt() CASCADE")
    execute("DROP FUNCTION IF EXISTS validate_preference_outcome_scope() CASCADE")

    for table <- [
          "preference_observations",
          "preference_review_receipts",
          "preference_confirmation_receipts",
          "preference_activation_receipts",
          "preference_outcome_receipts",
          "preference_snapshots"
        ] do
      execute("DROP FUNCTION IF EXISTS reject_#{table}_mutation() CASCADE")
    end

    drop table(:preference_snapshots)
    drop table(:preference_outcome_receipts)
    drop table(:preference_confirmation_receipts)
    drop table(:preference_activation_receipts)
    drop table(:preference_review_receipts)
    drop table(:preferences)
    drop table(:preference_observations)
    drop table(:preference_scopes)
  end
end
