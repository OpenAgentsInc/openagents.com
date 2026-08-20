defmodule OpenAgents.Repo.Migrations.AddCliDeviceAuthorizations do
  use Ecto.Migration

  def change do
    create table(:device_authorizations, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :device_code_digest, :binary, null: false
      add :user_code_digest, :binary, null: false
      add :state, :string, null: false, default: "pending"
      add :scopes, {:array, :string}, null: false, default: ["forge:write"]
      add :interval_seconds, :integer, null: false, default: 5
      add :poll_count, :integer, null: false, default: 0
      add :last_polled_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec, null: false
      add :approved_at, :utc_datetime_usec
      add :denied_at, :utc_datetime_usec
      add :claimed_at, :utc_datetime_usec

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)

      add :api_token_id,
          references(:api_tokens, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:device_authorizations, [:device_code_digest])
    create unique_index(:device_authorizations, [:user_code_digest])
    create index(:device_authorizations, [:expires_at])

    create constraint(:device_authorizations, :device_authorizations_state_check,
             check: "state IN ('pending', 'approved', 'denied', 'claimed')"
           )

    create constraint(:device_authorizations, :device_authorizations_interval_check,
             check: "interval_seconds BETWEEN 1 AND 30"
           )

    create constraint(:device_authorizations, :device_authorizations_poll_count_check,
             check: "poll_count >= 0"
           )
  end
end
