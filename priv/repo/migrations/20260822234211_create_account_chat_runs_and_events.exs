defmodule OpenAgents.Repo.Migrations.CreateAccountChatRunsAndEvents do
  use Ecto.Migration

  def change do
    create table(:account_chat_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :status, :string, null: false
      add :reasoning_effort, :string, null: false
      add :user_content, :text, null: false
      add :assistant_content, :text
      add :completion, :map
      add :error, :text
      add :started_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:account_chat_runs, [:conversation_id, :inserted_at])

    create unique_index(:account_chat_runs, [:conversation_id],
             where: "status = 'streaming'",
             name: :account_chat_runs_one_streaming_per_conversation
           )

    create constraint(:account_chat_runs, :account_chat_runs_status,
             check: "status IN ('streaming', 'completed', 'failed')"
           )

    create table(:account_chat_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :run_id, references(:account_chat_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :sequence, :integer, null: false
      add :kind, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :observed_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:account_chat_events, [:run_id, :sequence])
    create index(:account_chat_events, [:run_id, :observed_at])

    create constraint(:account_chat_events, :account_chat_events_positive_sequence,
             check: "sequence > 0"
           )
  end
end
