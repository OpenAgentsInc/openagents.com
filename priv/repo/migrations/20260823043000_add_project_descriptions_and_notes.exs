defmodule OpenAgents.Repo.Migrations.AddProjectDescriptionsAndNotes do
  use Ecto.Migration

  def up do
    alter table(:projects) do
      add :description, :text
    end

    create table(:project_notes) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false

      add :repository_id,
          references(:repositories, type: :binary_id, on_delete: :delete_all),
          null: false

      add :author_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :author, :map
      add :kind, :string, null: false, default: "note"
      add :body, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:project_notes, [:project_id, :id])
    create index(:project_notes, [:repository_id])

    create constraint(:project_notes, :project_notes_kind_check,
             check: "kind in ('note', 'activity')"
           )

    # A note belongs to the project and to the repository that owns the
    # project, and the pair has to agree: the repository is the authority
    # boundary every project surface reads through, so a note whose
    # repository_id drifted from its project's would be readable by the wrong
    # members.
    execute("""
    ALTER TABLE project_notes
      ADD CONSTRAINT project_notes_project_repository_fkey
      FOREIGN KEY (project_id, repository_id)
      REFERENCES projects (id, repository_id)
      ON DELETE CASCADE
    """)
  end

  def down do
    execute("ALTER TABLE project_notes DROP CONSTRAINT project_notes_project_repository_fkey")
    drop table(:project_notes)

    alter table(:projects) do
      remove :description
    end
  end
end
