defmodule OpenAgents.Repo.Migrations.CreateStagingDisposableResources do
  use Ecto.Migration

  def up do
    create table(:staging_disposable_resources, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :run_id, :string, null: false
      add :kind, :string, null: false
      add :resource_id, :binary_id, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("timezone('utc', now())")
    end

    create index(:staging_disposable_resources, [:run_id])
    create unique_index(:staging_disposable_resources, [:kind, :resource_id])

    create constraint(:staging_disposable_resources, :staging_disposable_run_id_check,
             check: "run_id ~ '^[a-z0-9][a-z0-9-]{7,63}$'"
           )

    create constraint(:staging_disposable_resources, :staging_disposable_kind_check,
             check: "kind IN ('account', 'machine', 'recording', 'repository')"
           )

    execute("""
    CREATE FUNCTION prevent_staging_disposable_resource_update()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'staging disposable resource registrations are immutable';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER staging_disposable_resources_prevent_update
    BEFORE UPDATE ON staging_disposable_resources
    FOR EACH ROW
    EXECUTE FUNCTION prevent_staging_disposable_resource_update();
    """)
  end

  def down do
    drop table(:staging_disposable_resources)
    execute("DROP FUNCTION prevent_staging_disposable_resource_update()")
  end
end
