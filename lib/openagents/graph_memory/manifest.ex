defmodule OpenAgents.GraphMemory.Manifest do
  @moduledoc "A generation-pinned derived graph build; never memory authority."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]
  schema "graph_manifests" do
    belongs_to :owner, OpenAgents.Conversations.Visitor, foreign_key: :owner_visitor_id
    field :work_scope, :string
    field :generation, :integer
    field :status, :string
    field :policy_id, :string
    field :policy_version, :integer
    field :source_snapshot_digest, :string
    field :build_digest, :string
    field :node_count, :integer, default: 0
    field :edge_count, :integer, default: 0
    field :failure_code, :string
    field :built_at, :utc_datetime_usec
    timestamps()
  end

  def create_changeset(row, attrs),
    do:
      row
      |> cast(attrs, [
        :owner_visitor_id,
        :work_scope,
        :generation,
        :status,
        :policy_id,
        :policy_version,
        :source_snapshot_digest,
        :node_count,
        :edge_count
      ])
      |> validate_required([
        :owner_visitor_id,
        :work_scope,
        :generation,
        :status,
        :policy_id,
        :policy_version,
        :source_snapshot_digest
      ])
      |> validate_inclusion(:status, ~w(building current retired failed))

  def transition_changeset(row, attrs),
    do:
      cast(row, attrs, [
        :status,
        :build_digest,
        :node_count,
        :edge_count,
        :failure_code,
        :built_at
      ])
end
