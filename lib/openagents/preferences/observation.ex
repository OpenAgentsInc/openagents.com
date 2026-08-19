defmodule OpenAgents.Preferences.Observation do
  @moduledoc "Immutable private evidence that may propose, but never activate, a behavior preference."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "preference_observations" do
    belongs_to :owner, OpenAgents.Conversations.Visitor, foreign_key: :owner_visitor_id
    belongs_to :source_message, OpenAgents.Conversations.Message
    field :source_kind, :string
    field :summary, :string
    field :evidence_digest, :string
    field :confidence_millis, :integer
    field :observed_at, :utc_datetime_usec
    field :freshness_until, :utc_datetime_usec
    field :proposer_id, :string
    field :proposer_digest, :string
    field :policy_id, :string
    field :policy_version, :integer
    timestamps()
  end

  def changeset(observation, attributes) do
    observation
    |> cast(attributes, [
      :owner_visitor_id,
      :source_message_id,
      :source_kind,
      :summary,
      :evidence_digest,
      :confidence_millis,
      :observed_at,
      :freshness_until,
      :proposer_id,
      :proposer_digest,
      :policy_id,
      :policy_version
    ])
    |> validate_required([
      :owner_visitor_id,
      :source_kind,
      :summary,
      :evidence_digest,
      :confidence_millis,
      :observed_at,
      :proposer_id,
      :proposer_digest,
      :policy_id,
      :policy_version
    ])
    |> validate_inclusion(:source_kind, ~w(current_user_message correction tool_outcome))
    |> validate_length(:summary, min: 1, max: 500, count: :bytes)
    |> validate_number(:confidence_millis,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 1000
    )
    |> validate_number(:policy_version, greater_than: 0)
    |> validate_format(:evidence_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:proposer_digest, ~r/\A[0-9a-f]{64}\z/)
    |> foreign_key_constraint(:owner_visitor_id)
    |> foreign_key_constraint(:source_message_id)
  end
end
