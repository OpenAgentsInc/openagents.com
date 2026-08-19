defmodule Sarah.Repo.Migrations.CreateChangelogEntries do
  use Ecto.Migration

  def change do
    create table(:changelog_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :repo, :string, null: false
      add :sha, :string, null: false
      add :summary, :string, null: false
      add :category, :string, null: false
      add :visibility, :string, null: false, default: "l2"
      add :disclosure_after, :utc_datetime_usec
      add :source, :string, null: false
      add :entry_at, :utc_datetime_usec, null: false
      add :trace_ref, :string
      add :trace_digest, :string
      add :detail, :map, null: false, default: %{}
      add :push_receipt_id, :binary_id
      add :build_receipt_id, :binary_id
      add :target_id, :binary_id
      add :deploy_receipt_id, :binary_id
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:changelog_entries, [:repo, :entry_at])
    create unique_index(:changelog_entries, [:repo, :sha, :source])

    create constraint(:changelog_entries, :changelog_entries_category,
             check:
               "category IN ('ui','voice','feature','fix','infra','forge','memory','agents','privacy','incident')"
           )

    create constraint(:changelog_entries, :changelog_entries_source,
             check: "source IN ('coding_job','commit_trailer','operator','backfill')"
           )
  end
end
