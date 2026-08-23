defmodule OpenAgents.Repo.Migrations.CreateIssueClosingReferences do
  use Ecto.Migration

  def change do
    create table(:issue_closing_references, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all),
        null: false

      add :issue_id, references(:issues, on_delete: :delete_all), null: false
      add :commit_sha, :string, null: false, size: 64
      add :repo, :string
      add :wal_seq, :integer
      add :principal, :string, null: false
      add :verb, :string
      add :closed, :boolean, null: false, default: false
      add :closed_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :push_receipt_id, :binary_id

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # The idempotency gate. WAL replay, receipt reconciliation, and a force
    # push that re-presents the same commits all arrive at the same pair, and
    # this index turns the second arrival into a no-op rather than a second
    # close and a second timeline entry.
    create unique_index(:issue_closing_references, [:issue_id, :commit_sha])

    # The issue page reads its own references; the commit page reads the
    # references one commit made.
    create index(:issue_closing_references, [:repository_id, :commit_sha])
  end
end
