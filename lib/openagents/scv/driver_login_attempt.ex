defmodule OpenAgents.SCV.DriverLoginAttempt do
  @moduledoc "Durable, credential-free state for one SCV Codex device login."

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Accounts.User
  alias OpenAgents.SCV.DriverAccount

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "scv_driver_login_attempts" do
    field :login_id, :string
    field :status, :string, default: "starting"
    field :verification_url, :string
    field :user_code_digest, :binary, redact: true
    field :expires_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :failure_code, :string

    belongs_to :account, DriverAccount
    belongs_to :operator, User

    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc false
  def create_changeset(attempt, attributes) do
    attempt
    |> cast(attributes, [:account_id, :operator_id, :expires_at])
    |> validate_required([:account_id, :operator_id, :expires_at])
    |> put_change(:status, "starting")
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:operator_id)
    |> check_constraint(:status, name: :scv_driver_login_attempts_status_check)
  end

  @doc false
  def waiting_changeset(attempt, attributes) do
    attempt
    |> cast(attributes, [:login_id, :verification_url, :user_code_digest])
    |> validate_required([:login_id, :verification_url, :user_code_digest])
    |> validate_change(:verification_url, &validate_verification_url/2)
    |> put_change(:status, "waiting")
    |> unique_constraint(:login_id)
    |> check_constraint(:status, name: :scv_driver_login_attempts_status_check)
  end

  @doc false
  def terminal_changeset(attempt, status, failure_code \\ nil)
      when status in ["succeeded", "failed", "cancelled", "expired"] do
    attempt
    |> change(
      status: status,
      failure_code: failure_code,
      completed_at: DateTime.utc_now()
    )
    |> check_constraint(:status, name: :scv_driver_login_attempts_status_check)
  end

  defp validate_verification_url(:verification_url, value) do
    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: "auth.openai.com", path: "/codex/device"}} -> []
      _invalid -> [verification_url: "must be the Codex device verification URL"]
    end
  end
end
