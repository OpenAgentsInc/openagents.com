defmodule OpenAgents.Repo.Migrations.AddBackendToAccountChatRuns do
  use Ecto.Migration

  # A turn now names the backend that answered it. Without the column a
  # conversation cannot tell which model produced an earlier answer, and the
  # history it replays into the next turn is shaped for whichever provider
  # wrote it: an OpenRouter Responses output list is not a Gemini turn. A row
  # written before this column is an Ox Alpha turn, which is what `NULL` reads
  # as, so no backfill is needed and no stored row is rewritten.
  def change do
    alter table(:account_chat_runs) do
      add :backend, :string
    end
  end
end
