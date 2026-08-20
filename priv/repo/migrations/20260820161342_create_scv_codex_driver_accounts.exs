defmodule OpenAgents.Repo.Migrations.CreateScvCodexDriverAccounts do
  use Ecto.Migration

  def change do
    create table(:scv_driver_accounts, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :operator_id, references(:users, type: :uuid, on_delete: :restrict), null: false
      add :driver, :string, null: false
      add :credential_kind, :string, null: false
      add :label, :string, null: false
      add :status, :string, null: false
      add :secret_ref, :string, null: false
      add :credential_version, :bigint
      add :account_email, :string
      add :plan_type, :string
      add :available_models, {:array, :string}, null: false, default: []
      add :reasoning_efforts, {:array, :string}, null: false, default: []
      add :last_verified_at, :utc_datetime_usec
      add :last_error_code, :string
      add :disconnected_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:scv_driver_accounts, [:secret_ref])
    create index(:scv_driver_accounts, [:operator_id, :status])

    create constraint(:scv_driver_accounts, :scv_driver_accounts_driver_check,
             check: "driver = 'codex_app_server'"
           )

    create constraint(:scv_driver_accounts, :scv_driver_accounts_credential_kind_check,
             check: "credential_kind = 'managed_chatgpt'"
           )

    create constraint(:scv_driver_accounts, :scv_driver_accounts_status_check,
             check:
               "status IN ('pending','ready','failed','reauthentication_required','disconnected')"
           )

    create table(:scv_driver_login_attempts, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :account_id,
          references(:scv_driver_accounts, type: :uuid, on_delete: :delete_all),
          null: false

      add :operator_id, references(:users, type: :uuid, on_delete: :restrict), null: false
      add :login_id, :string
      add :status, :string, null: false
      add :verification_url, :string
      add :user_code_digest, :binary
      add :expires_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec
      add :failure_code, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:scv_driver_login_attempts, [:login_id], where: "login_id IS NOT NULL")
    create index(:scv_driver_login_attempts, [:account_id, :inserted_at])
    create index(:scv_driver_login_attempts, [:operator_id, :status])

    create constraint(:scv_driver_login_attempts, :scv_driver_login_attempts_status_check,
             check: "status IN ('starting','waiting','succeeded','failed','cancelled','expired')"
           )
  end
end
