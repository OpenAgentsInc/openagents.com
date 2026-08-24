defmodule OpenAgents.Repo.Migrations.DropScvRunsIssueId do
  use Ecto.Migration

  # `scv_runs.issue_id` was a second issue-to-work record that no caller ever
  # set. `forge_assignments` is the one attempt record that binds an issue to
  # work. Issue #152 decided to drop the column rather than keep a fourth,
  # unreachable edge. The reversal restores the column and its index exactly.
  def change do
    drop index(:scv_runs, [:issue_id, :inserted_at])

    alter table(:scv_runs) do
      remove :issue_id, references(:issues, on_delete: :nilify_all)
    end
  end
end
