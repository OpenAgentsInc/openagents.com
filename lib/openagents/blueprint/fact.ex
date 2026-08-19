defmodule OpenAgents.Blueprint.Fact do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "sarah_blueprint_facts" do
    belongs_to :revision, OpenAgents.Blueprint.Revision
    field :fact_id, :string
    field :section, :string
    field :value_type, :string
    field :typed_value, :map
    field :source_type, :string
    field :source_ref, :string
    field :source_status, :string
    field :source_observed_at, :utc_datetime_usec
    field :source_digest, :string
    field :introduced_revision, :string
    field :retired_revision, :string
    field :compatibility_min, :integer
    field :compatibility_max, :integer
    field :capability_ref, :string
    field :promise_ref, :string
    field :author, :string
    field :reason, :string
    field :receipt, :map, default: %{}
    timestamps()
  end

  def changeset(fact, attributes) do
    fact
    |> cast(attributes, [
      :fact_id,
      :section,
      :value_type,
      :typed_value,
      :source_type,
      :source_ref,
      :source_status,
      :source_observed_at,
      :source_digest,
      :introduced_revision,
      :retired_revision,
      :compatibility_min,
      :compatibility_max,
      :capability_ref,
      :promise_ref,
      :author,
      :reason,
      :receipt
    ])
    |> validate_required([
      :revision_id,
      :fact_id,
      :section,
      :value_type,
      :typed_value,
      :source_type,
      :source_ref,
      :source_status,
      :source_observed_at,
      :source_digest,
      :introduced_revision,
      :compatibility_min,
      :compatibility_max,
      :author,
      :reason,
      :receipt
    ])
    |> validate_inclusion(
      :section,
      ~w(identity voice vocabulary roles product_truths rules examples)
    )
    |> validate_inclusion(:value_type, ~w(text terms role example))
    |> validate_inclusion(
      :source_type,
      ~w(repository_document release_artifact persona_source founder_direction)
    )
    |> validate_inclusion(:source_status, ~w(admitted binding historical_evidence))
    |> validate_format(:source_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_number(:compatibility_min, greater_than: 0)
    |> validate_length(:fact_id, min: 1, max: 160)
    |> validate_length(:source_ref, min: 1, max: 1_000)
    |> validate_length(:author, min: 1, max: 200)
    |> validate_length(:reason, min: 1, max: 2_000)
    |> foreign_key_constraint(:revision_id)
    |> unique_constraint([:revision_id, :fact_id])
  end
end
