defmodule OpenAgents.Repo.Migrations.AddKindToDeviceAuthorizations do
  use Ecto.Migration

  # The `token` kind is today's only behavior: an approval mints an API token.
  # `github_connect` approvals mint nothing; they record that the approving
  # account completed the GitHub repository authorization the CLI started.
  def change do
    alter table(:device_authorizations) do
      add :kind, :string, null: false, default: "token"
    end

    create constraint(:device_authorizations, :device_authorizations_kind_check,
             check: "kind in ('token', 'github_connect')"
           )

    create index(:device_authorizations, [:kind])
  end
end
