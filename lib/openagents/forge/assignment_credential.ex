defmodule OpenAgents.Forge.AssignmentCredential do
  @moduledoc "Digest-only short-lived credential for one forge assignment."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "forge_assignment_credentials" do
    belongs_to :assignment, OpenAgents.Forge.Assignment
    field :token_digest, :binary, redact: true
    field :last_four, :string
    field :repository_id, :binary_id
    field :branch, :string
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [:token_digest, :last_four, :repository_id, :branch, :expires_at, :revoked_at])
    |> put_programmatic(attrs, :assignment_id)
    |> validate_required([
      :assignment_id,
      :token_digest,
      :last_four,
      :repository_id,
      :branch,
      :expires_at
    ])
    |> validate_length(:branch, max: 255)
    |> validate_length(:last_four, is: 4)
    |> foreign_key_constraint(:assignment_id)
    |> unique_constraint(:token_digest)
  end

  defp put_programmatic(changeset, attrs, field) do
    case Map.fetch(attrs, field) do
      {:ok, value} -> put_change(changeset, field, value)
      :error -> changeset
    end
  end
end
