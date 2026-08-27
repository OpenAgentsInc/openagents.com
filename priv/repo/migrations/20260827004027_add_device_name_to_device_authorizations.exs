defmodule OpenAgents.Repo.Migrations.AddDeviceNameToDeviceAuthorizations do
  use Ecto.Migration

  def change do
    alter table(:device_authorizations) do
      add :device_name, :string, size: 80
    end
  end
end
