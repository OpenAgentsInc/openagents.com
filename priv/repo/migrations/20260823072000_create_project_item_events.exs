defmodule OpenAgents.Repo.Migrations.CreateProjectItemEvents do
  use Ecto.Migration

  def up do
    create table(:project_item_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_item_id, :id, null: false
      add :project_id, :id, null: false

      add :repository_id, references(:repositories, type: :binary_id, on_delete: :nilify_all)

      add :actor_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :actor_login, :string, null: false
      add :kind, :string, null: false
      add :from_state, :string
      add :to_state, :string
      add :changes, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false
      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create index(:project_item_events, [:project_item_id, :occurred_at])
    create index(:project_item_events, [:project_id, :occurred_at])
    create index(:project_item_events, [:repository_id])

    execute("""
    CREATE OR REPLACE FUNCTION prevent_project_item_event_rewrite()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'project item events are append-only';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER project_item_events_prevent_update
    BEFORE UPDATE ON project_item_events
    FOR EACH ROW EXECUTE FUNCTION prevent_project_item_event_rewrite()
    """)

    execute("""
    CREATE TRIGGER project_item_events_prevent_delete
    BEFORE DELETE ON project_item_events
    FOR EACH ROW EXECUTE FUNCTION prevent_project_item_event_rewrite()
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS project_item_events_prevent_update ON project_item_events")
    execute("DROP TRIGGER IF EXISTS project_item_events_prevent_delete ON project_item_events")
    execute("DROP FUNCTION IF EXISTS prevent_project_item_event_rewrite()")
    drop table(:project_item_events)
  end
end
