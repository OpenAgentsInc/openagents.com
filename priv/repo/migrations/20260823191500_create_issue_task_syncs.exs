defmodule OpenAgents.Repo.Migrations.CreateIssueTaskSyncs do
  use Ecto.Migration

  def change do
    create table(:issue_task_syncs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all),
        null: false

      # The issue whose history shows the edit. For a rewritten comment this is
      # the issue the comment hangs off, so one read assembles the feed.
      add :issue_id, references(:issues, on_delete: :delete_all), null: false
      add :comment_id, references(:comments, on_delete: :delete_all)

      # The issue whose state change caused the edit.
      add :reference_issue_id, references(:issues, on_delete: :delete_all), null: false
      add :reference_number, :integer, null: false
      add :checked, :boolean, null: false, default: false
      add :principal, :string, null: false, default: "system"

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # The issue page reads its own edits in order. There is deliberately no
    # unique key here: closing, reopening, and closing an issue again are three
    # real edits, and the history should show all three. Idempotency comes from
    # the rendered body instead — a rewrite that would change nothing is never
    # written, so it never reaches this table.
    create index(:issue_task_syncs, [:issue_id, :inserted_at])
    create index(:issue_task_syncs, [:reference_issue_id])
  end
end
