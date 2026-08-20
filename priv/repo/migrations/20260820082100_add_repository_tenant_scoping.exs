defmodule OpenAgents.Repo.Migrations.AddRepositoryTenantScoping do
  use Ecto.Migration

  @initial_repository_id "00000000-0000-4000-8000-000000000001"

  def up do
    create table(:repositories, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :owner, :string, null: false
      add :name, :string, null: false
      add :owner_key, :string, null: false
      add :name_key, :string, null: false
      add :visibility, :string, null: false
      add :default_branch, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:repositories, [:owner_key, :name_key])

    create constraint(:repositories, :repositories_visibility_check,
             check: "visibility IN ('public', 'private')"
           )

    create constraint(:repositories, :repositories_normalized_path_check,
             check: "owner_key = lower(owner) AND name_key = lower(name)"
           )

    execute("""
    INSERT INTO repositories
      (id, owner, name, owner_key, name_key, visibility, default_branch, inserted_at, updated_at)
    VALUES
      ('#{@initial_repository_id}', 'OpenAgentsInc', 'openagents.com',
       'openagentsinc', 'openagents.com', 'public', 'main', now(), now())
    """)

    create table(:repository_memberships, primary_key: false) do
      add :repository_id,
          references(:repositories, type: :binary_id, on_delete: :delete_all),
          primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :role, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:repository_memberships, [:repository_id, :user_id])

    create constraint(:repository_memberships, :repository_memberships_role_check,
             check: "role IN ('owner', 'maintainer', 'contributor', 'viewer')"
           )

    alter table(:issues) do
      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all)
      add :milestone_id, references(:milestones, on_delete: :nilify_all)
      add :author_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
    end

    alter table(:labels) do
      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all)
    end

    alter table(:milestones) do
      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all)
    end

    alter table(:comments) do
      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all)
      add :author_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
    end

    alter table(:projects) do
      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all)
      add :owner_user_id, references(:users, type: :binary_id, on_delete: :restrict)
    end

    alter table(:project_items) do
      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all)
    end

    flush()

    for table <- ~w(issues labels milestones comments projects project_items)a do
      execute("UPDATE #{table} SET repository_id = '#{@initial_repository_id}'")
      execute("ALTER TABLE #{table} ALTER COLUMN repository_id SET NOT NULL")
    end

    execute("""
    INSERT INTO repository_memberships
      (repository_id, user_id, role, inserted_at, updated_at)
    SELECT '#{@initial_repository_id}', id, 'contributor', now(), now()
    FROM users
    ON CONFLICT (repository_id, user_id) DO NOTHING
    """)

    execute("""
    UPDATE issues AS issue
    SET author_user_id = app_user.id
    FROM users AS app_user
    WHERE issue.user IS NOT NULL
      AND lower(issue.user->>'login') = lower(app_user.github_login)
    """)

    execute("""
    UPDATE comments AS comment
    SET author_user_id = app_user.id
    FROM users AS app_user
    WHERE comment.user IS NOT NULL
      AND lower(comment.user->>'login') = lower(app_user.github_login)
    """)

    execute("""
    UPDATE projects AS project
    SET owner_user_id = app_user.id
    FROM users AS app_user
    WHERE lower(project.owner) = lower(app_user.github_login)
    """)

    execute("""
    UPDATE issues AS issue
    SET milestone_id = milestone.id
    FROM milestones AS milestone
    WHERE issue.milestone IS NOT NULL
      AND issue.repository_id = milestone.repository_id
      AND (issue.milestone->>'number')::integer = milestone.number
    """)

    drop index(:issues, [:number])
    create unique_index(:issues, [:repository_id, :number])
    create unique_index(:milestones, [:repository_id, :number])
    create unique_index(:labels, [:repository_id, :name])
    create unique_index(:projects, [:repository_id, :number])
    create unique_index(:issues, [:id, :repository_id])
    create unique_index(:labels, [:id, :repository_id])
    create unique_index(:milestones, [:id, :repository_id])
    create unique_index(:projects, [:id, :repository_id])

    create table(:issue_labels, primary_key: false) do
      add :issue_id, references(:issues, on_delete: :delete_all), primary_key: true
      add :label_id, references(:labels, on_delete: :delete_all), primary_key: true

      add :repository_id,
          references(:repositories, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:issue_labels, [:issue_id, :label_id])

    create table(:issue_assignees, primary_key: false) do
      add :issue_id, references(:issues, on_delete: :delete_all), primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :repository_id,
          references(:repositories, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:issue_assignees, [:issue_id, :user_id])

    flush()

    execute("""
    INSERT INTO labels (repository_id, name, color, description, inserted_at, updated_at)
    SELECT DISTINCT ON (issue.repository_id, label->>'name')
      issue.repository_id,
      label->>'name',
      COALESCE(NULLIF(label->>'color', ''), 'ffffff'),
      label->>'description',
      now(),
      now()
    FROM issues AS issue
    CROSS JOIN LATERAL unnest(issue.labels) AS label
    WHERE NULLIF(label->>'name', '') IS NOT NULL
    ON CONFLICT (repository_id, name) DO NOTHING
    """)

    execute("""
    INSERT INTO issue_labels
      (issue_id, label_id, repository_id, inserted_at, updated_at)
    SELECT issue.id, label.id, issue.repository_id, now(), now()
    FROM issues AS issue
    CROSS JOIN LATERAL unnest(issue.labels) AS snapshot
    JOIN labels AS label
      ON label.repository_id = issue.repository_id
     AND label.name = snapshot->>'name'
    ON CONFLICT (issue_id, label_id) DO NOTHING
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM issues AS issue
        CROSS JOIN LATERAL unnest(issue.assignees) AS snapshot
        LEFT JOIN users AS app_user
          ON lower(app_user.github_login) = lower(snapshot->>'login')
        WHERE NULLIF(snapshot->>'login', '') IS NOT NULL
          AND app_user.id IS NULL
      ) THEN
        RAISE EXCEPTION 'repository backfill found an assignee without a matching user';
      END IF;
    END
    $$
    """)

    execute("""
    INSERT INTO issue_assignees
      (issue_id, user_id, repository_id, inserted_at, updated_at)
    SELECT issue.id, app_user.id, issue.repository_id, now(), now()
    FROM issues AS issue
    CROSS JOIN LATERAL unnest(issue.assignees) AS snapshot
    JOIN users AS app_user
      ON lower(app_user.github_login) = lower(snapshot->>'login')
    ON CONFLICT (issue_id, user_id) DO NOTHING
    """)

    execute("""
    ALTER TABLE issue_labels
      ADD CONSTRAINT issue_labels_issue_repository_fkey
      FOREIGN KEY (issue_id, repository_id)
      REFERENCES issues (id, repository_id)
      ON DELETE CASCADE,
      ADD CONSTRAINT issue_labels_label_repository_fkey
      FOREIGN KEY (label_id, repository_id)
      REFERENCES labels (id, repository_id)
      ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE issue_assignees
      ADD CONSTRAINT issue_assignees_issue_repository_fkey
      FOREIGN KEY (issue_id, repository_id)
      REFERENCES issues (id, repository_id)
      ON DELETE CASCADE,
      ADD CONSTRAINT issue_assignees_membership_fkey
      FOREIGN KEY (repository_id, user_id)
      REFERENCES repository_memberships (repository_id, user_id)
      ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE comments
      ADD CONSTRAINT comments_issue_repository_fkey
      FOREIGN KEY (issue_id, repository_id)
      REFERENCES issues (id, repository_id)
      ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE issues
      ADD CONSTRAINT issues_milestone_repository_fkey
      FOREIGN KEY (milestone_id, repository_id)
      REFERENCES milestones (id, repository_id)
      ON DELETE SET NULL (milestone_id)
    """)

    execute("""
    ALTER TABLE projects
      ADD CONSTRAINT projects_owner_membership_fkey
      FOREIGN KEY (repository_id, owner_user_id)
      REFERENCES repository_memberships (repository_id, user_id)
      ON DELETE RESTRICT
    """)

    execute("""
    ALTER TABLE project_items
      ADD CONSTRAINT project_items_project_repository_fkey
      FOREIGN KEY (project_id, repository_id)
      REFERENCES projects (id, repository_id)
      ON DELETE CASCADE,
      ADD CONSTRAINT project_items_issue_repository_fkey
      FOREIGN KEY (issue_id, repository_id)
      REFERENCES issues (id, repository_id)
      ON DELETE RESTRICT
    """)
  end

  def down do
    execute("ALTER TABLE project_items DROP CONSTRAINT project_items_issue_repository_fkey")
    execute("ALTER TABLE project_items DROP CONSTRAINT project_items_project_repository_fkey")
    execute("ALTER TABLE projects DROP CONSTRAINT projects_owner_membership_fkey")
    execute("ALTER TABLE issues DROP CONSTRAINT issues_milestone_repository_fkey")
    execute("ALTER TABLE comments DROP CONSTRAINT comments_issue_repository_fkey")

    drop table(:issue_assignees)
    drop table(:issue_labels)

    drop index(:projects, [:id, :repository_id])
    drop index(:milestones, [:id, :repository_id])
    drop index(:labels, [:id, :repository_id])
    drop index(:issues, [:id, :repository_id])
    drop index(:projects, [:repository_id, :number])
    drop index(:labels, [:repository_id, :name])
    drop index(:milestones, [:repository_id, :number])
    drop index(:issues, [:repository_id, :number])
    create unique_index(:issues, [:number])

    alter table(:project_items), do: remove(:repository_id)

    alter table(:projects) do
      remove :owner_user_id
      remove :repository_id
    end

    alter table(:comments) do
      remove :author_user_id
      remove :repository_id
    end

    alter table(:milestones), do: remove(:repository_id)
    alter table(:labels), do: remove(:repository_id)

    alter table(:issues) do
      remove :author_user_id
      remove :milestone_id
      remove :repository_id
    end

    drop table(:repository_memberships)
    drop table(:repositories)
  end
end
