defmodule OpenAgents.Repo.Migrations.CreatePullRequests do
  use Ecto.Migration

  def change do
    alter table(:repositories) do
      add :pull_requests_enabled, :boolean, null: false, default: true
    end

    execute(
      "UPDATE repositories SET pull_requests_enabled = FALSE WHERE owner_key = 'openagentsinc' AND name_key = 'openagents.com'",
      "UPDATE repositories SET pull_requests_enabled = TRUE WHERE owner_key = 'openagentsinc' AND name_key = 'openagents.com'"
    )

    create table(:pull_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :repository_id, references(:repositories, type: :binary_id, on_delete: :delete_all),
        null: false

      add :issue_id, references(:issues, on_delete: :delete_all), null: false

      add :head_repository_id, references(:repositories, type: :binary_id, on_delete: :restrict),
        null: false

      add :head_ref, :string, null: false
      add :head_sha, :string, null: false
      add :base_ref, :string, null: false
      add :base_sha, :string, null: false
      add :state, :string, null: false, default: "open"
      add :merged_at, :utc_datetime_usec
      add :merged_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :merge_commit_sha, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:pull_requests, [:issue_id])
    create index(:pull_requests, [:repository_id])
    create index(:pull_requests, [:head_repository_id])

    create unique_index(
             :pull_requests,
             [:repository_id, :head_repository_id, :head_ref, :base_ref],
             where: "state = 'open'",
             name: :pull_requests_one_open_head_base_index
           )

    create constraint(:pull_requests, :pull_requests_state_check,
             check: "state IN ('open', 'closed')"
           )
  end
end
