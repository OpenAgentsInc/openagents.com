defmodule OpenAgents.Preferences.Preference do
  @moduledoc "Governed behavior preference; it contains presentation strategy, never authority."
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(candidate reviewed confirmed active suspended deleted)
  @categories ~w(presentation interaction)
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "preferences" do
    belongs_to :owner, OpenAgents.Conversations.Visitor, foreign_key: :owner_visitor_id
    belongs_to :observation, OpenAgents.Preferences.Observation
    belongs_to :supersedes, __MODULE__, foreign_key: :supersedes_preference_id
    field :category, :string
    field :effect_key, :string
    field :effect_value, :string
    field :proposed_effect, :map
    field :effect_digest, :string
    field :status, :string, default: "candidate"
    field :confidence_millis, :integer
    field :freshness_until, :utc_datetime_usec
    field :policy_id, :string
    field :policy_version, :integer
    field :generation, :integer, default: 1
    field :created_generation, :integer
    field :active_generation, :integer
    field :terminal_generation, :integer
    field :confirmation_ref, :string
    timestamps()
  end

  def create_changeset(preference, attributes) do
    preference
    |> cast(attributes, [
      :owner_visitor_id,
      :observation_id,
      :supersedes_preference_id,
      :category,
      :effect_key,
      :effect_value,
      :proposed_effect,
      :effect_digest,
      :status,
      :confidence_millis,
      :freshness_until,
      :policy_id,
      :policy_version,
      :generation,
      :created_generation,
      :active_generation,
      :terminal_generation,
      :confirmation_ref
    ])
    |> validate_required([
      :owner_visitor_id,
      :observation_id,
      :category,
      :effect_key,
      :effect_value,
      :proposed_effect,
      :effect_digest,
      :status,
      :confidence_millis,
      :policy_id,
      :policy_version,
      :generation,
      :created_generation
    ])
    |> common_validations()
    |> foreign_key_constraint(:owner_visitor_id)
    |> foreign_key_constraint(:observation_id)
  end

  def lifecycle_changeset(preference, attributes) do
    preference
    |> cast(attributes, [
      :status,
      :generation,
      :active_generation,
      :terminal_generation,
      :confirmation_ref
    ])
    |> common_validations()
  end

  defp common_validations(changeset) do
    changeset
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:category, @categories)
    |> validate_number(:confidence_millis,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 1000
    )
    |> validate_number(:policy_version, greater_than: 0)
    |> validate_number(:generation, greater_than: 0)
    |> validate_number(:created_generation, greater_than: 0)
    |> validate_format(:effect_digest, ~r/\A[0-9a-f]{64}\z/)
  end
end
