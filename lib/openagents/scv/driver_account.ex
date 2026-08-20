defmodule OpenAgents.SCV.DriverAccount do
  @moduledoc "Restricted metadata for one operator-connected SCV driver account."

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Accounts.User
  alias OpenAgents.SCV.DriverLoginAttempt

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "scv_driver_accounts" do
    field :driver, :string, default: "codex_app_server"
    field :credential_kind, :string, default: "managed_chatgpt"
    field :label, :string
    field :status, :string, default: "pending"
    field :secret_ref, :string, redact: true
    field :credential_version, :integer
    field :account_email, :string
    field :plan_type, :string
    field :available_models, {:array, :string}, default: []
    field :reasoning_efforts, {:array, :string}, default: []
    field :last_verified_at, :utc_datetime_usec
    field :last_error_code, :string
    field :disconnected_at, :utc_datetime_usec

    belongs_to :operator, User
    has_many :login_attempts, DriverLoginAttempt, foreign_key: :account_id

    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc false
  def create_changeset(account, attributes) do
    account
    |> cast(attributes, [:id, :operator_id, :label, :secret_ref])
    |> validate_required([:operator_id, :label, :secret_ref])
    |> validate_length(:label, min: 1, max: 80)
    |> validate_length(:secret_ref, min: 1, max: 512)
    |> put_change(:driver, "codex_app_server")
    |> put_change(:credential_kind, "managed_chatgpt")
    |> put_change(:status, "pending")
    |> foreign_key_constraint(:operator_id)
    |> unique_constraint(:secret_ref)
    |> check_constraint(:driver, name: :scv_driver_accounts_driver_check)
    |> check_constraint(:credential_kind, name: :scv_driver_accounts_credential_kind_check)
    |> check_constraint(:status, name: :scv_driver_accounts_status_check)
  end

  @doc false
  def ready_changeset(account, attributes) do
    account
    |> cast(attributes, [
      :credential_version,
      :account_email,
      :plan_type,
      :available_models,
      :reasoning_efforts,
      :last_verified_at
    ])
    |> validate_required([:credential_version, :plan_type, :last_verified_at])
    |> validate_length(:account_email, max: 320)
    |> validate_length(:plan_type, min: 1, max: 80)
    |> put_change(:status, "ready")
    |> put_change(:last_error_code, nil)
    |> check_constraint(:status, name: :scv_driver_accounts_status_check)
  end

  @doc false
  def failed_changeset(account, code) when is_binary(code) do
    account
    |> change(status: "failed", last_error_code: String.slice(code, 0, 80))
    |> check_constraint(:status, name: :scv_driver_accounts_status_check)
  end
end
