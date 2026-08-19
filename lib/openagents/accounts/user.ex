defmodule OpenAgents.Accounts.User do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "users" do
    field :github_id, :integer
    field :github_login, :string
    field :github_name, :string
    field :github_avatar_url, :string
    field :status, :string, default: "active"
    field :banned_at, :utc_datetime_usec
    field :ban_reason_code, :string
    field :last_authenticated_at, :utc_datetime_usec
    field :github_token_ciphertext, :binary, redact: true

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          github_id: pos_integer(),
          github_login: String.t(),
          github_name: String.t() | nil,
          github_avatar_url: String.t(),
          status: String.t(),
          banned_at: DateTime.t() | nil,
          ban_reason_code: String.t() | nil,
          last_authenticated_at: DateTime.t() | nil,
          github_token_ciphertext: binary() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  def github_changeset(user, attributes) do
    user
    |> cast(attributes, [
      :github_id,
      :github_login,
      :github_name,
      :github_avatar_url,
      :last_authenticated_at
    ])
    |> validate_required([
      :github_id,
      :github_login,
      :github_avatar_url,
      :last_authenticated_at
    ])
    |> validate_number(:github_id, greater_than: 0)
    |> validate_length(:github_login, min: 1, max: 39)
    |> validate_length(:github_name, max: 255)
    |> validate_format(:github_login, ~r/\A[A-Za-z0-9][A-Za-z0-9-]*\z/)
    |> validate_avatar_url()
    |> unique_constraint(:github_id)
  end

  defp validate_avatar_url(changeset) do
    validate_change(changeset, :github_avatar_url, fn :github_avatar_url, value ->
      case URI.new(value) do
        {:ok, %URI{scheme: "https", host: "avatars.githubusercontent.com"}} ->
          []

        _invalid ->
          [github_avatar_url: "must be an HTTPS GitHub avatar URL"]
      end
    end)
  end
end
