defmodule OpenAgents.GraphMemory.OutboxEvent do
  @moduledoc "A transactionally emitted source mutation awaiting a graph generation."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "graph_mutation_outbox" do
    field :owner_visitor_id, :binary_id
    field :work_scope, :string
    field :source_kind, :string
    field :source_ref, :string
    field :source_generation, :integer
    field :source_digest, :string
    field :operation, :string
    field :status, :string
    field :consumed_manifest_id, :binary_id
    field :consumed_at, :utc_datetime_usec
    timestamps()
  end

  def consume_changeset(row, attrs),
    do:
      row
      |> cast(attrs, [:status, :consumed_manifest_id, :consumed_at])
      |> validate_required([:status, :consumed_manifest_id, :consumed_at])
      |> validate_inclusion(:status, ["consumed"])
end
