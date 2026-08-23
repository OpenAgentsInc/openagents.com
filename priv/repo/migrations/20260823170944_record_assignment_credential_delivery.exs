defmodule OpenAgents.Repo.Migrations.RecordAssignmentCredentialDelivery do
  use Ecto.Migration

  def up do
    alter table(:forge_assignments) do
      add :credential_delivery_status, :string, null: false, default: "not_applicable"
      add :credential_delivery_reason, :string
    end
  end

  def down do
    alter table(:forge_assignments) do
      remove :credential_delivery_reason
      remove :credential_delivery_status
    end
  end
end
