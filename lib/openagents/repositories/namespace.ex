defmodule OpenAgents.Repositories.Namespace do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]
  @reserved_slugs ~w(
    admin api assets auth changelog chat components computers controller data dev device docs git og
    health healthz leaderboard machines memory repositories settings status voice
  )

  def reserved_slugs, do: @reserved_slugs

  schema "namespaces" do
    field :provider, :string, default: "github"
    field :provider_account_id, :integer
    field :provider_node_id, :string
    field :slug, :string
    field :slug_key, :string
    field :kind, :string
    field :provider_refreshed_at, :utc_datetime_usec
    field :state, :string, default: "active"

    belongs_to :owner_user, OpenAgents.Accounts.User
    has_many :aliases, OpenAgents.Repositories.NamespaceAlias
    has_many :repositories, OpenAgents.Repositories.Repository

    timestamps()
  end

  def changeset(namespace, attrs) do
    namespace
    |> cast(attrs, [
      :provider_account_id,
      :provider_node_id,
      :slug,
      :kind,
      :owner_user_id,
      :provider_refreshed_at,
      :state
    ])
    |> put_change(:provider, "github")
    |> validate_required([
      :provider,
      :provider_account_id,
      :slug,
      :kind,
      :provider_refreshed_at,
      :state
    ])
    |> validate_number(:provider_account_id, greater_than: 0)
    |> validate_inclusion(:kind, ~w(user organization))
    |> validate_inclusion(:state, ~w(active suspended retired))
    |> validate_length(:slug, min: 1, max: 100)
    |> validate_length(:provider_node_id, max: 100)
    |> validate_format(:slug, ~r/\A[A-Za-z0-9][A-Za-z0-9-]*\z/)
    |> normalize_slug()
    |> validate_exclusion(:slug_key, @reserved_slugs)
    |> validate_owner_kind()
    |> unique_constraint([:provider, :provider_account_id, :kind])
    |> unique_constraint(:slug_key, name: :namespaces_active_slug_key_index)
    |> foreign_key_constraint(:owner_user_id)
    |> check_constraint(:kind, name: :namespaces_kind_check)
    |> check_constraint(:state, name: :namespaces_state_check)
    |> check_constraint(:slug_key, name: :namespaces_normalized_slug_check)
    |> check_constraint(:owner_user_id, name: :namespaces_owner_kind_check)
  end

  defp normalize_slug(changeset) do
    case get_field(changeset, :slug) do
      slug when is_binary(slug) -> put_change(changeset, :slug_key, String.downcase(slug))
      _missing -> changeset
    end
  end

  defp validate_owner_kind(changeset) do
    case {get_field(changeset, :kind), get_field(changeset, :owner_user_id)} do
      {"user", owner_user_id} when is_binary(owner_user_id) ->
        changeset

      {"organization", nil} ->
        changeset

      {"user", _missing} ->
        add_error(changeset, :owner_user_id, "is required for a user namespace")

      {"organization", _present} ->
        add_error(changeset, :owner_user_id, "must be empty for an organization namespace")

      _invalid ->
        changeset
    end
  end
end
