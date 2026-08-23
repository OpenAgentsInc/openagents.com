defmodule OpenAgents.Repo.Migrations.CreatePullRequestStackApiTables do
  use Ecto.Migration

  def change do
    create table(:pull_request_stack_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :stack_id,
          references(:pull_request_stacks, type: :binary_id, on_delete: :delete_all),
          null: false

      add :event_type, :string, null: false
      add :stack_version, :bigint, null: false
      add :actor_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :payload, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create index(:pull_request_stack_events, [:stack_id])

    create constraint(:pull_request_stack_events, :pull_request_stack_events_version_check,
             check: "stack_version >= 1"
           )

    create table(:pull_request_stack_idempotency_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :operation, :string, null: false
      add :idempotency_key, :string, null: false
      add :request_digest, :string, null: false

      add :stack_id,
          references(:pull_request_stacks, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:pull_request_stack_idempotency_requests, [
             :user_id,
             :operation,
             :idempotency_key
           ])

    create constraint(
             :pull_request_stack_idempotency_requests,
             :pull_request_stack_idempotency_digest_check,
             check: "request_digest ~ '^[0-9a-f]{64}$'"
           )
  end
end
