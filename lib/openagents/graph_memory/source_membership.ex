defmodule OpenAgents.GraphMemory.SourceMembership do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]
  schema "graph_source_memberships" do
    field :manifest_id, :binary_id
    field :artifact_id, :string
    field :owner_visitor_id, :binary_id
    field :work_scope, :string
    field :source_kind, :string
    field :source_ref, :string
    field :source_digest, :string
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
        :source_kind,
        :source_ref,
        :source_digest
      ])
      |> validate_required([
        :manifest_id,
        :artifact_id,
        :owner_visitor_id,
        :work_scope,
        :source_kind,
        :source_ref,
        :source_digest
      ])
      |> validate_inclusion(:source_kind, ~w(experience_record experience_pattern))
end
