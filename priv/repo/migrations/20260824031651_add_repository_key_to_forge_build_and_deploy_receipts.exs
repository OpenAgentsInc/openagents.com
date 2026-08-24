defmodule OpenAgents.Repo.Migrations.AddRepositoryKeyToForgeBuildAndDeployReceipts do
  use Ecto.Migration

  @moduledoc """
  Names the repository a build or deploy receipt belongs to.

  `forge_builds.repo` and `forge_deploys.repo` hold `Target.repo`, which
  `OpenAgents.Forge.Targets` constrains to a member of `:forge_repos` — a
  repository *name*, or `owner/name`. `repositories` is unique on
  `{namespace_id, name_key}` rather than on `name`, so two repositories can
  answer to one receipt string, and `OpenAgents.Issues.Evidence` records no
  evidence at all when they do.

  `forge_pushes.repo` is deliberately left alone. It holds
  `Repository.storage_key`, which carries a unique index, so it already names
  exactly one repository. Adding a key there would buy no disambiguation and
  would cost something: `EXIT-003` requires every `forge_pushes` column to be
  re-derivable from the WAL by `Pushes.reconcile_receipts/1`, and a column only
  PostgreSQL can produce would make the database a second opinion about a push
  record the WAL alone decides.

  The backfill statement itself lives in
  `OpenAgents.Forge.ReceiptRepository.backfill!/1` rather than inline here, so
  the rule it applies is proven by a test rather than asserted by a comment. It
  resolves a name only when exactly one repository answers to it.
  A row it cannot settle keeps a null key and stays readable by its string. A
  null here means "not settled", never "no repository", and no row is attached
  to a guess.

  `forge_deploys` carries the `forge_deploy_receipts_immutable` trigger, which
  refuses every `UPDATE`. The backfill suspends it for the length of this
  migration's transaction and restores it in the same transaction. What the
  backfill writes is a derived key beside the receipt, not a change to anything
  the receipt claims: `repo`, `sha`, `result`, the digests, and the node results
  are untouched.
  """

  def up do
    alter table(:forge_builds) do
      add :repository_id, references(:repositories, type: :binary_id, on_delete: :nothing)
    end

    alter table(:forge_deploys) do
      add :repository_id, references(:repositories, type: :binary_id, on_delete: :nothing)
    end

    create index(:forge_builds, [:repository_id, :sha])
    create index(:forge_deploys, [:repository_id, :sha])

    flush()

    OpenAgents.Forge.ReceiptRepository.backfill!("forge_builds")

    repo().query!("ALTER TABLE forge_deploys DISABLE TRIGGER forge_deploy_receipts_immutable")
    OpenAgents.Forge.ReceiptRepository.backfill!("forge_deploys")
    repo().query!("ALTER TABLE forge_deploys ENABLE TRIGGER forge_deploy_receipts_immutable")
  end

  def down do
    drop index(:forge_builds, [:repository_id, :sha])
    drop index(:forge_deploys, [:repository_id, :sha])

    alter table(:forge_builds) do
      remove :repository_id
    end

    alter table(:forge_deploys) do
      remove :repository_id
    end
  end
end
