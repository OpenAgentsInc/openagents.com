defmodule OpenAgents.ExperienceMemory.Record do
  @moduledoc "Private per-case work experience; never a profile fact or authority grant."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]
  schema "experience_records" do
    belongs_to :owner, OpenAgents.Conversations.Visitor, foreign_key: :owner_visitor_id
    belongs_to :scope, OpenAgents.ExperienceMemory.Scope
    belongs_to :supersedes, __MODULE__, foreign_key: :supersedes_record_id
    field :work_scope, :string
    field :objective, :string
    field :approach, :string
    field :outcome_state, :string
    field :outcome, :string
    field :correction, :string
    field :applicability, :string
    field :confidence_millis, :integer
    field :retention_until, :utc_datetime_usec
    field :policy_id, :string
    field :policy_version, :integer
    field :content_digest, :string
    field :generation, :integer, default: 1
    field :scope_generation, :integer
    timestamps()
  end

  def create_changeset(record, attrs),
    do:
      record
      |> cast(attrs, fields())
      |> validate_required([
        :owner_visitor_id,
        :scope_id,
        :work_scope,
        :objective,
        :approach,
        :outcome_state,
        :applicability,
        :confidence_millis,
        :policy_id,
        :policy_version,
        :content_digest,
        :generation,
        :scope_generation
      ])
      |> common()

  def lifecycle_changeset(record, attrs),
    do:
      record
      |> cast(attrs, [:outcome_state, :outcome, :correction, :generation, :scope_generation])
      |> common()

  defp fields,
    do: [
      :owner_visitor_id,
      :scope_id,
      :supersedes_record_id,
      :work_scope,
      :objective,
      :approach,
      :outcome_state,
      :outcome,
      :correction,
      :applicability,
      :confidence_millis,
      :retention_until,
      :policy_id,
      :policy_version,
      :content_digest,
      :generation,
      :scope_generation
    ]

  defp common(changeset),
    do:
      changeset
      |> validate_inclusion(:outcome_state, ~w(requested running succeeded failed corrected))
      |> validate_number(:confidence_millis,
        greater_than_or_equal_to: 0,
        less_than_or_equal_to: 1000
      )
      |> validate_format(:content_digest, ~r/\A[0-9a-f]{64}\z/)
end
