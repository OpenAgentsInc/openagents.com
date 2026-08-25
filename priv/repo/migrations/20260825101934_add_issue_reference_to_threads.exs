defmodule OpenAgents.Repo.Migrations.AddIssueReferenceToThreads do
  @moduledoc """
  A thread may name the issue it is doing work for.

  The reference is nullable: a thread can exist without naming an issue,
  and an issue is never a second work record. Deleting an issue leaves the
  thread behind with a null reference, because the thread is the durable
  work record.
  """

  use Ecto.Migration

  def change do
    alter table(:threads) do
      add :issue_id, references(:issues, on_delete: :nilify_all)
    end

    create index(:threads, [:issue_id])
  end
end
