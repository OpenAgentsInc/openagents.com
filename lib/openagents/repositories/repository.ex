defmodule OpenAgents.Repositories.Repository do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "repositories" do
    field :owner, :string
    field :name, :string
    field :owner_key, :string
    field :name_key, :string
    field :visibility, :string, default: "private"
    field :default_branch, :string, default: "main"
    field :protected_branches, {:array, :string}, default: []
    field :description, :string
    field :pull_requests_enabled, :boolean, default: true
    field :lifecycle_state, :string, default: "provisioning"
    field :provisioning_kind, :string, default: "empty"
    field :provision_error_code, :string
    field :storage_key, :string
    field :ready_at, :utc_datetime_usec
    field :upstream_url, :string
    field :upstream_license, :string

    belongs_to :namespace, OpenAgents.Repositories.Namespace
    belongs_to :created_by_user, OpenAgents.Accounts.User
    has_many :memberships, OpenAgents.Repositories.Membership
    has_one :repository_import, OpenAgents.Repositories.RepositoryImport
    has_one :provisioning_outbox, OpenAgents.Repositories.ProvisioningOutbox

    timestamps()
  end

  def changeset(repository, attrs) do
    repository
    |> cast(attrs, [
      :namespace_id,
      :owner,
      :name,
      :visibility,
      :default_branch,
      :description,
      :pull_requests_enabled,
      :lifecycle_state,
      :provisioning_kind,
      :provision_error_code,
      :storage_key,
      :ready_at
    ])
    |> validate_required([
      :namespace_id,
      :owner,
      :name,
      :visibility,
      :default_branch,
      :lifecycle_state,
      :provisioning_kind,
      :storage_key
    ])
    |> validate_inclusion(:visibility, ~w(public private))
    |> validate_inclusion(:lifecycle_state, ~w(provisioning ready failed))
    |> validate_inclusion(:provisioning_kind, ~w(empty github_import))
    |> validate_length(:owner, min: 1, max: 100)
    |> validate_length(:name, min: 1, max: 64)
    |> validate_format(:name, ~r/\A[a-z0-9](?:[a-z0-9_-]|\.(?=[a-z0-9])){0,63}\z/)
    |> validate_length(:description, max: 350)
    |> validate_length(:default_branch, min: 1, max: 255)
    |> validate_branch_name()
    |> validate_length(:provision_error_code, max: 80)
    |> normalize_path()
    |> unique_constraint([:namespace_id, :name_key])
    |> unique_constraint(:storage_key)
    |> foreign_key_constraint(:namespace_id)
    |> foreign_key_constraint(:created_by_user_id)
    |> check_constraint(:visibility, name: :repositories_visibility_check)
    |> check_constraint(:owner_key, name: :repositories_normalized_path_check)
    |> check_constraint(:lifecycle_state, name: :repositories_lifecycle_state_check)
    |> check_constraint(:provisioning_kind, name: :repositories_provisioning_kind_check)
    |> check_constraint(:ready_at, name: :repositories_ready_state_check)
    |> check_constraint(:upstream_url, name: :repositories_upstream_mirror_check)
  end

  def creation_changeset(repository, attrs, namespace, created_by_user_id, provisioning_kind) do
    storage_key = Ecto.UUID.generate()

    attrs =
      attrs
      |> Map.new()
      |> normalize_creation_name()
      |> Map.put(:namespace_id, namespace.id)
      |> Map.put(:owner, namespace.slug)
      |> Map.put_new(:visibility, "private")
      |> Map.put_new(:default_branch, "main")
      |> Map.put(:lifecycle_state, "provisioning")
      |> Map.put(:provisioning_kind, provisioning_kind)
      |> Map.put(:storage_key, storage_key)

    repository
    |> changeset(attrs)
    |> put_change(:created_by_user_id, created_by_user_id)
  end

  @doc """
  Build an upstream mirror: a repository whose content comes from a public
  source this forge does not own.

  The upstream fields are deliberately absent from `changeset/2`'s `cast`
  list and are written only here, through `put_change/3`. Caller-supplied
  attributes therefore cannot make a repository claim an upstream, and the
  ordinary import path cannot produce a mirror however its attributes are
  shaped. A mirror exists only because a caller asked this function for one.

  `license` is the upstream's SPDX identifier, or the literal `"none"` when
  the upstream publishes no license. `nil` is not accepted: the database
  constraint pairs the two columns, and a mirror that says nothing about its
  license is exactly the state this refuses to represent.
  """
  def mirror_creation_changeset(
        repository,
        attrs,
        namespace,
        created_by_user_id,
        upstream_url,
        license
      )
      when is_binary(upstream_url) and is_binary(license) do
    repository
    |> creation_changeset(attrs, namespace, created_by_user_id, "github_import")
    |> put_change(:upstream_url, upstream_url)
    |> put_change(:upstream_license, license)
    |> validate_length(:upstream_url, min: 12, max: 500)
    |> validate_format(:upstream_url, ~r{\Ahttps://[a-z0-9.-]+/[^\s]+\z})
    |> validate_length(:upstream_license, min: 1, max: 60)
  end

  @doc "Whether this repository is an upstream mirror rather than an owned repository."
  def mirror?(%__MODULE__{upstream_url: url}), do: is_binary(url)

  defp normalize_creation_name(attrs) do
    case Map.get(attrs, :name, Map.get(attrs, "name")) do
      name when is_binary(name) ->
        attrs
        |> Map.delete("name")
        |> Map.put(:name, String.downcase(name))

      _missing ->
        attrs
    end
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

  defp validate_branch_name(changeset) do
    validate_change(changeset, :default_branch, fn :default_branch, branch ->
      invalid? =
        String.starts_with?(branch, ["-", "."]) or
          String.ends_with?(branch, [".", "/", ".lock"]) or
          String.contains?(branch, ["..", "@{", "\\", " ", "~", "^", ":", "?", "*", "["])

      if invalid?, do: [default_branch: "is not a valid Git ref name"], else: []
    end)
  end
end
