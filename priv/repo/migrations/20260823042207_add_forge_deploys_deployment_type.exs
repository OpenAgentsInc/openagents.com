defmodule OpenAgents.Repo.Migrations.AddForgeDeploysDeploymentType do
  use Ecto.Migration

  # Nullable on purpose: receipts are immutable (no backfill), so rows written
  # before this column render an honest "unknown" type rather than a guess.
  def change do
    alter table(:forge_deploys) do
      add :deployment_type, :string
    end

    create constraint(:forge_deploys, :forge_deploys_deployment_type,
             check:
               "deployment_type IS NULL OR deployment_type IN ('direct_load', 'relup', 'rolling_replacement')"
           )
  end
end
