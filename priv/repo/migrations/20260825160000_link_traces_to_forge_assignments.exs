defmodule OpenAgents.Repo.Migrations.LinkTracesToForgeAssignments do
  @moduledoc """
  The attempt an uploaded ATIF trace is a trajectory of.

  A trace names the attempt rather than the issue. The attempt already records
  which issue and which repository it was admitted against, so the trace
  inherits both without the issue gaining a second work record — the same shape
  `forge_assignments.work_job_id` uses to join the attempt to its execution.

  Nullable, because a trace uploaded outside an attempt is the ordinary case
  and stays exactly as portable as it was. `ON DELETE SET NULL` because the
  document is the uploader's, not the attempt's: deleting an attempt must not
  delete an account's own record of what its agent did.

  Expand-only. Nothing reads the column until the code that added it is
  running, and every existing row is `NULL`, so the constraint validates
  against no rows and a fleet mid-roll sees a column it ignores.
  """

  use Ecto.Migration

  def change do
    alter table(:traces) do
      add :assignment_id,
          references(:forge_assignments, type: :binary_id, on_delete: :nilify_all),
          null: true
    end

    create index(:traces, [:assignment_id])
  end
end
