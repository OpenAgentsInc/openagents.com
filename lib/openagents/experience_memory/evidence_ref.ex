defmodule OpenAgents.ExperienceMemory.EvidenceRef do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]
  schema "experience_evidence_refs" do
    belongs_to :record, OpenAgents.ExperienceMemory.Record
    field :owner_visitor_id, :binary_id
    field :work_scope, :string
    field :kind, :string
    field :reference, :string
    field :reference_digest, :string
    timestamps()
  end

  def changeset(ref, attrs),
    do:
      ref
      |> cast(attrs, [
        :record_id,
        :owner_visitor_id,
        :work_scope,
        :kind,
        :reference,
        :reference_digest
      ])
      |> validate_required([
        :record_id,
        :owner_visitor_id,
        :work_scope,
        :kind,
        :reference,
        :reference_digest
      ])
      |> validate_inclusion(:kind, ~w(source trace target correction))
      |> validate_format(:reference_digest, ~r/\A[0-9a-f]{64}\z/)
end
