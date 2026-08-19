defmodule OpenAgents.Memory.SemanticManifest do
  @moduledoc "Versioned rebuild manifest for disposable semantic recall derivatives."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "semantic_index_manifests" do
    field :generation, :integer
    field :model_id, :string
    field :model_version, :string
    field :dimensions, :integer
    field :ranking_policy_id, :string
    field :ranking_policy_version, :integer
    field :manifest_digest, :string
    field :status, :string
    timestamps()
  end

  def changeset(record, attributes) do
    record
    |> cast(
      attributes,
      ~w(generation model_id model_version dimensions ranking_policy_id ranking_policy_version manifest_digest status)a
    )
    |> validate_required(
      ~w(generation model_id model_version dimensions ranking_policy_id ranking_policy_version manifest_digest status)a
    )
    |> validate_inclusion(:status, ~w(active retired))
    |> validate_number(:generation, greater_than: 0)
    |> validate_number(:dimensions, equal_to: 64)
    |> validate_number(:ranking_policy_version, greater_than: 0)
    |> validate_format(:manifest_digest, ~r/\A[0-9a-f]{64}\z/)
    |> unique_constraint(:generation)
  end
end
