defmodule OpenAgents.Repo.Migrations.AllowCrossRepositoryProjectItems do
  use Ecto.Migration

  def up do
    alter table(:project_items) do
      add :issue_repository_id,
          references(:repositories, type: :binary_id, on_delete: :delete_all)
    end

    execute("UPDATE project_items SET issue_repository_id = repository_id")
    execute("ALTER TABLE project_items ALTER COLUMN issue_repository_id SET NOT NULL")
    execute("ALTER TABLE project_items DROP CONSTRAINT project_items_issue_repository_fkey")
    create index(:project_items, [:issue_repository_id])
    create unique_index(:project_items, [:project_id, :issue_id])

    execute("""
    ALTER TABLE project_items
      ADD CONSTRAINT project_items_issue_source_repository_fkey
      FOREIGN KEY (issue_id, issue_repository_id)
      REFERENCES issues (id, repository_id)
      ON DELETE RESTRICT
    """)
  end

  def down do
    execute("DELETE FROM project_items WHERE issue_repository_id <> repository_id")

    execute(
      "ALTER TABLE project_items DROP CONSTRAINT project_items_issue_source_repository_fkey"
    )

    drop unique_index(:project_items, [:project_id, :issue_id])
    drop index(:project_items, [:issue_repository_id])

    execute("""
    ALTER TABLE project_items
      ADD CONSTRAINT project_items_issue_repository_fkey
      FOREIGN KEY (issue_id, repository_id)
      REFERENCES issues (id, repository_id)
      ON DELETE RESTRICT
    """)

    alter table(:project_items), do: remove(:issue_repository_id)
  end
end
