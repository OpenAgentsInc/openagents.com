defmodule OpenAgents.Repo.Migrations.AddCancelledStatusToAccountChatRuns do
  use Ecto.Migration

  def up do
    drop constraint(:account_chat_runs, :account_chat_runs_status)

    create constraint(:account_chat_runs, :account_chat_runs_status,
             check: "status IN ('streaming', 'completed', 'failed', 'cancelled')"
           )

    alter table(:account_chat_runs) do
      add :error_code, :string
      add :latency_ms, :integer
      # Redaction blanks every field whose name contains `token`, which token
      # counts do. The counts the provider reported live here instead.
      add :usage, :map
    end
  end

  def down do
    alter table(:account_chat_runs) do
      remove :error_code
      remove :latency_ms
      remove :usage
    end

    execute "UPDATE account_chat_runs SET status = 'failed' WHERE status = 'cancelled'"

    drop constraint(:account_chat_runs, :account_chat_runs_status)

    create constraint(:account_chat_runs, :account_chat_runs_status,
             check: "status IN ('streaming', 'completed', 'failed')"
           )
  end
end
