defmodule OpenAgents.Repositories.NamespaceAlias do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "namespace_aliases" do
    field :slug, :string
    field :slug_key, :string
    belongs_to :namespace, OpenAgents.Repositories.Namespace
    timestamps()
  end

  def changeset(namespace_alias, namespace_id, slug) do
    namespace_alias
    |> change()
    |> put_change(:namespace_id, namespace_id)
    |> put_change(:slug, slug)
    |> put_change(:slug_key, String.downcase(slug))
    |> validate_required([:namespace_id, :slug, :slug_key])
    |> validate_length(:slug, min: 1, max: 100)
    |> unique_constraint(:slug_key)
    |> foreign_key_constraint(:namespace_id)
    |> check_constraint(:slug_key, name: :namespace_aliases_normalized_slug_check)
  end
end
