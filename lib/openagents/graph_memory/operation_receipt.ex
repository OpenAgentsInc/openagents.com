defmodule OpenAgents.GraphMemory.OperationReceipt do
  @moduledoc "Append-only graph rebuild, replay, cascade, or drop evidence."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]
  schema "graph_operation_receipts" do
    field :owner_visitor_id, :binary_id
    field :work_scope, :string
    field :operation, :string
    field :manifest_ref, :string
    field :plan_ref, :string
    field :source_snapshot_digest, :string
    field :deleted_node_count, :integer
    field :deleted_edge_count, :integer
    field :receipt_digest, :string
    timestamps()
  end

  def changeset(row, attrs),
    do:
      row
      |> cast(attrs, [
        :owner_visitor_id,
        :work_scope,
        :operation,
        :manifest_ref,
        :plan_ref,
        :source_snapshot_digest,
        :deleted_node_count,
        :deleted_edge_count,
        :receipt_digest
      ])
      |> validate_required([
        :owner_visitor_id,
        :work_scope,
        :operation,
        :source_snapshot_digest,
        :deleted_node_count,
        :deleted_edge_count,
        :receipt_digest
      ])
      |> validate_inclusion(:operation, ~w(rebuild replay recover cascade drop))
end
