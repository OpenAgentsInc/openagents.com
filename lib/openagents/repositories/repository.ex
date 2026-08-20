defmodule OpenAgents.Repositories.Repository do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "repositories" do
    field :owner, :string
    field :name, :string
    field :owner_key, :string
    field :name_key, :string
    field :visibility, :string, default: "private"
    field :default_branch, :string, default: "main"

    has_many :memberships, OpenAgents.Repositories.Membership

    timestamps()
  end

  def changeset(repository, attrs) do
    repository
    |> cast(attrs, [:owner, :name, :visibility, :default_branch])
    |> validate_required([:owner, :name, :visibility, :default_branch])
    |> validate_inclusion(:visibility, ~w(public private))
    |> validate_length(:owner, min: 1, max: 100)
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:default_branch, min: 1, max: 255)
    |> normalize_path()
    |> unique_constraint([:owner_key, :name_key])
    |> check_constraint(:visibility, name: :repositories_visibility_check)
    |> check_constraint(:owner_key, name: :repositories_normalized_path_check)
  end

  defp normalize_path(changeset) do
    owner = get_field(changeset, :owner)
    name = get_field(changeset, :name)

    changeset
    |> maybe_put_key(:owner_key, owner)
    |> maybe_put_key(:name_key, name)
  end

  defp maybe_put_key(changeset, _field, value) when not is_binary(value), do: changeset

  defp maybe_put_key(changeset, field, value) do
    put_change(changeset, field, String.downcase(value))
  end
end
