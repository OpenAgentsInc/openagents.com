defmodule OpenAgents.GraphMemory.Artifact do
  @moduledoc "An immutable derived node or edge."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key false
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]
  schema "graph_artifacts" do
    field :manifest_id, :binary_id, primary_key: true
    field :artifact_id, :string, primary_key: true
    field :owner_visitor_id, :binary_id
    field :work_scope, :string
    field :kind, :string
    field :entity_kind, :string
    field :identity_key, :string
    field :version_key, :string
    field :conflict_key, :string
    field :source_node_id, :string
    field :target_node_id, :string
    field :predicate, :string
    field :properties, :map
    field :artifact_digest, :string
    timestamps()
  end

  def changeset(row, attrs),
    do:
      row
      |> cast(attrs, [
        :manifest_id,
        :artifact_id,
        :owner_visitor_id,
        :work_scope,
        :kind,
        :entity_kind,
        :identity_key,
        :version_key,
        :conflict_key,
        :source_node_id,
        :target_node_id,
        :predicate,
        :properties,
        :artifact_digest
      ])
      |> validate_required([
        :manifest_id,
        :artifact_id,
        :owner_visitor_id,
        :work_scope,
        :kind,
        :properties,
        :artifact_digest
      ])
      |> validate_inclusion(:kind, ~w(node edge))
end
