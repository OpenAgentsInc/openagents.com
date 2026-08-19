defmodule OpenAgents.ExperienceMemory.Bank do
  @moduledoc "Frozen deterministic experience selection for one turn."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]
  schema "experience_banks" do
    belongs_to :turn, OpenAgents.Conversations.Turn
    belongs_to :owner, OpenAgents.Conversations.Visitor, foreign_key: :owner_visitor_id
    belongs_to :scope, OpenAgents.ExperienceMemory.Scope
    field :work_scope, :string
    field :scope_generation, :integer
    field :query_digest, :string
    field :bank_digest, :string
    field :status, :string, default: "frozen"
    field :selected_record_refs, {:array, :string}, default: []
    field :selected_pattern_refs, {:array, :string}, default: []
    field :dropped_refs, {:array, :string}, default: []
    field :used_bytes, :integer
    field :frozen_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(bank, attrs),
    do:
      bank
      |> cast(attrs, [
        :turn_id,
        :owner_visitor_id,
        :scope_id,
        :work_scope,
        :scope_generation,
        :query_digest,
        :bank_digest,
        :status,
        :selected_record_refs,
        :selected_pattern_refs,
        :dropped_refs,
        :used_bytes,
        :frozen_at,
        :inserted_at
      ])
      |> validate_required([
        :turn_id,
        :owner_visitor_id,
        :scope_id,
        :work_scope,
        :scope_generation,
        :query_digest,
        :bank_digest,
        :status,
        :used_bytes,
        :frozen_at,
        :inserted_at
      ])
      |> validate_inclusion(:status, ~w(frozen invalidated))
      |> validate_format(:query_digest, ~r/\A[0-9a-f]{64}\z/)
      |> validate_format(:bank_digest, ~r/\A[0-9a-f]{64}\z/)
end
