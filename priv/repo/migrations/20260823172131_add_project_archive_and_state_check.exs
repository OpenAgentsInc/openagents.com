defmodule OpenAgents.Repo.Migrations.AddProjectArchiveAndStateCheck do
  use Ecto.Migration

  # Archiving is orthogonal to `state`: a board is retired from the working set
  # without claiming the work it tracked is finished, and it comes back
  # unchanged. Keeping the archive a timestamp rather than a third `state`
  # value leaves every open/closed reader — the API, the board, the workspace
  # tabs — reading the same two values it always read.
  def up do
    alter table(:projects) do
      add :archived_at, :utc_datetime
    end

    create index(:projects, [:repository_id, :archived_at])

    create constraint(:projects, :projects_state_check, check: "state in ('open', 'closed')")
  end

  def down do
    drop constraint(:projects, :projects_state_check)
    drop index(:projects, [:repository_id, :archived_at])

    alter table(:projects) do
      remove :archived_at
    end
  end
end
