defmodule OpenAgents.Transparency.ArtifactLink do
  @moduledoc """
  A durable link between an artifact, the account and repository that own it,
  and a transparency tier. The link is the consent-bearing record for any
  public disclosure of the artifact.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @artifact_types ~w(changelog release issue build)
  @artifact_refs ~w(sha tag digest path)
  @tiers ~w(dark pulse ledger glass)

  schema "artifact_links" do
    field :account_id, :binary_id
    field :repository_id, :binary_id
    field :artifact_type, :string
    field :artifact_ref, :string
    field :tier, :string
    field :consent, :map, default: %{}
    field :authority_snapshot, :map, default: %{}
    field :revoked_at, :utc_datetime_usec
    field :revocation_tombstone, :map, default: %{}
    timestamps(updated_at: false)
  end

  def artifact_types, do: @artifact_types
  def artifact_refs, do: @artifact_refs
  def tiers, do: @tiers

  def changeset(artifact_link, attrs) do
    artifact_link
    |> cast(attrs, [
      :account_id,
      :repository_id,
      :artifact_type,
      :artifact_ref,
      :tier,
      :consent,
      :authority_snapshot
    ])
    |> validate_required([
      :account_id,
      :repository_id,
      :artifact_type,
      :artifact_ref,
      :tier
    ])
    |> validate_inclusion(:artifact_type, @artifact_types)
    |> validate_inclusion(:artifact_ref, @artifact_refs)
    |> validate_inclusion(:tier, @tiers)
  end
end
