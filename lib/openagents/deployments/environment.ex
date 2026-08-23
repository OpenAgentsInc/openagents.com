defmodule OpenAgents.Deployments.Environment do
  @moduledoc """
  A repository-scoped logical deployment target, such as `preview` or
  `production`.

  The environment owns the provider binding and the protection policy. It holds
  secret *references* only: the name of a secret the provider resolves at
  execution time. A durable record that carried the secret value would leak
  through every read path that returns the environment.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias OpenAgents.Deployments.Protection

  @kinds ~w(preview staging production)
  @name_pattern ~r/\A[a-z][a-z0-9-]{0,59}\z/
  @secret_reference_pattern ~r/\A[A-Z][A-Z0-9_]{0,79}\z/

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "deployment_environments" do
    field :name, :string
    field :kind, :string
    field :provider, :string
    field :provider_config, :map, default: %{}
    field :secret_references, {:array, :string}, default: []
    field :retention_days, :integer, default: 90

    embeds_one :protection, Protection, on_replace: :update

    belongs_to :repository, OpenAgents.Repositories.Repository
    belongs_to :created_by_user, OpenAgents.Accounts.User

    timestamps()
  end

  @doc false
  def changeset(environment, attrs) do
    environment
    |> cast(attrs, [
      :name,
      :kind,
      :provider,
      :provider_config,
      :secret_references,
      :retention_days
    ])
    |> cast_embed(:protection, required: true)
    |> validate_required([:name, :kind, :provider])
    |> validate_format(:name, @name_pattern)
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:provider, min: 1, max: 60)
    |> validate_number(:retention_days, greater_than: 0, less_than_or_equal_to: 3_650)
    |> validate_secret_references()
    |> validate_provider_config()
    |> unique_constraint(:name, name: :deployment_environments_repository_id_name_index)
    |> foreign_key_constraint(:repository_id)
  end

  @doc "The environment kinds a repository can define."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  defp validate_secret_references(changeset) do
    validate_change(changeset, :secret_references, fn :secret_references, references ->
      cond do
        length(references) > 20 ->
          [secret_references: "admits at most 20 references"]

        Enum.any?(references, &(not Regex.match?(@secret_reference_pattern, to_string(&1)))) ->
          [secret_references: "must name secrets in upper snake case"]

        true ->
          []
      end
    end)
  end

  # Provider configuration is tenant-authored, so it is bounded and shallow:
  # a nested document is where a secret value hides from review.
  defp validate_provider_config(changeset) do
    validate_change(changeset, :provider_config, fn :provider_config, config ->
      cond do
        not is_map(config) -> [provider_config: "must be a map"]
        map_size(config) > 20 -> [provider_config: "admits at most 20 keys"]
        not Enum.all?(config, &scalar_entry?/1) -> [provider_config: "must hold scalar values"]
        true -> []
      end
    end)
  end

  defp scalar_entry?({key, value}) when is_binary(key) do
    byte_size(key) <= 60 and scalar_value?(value)
  end

  defp scalar_entry?(_entry), do: false

  defp scalar_value?(value) when is_binary(value), do: byte_size(value) <= 500
  defp scalar_value?(value) when is_integer(value) or is_boolean(value), do: true
  defp scalar_value?(_value), do: false
end
