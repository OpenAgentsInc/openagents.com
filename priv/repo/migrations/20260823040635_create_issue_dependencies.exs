defmodule OpenAgents.Repo.Migrations.CreateIssueDependencies do
  use Ecto.Migration

  def change do
    create table(:issue_dependencies, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all),
        null: false

      add :issue_id, references(:issues, on_delete: :delete_all), null: false
      add :blocked_by_issue_id, references(:issues, on_delete: :delete_all), null: false
      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      timestamps(type: :utc_datetime)
    end

    # One edge per ordered pair, so recording the same prerequisite twice is a
    # no-op rather than a duplicate the graph has to deduplicate on every read.
    create unique_index(:issue_dependencies, [:issue_id, :blocked_by_issue_id])

    # Both directions are read equally often: an issue asks what blocks it, and
    # a closing issue asks what it releases.
    create index(:issue_dependencies, [:blocked_by_issue_id])
    create index(:issue_dependencies, [:repository_id])

    create constraint(:issue_dependencies, :issue_dependencies_no_self_reference,
             check: "issue_id <> blocked_by_issue_id"
           )
  end
end
