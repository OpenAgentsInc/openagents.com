defmodule OpenAgents.GraphMemory.CascadePlan do
  @moduledoc "An inspectable exact-generation impact plan for source deletion."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "graph_cascade_plans" do
    field :owner_visitor_id, :binary_id
    field :work_scope, :string
    field :manifest_id, :binary_id
    field :source_ref, :string
    field :source_snapshot_digest, :string
    field :artifact_ids, {:array, :string}
    field :node_count, :integer
    field :edge_count, :integer
    field :plan_digest, :string
    field :status, :string
    field :applied_at, :utc_datetime_usec
    timestamps()
  end

  def create_changeset(row, attrs),
    do:
      row
      |> cast(attrs, [
        :owner_visitor_id,
        :work_scope,
        :manifest_id,
        :source_ref,
        :source_snapshot_digest,
        :artifact_ids,
        :node_count,
        :edge_count,
        :plan_digest,
        :status
      ])
      |> validate_required([
        :owner_visitor_id,
        :work_scope,
        :manifest_id,
        :source_ref,
        :source_snapshot_digest,
        :artifact_ids,
        :node_count,
        :edge_count,
        :plan_digest,
        :status
      ])

  def apply_changeset(row, attrs), do: cast(row, attrs, [:status, :applied_at])
end
