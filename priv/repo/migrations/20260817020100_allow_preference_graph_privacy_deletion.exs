defmodule Sarah.Repo.Migrations.AllowPreferenceGraphPrivacyDeletion do
  use Ecto.Migration

  @append_only_tables ~w(
    preference_observations
    preference_review_receipts
    preference_confirmation_receipts
    preference_activation_receipts
    preference_outcome_receipts
    preference_snapshots
  )

  def up do
    replace_foreign_keys("CASCADE")

    for table <- @append_only_tables do
      execute("""
      CREATE OR REPLACE FUNCTION reject_#{table}_mutation()
      RETURNS trigger AS $$
      BEGIN
        IF TG_OP = 'DELETE' AND NOT EXISTS (
          SELECT 1 FROM visitors WHERE id = OLD.owner_visitor_id
        ) THEN
          RETURN OLD;
        END IF;

        RAISE EXCEPTION '#{table} is append-only';
      END;
      $$ LANGUAGE plpgsql;
      """)
    end
  end

  def down do
    replace_foreign_keys("RESTRICT")

    for table <- @append_only_tables do
      execute("""
      CREATE OR REPLACE FUNCTION reject_#{table}_mutation()
      RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION '#{table} is append-only';
      END;
      $$ LANGUAGE plpgsql;
      """)
    end
  end

  defp replace_foreign_keys(on_delete) do
    replace_foreign_key(
      "preferences",
      "preferences_observation_id_fkey",
      "observation_id",
      "preference_observations",
      on_delete
    )

    for table <- ~w(
          preference_review_receipts
          preference_confirmation_receipts
          preference_activation_receipts
          preference_outcome_receipts
        ) do
      replace_foreign_key(
        table,
        "#{table}_preference_id_fkey",
        "preference_id",
        "preferences",
        on_delete
      )
    end

    replace_foreign_key(
      "preference_outcome_receipts",
      "preference_outcome_receipts_activation_receipt_id_fkey",
      "activation_receipt_id",
      "preference_activation_receipts",
      on_delete
    )

    replace_foreign_key(
      "preference_outcome_receipts",
      "preference_outcome_receipts_turn_id_fkey",
      "turn_id",
      "turns",
      on_delete
    )
  end

  defp replace_foreign_key(table, constraint, column, target, on_delete) do
    execute("ALTER TABLE #{table} DROP CONSTRAINT #{constraint}")

    execute(
      "ALTER TABLE #{table} ADD CONSTRAINT #{constraint} FOREIGN KEY (#{column}) REFERENCES #{target}(id) ON DELETE #{on_delete}"
    )
  end
end
