defmodule OpenAgents.Repo.Migrations.AddChainLinkToForgePushes do
  use Ecto.Migration

  # A push receipt now carries the WAL chain link of the entry it derives
  # from (`EXIT-005`). The column is a projection of the log and never a
  # second authority: it is written from the entry and re-derived from the
  # entries by `OpenAgents.Forge.Pushes.reconcile_receipts/1`, and no code
  # path reads it to decide anything.
  #
  # Nullable, and no backfill. A receipt derived from an entry written before
  # the chain existed has no link to carry, and a link the operator computes
  # over entries the operator holds proves nothing. `NULL` reads as "this
  # entry predates the chain", which is what `verify/2` reports as
  # `chained_from`.
  def change do
    alter table(:forge_pushes) do
      add :link, :string
    end
  end
end
