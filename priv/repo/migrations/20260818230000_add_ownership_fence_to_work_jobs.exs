defmodule Sarah.Repo.Migrations.AddOwnershipFenceToWorkJobs do
  use Ecto.Migration

  # M1: a job is a cluster-wide singleton that can relocate to a survivor when
  # its node dies. Two columns support that:
  #
  #   * owner_node  — which BEAM node currently drives the job (observability +
  #     "is my owner still alive"); set on every claim.
  #   * generation  — a monotonic fence bumped on every claim. A relocated
  #     instance bumps it; the linearizable Postgres row is the authority, so a
  #     stale (lower-generation) zombie can be fenced out of terminal writes.
  #
  # Both live outside the identity ROW and the terminal-immutable ROW that the
  # existing transition trigger guards, so claiming/adopting a running job
  # (running -> running, allowed by the trigger) does not trip them.
  def change do
    alter table(:work_jobs) do
      add :owner_node, :string
      add :generation, :integer, null: false, default: 0
    end
  end
end
