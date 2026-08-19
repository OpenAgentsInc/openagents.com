defmodule OpenAgents.ProfileMemory.Record do
  @moduledoc "One source-linked, browser-owned durable profile claim and its lifecycle state."

  use Ecto.Schema
  import Ecto.Changeset

  @categories ~w(name role project preference constraint other)
  @statuses ~w(candidate active superseded forgotten expired)
  @creators ~w(user_explicit model_proposal admin_migration)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "profile_memory_records" do
    belongs_to :owner_visitor, OpenAgents.Conversations.Visitor
    field :schema_version, :integer, default: 1
    field :category, :string
    field :claim, :string
    field :claim_fingerprint, :binary
    field :status, :string, default: "candidate"
    field :provenance, :map, default: %{}
    field :confidence, :decimal
    field :valid_from, :utc_datetime_usec
    field :valid_until, :utc_datetime_usec
    field :confirmed_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :owner_asserted_at, :utc_datetime_usec
    field :redaction_policy, :string
    field :policy_version, :string
    field :creator, :string
    field :creator_artifact_id, :string
    field :creator_artifact_digest, :string
    field :generation, :integer, default: 1
    field :created_generation, :integer
    field :active_generation, :integer
    field :terminal_generation, :integer
    belongs_to :supersedes_record, __MODULE__
    has_many :sources, OpenAgents.ProfileMemory.Source, foreign_key: :memory_record_id
    timestamps()
  end

  @type t :: %__MODULE__{}

  def create_changeset(record, attributes) do
    record
    |> cast(attributes, [
      :owner_visitor_id,
      :schema_version,
      :category,
      :claim,
      :claim_fingerprint,
      :status,
      :provenance,
      :confidence,
      :valid_from,
      :valid_until,
      :confirmed_at,
      :expires_at,
      :owner_asserted_at,
      :redaction_policy,
      :policy_version,
      :creator,
      :creator_artifact_id,
      :creator_artifact_digest,
      :generation,
      :created_generation,
      :active_generation,
      :terminal_generation,
      :supersedes_record_id
    ])
    |> validate_required([
      :owner_visitor_id,
      :schema_version,
      :category,
      :claim,
      :claim_fingerprint,
      :status,
      :provenance,
      :confidence,
      :redaction_policy,
      :policy_version,
      :creator,
      :generation,
      :created_generation
    ])
    |> validate_inclusion(:category, @categories)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:creator, @creators)
    |> validate_length(:claim, max: 500)
    |> validate_length(:redaction_policy, max: 100)
    |> validate_number(:confidence, greater_than_or_equal_to: 0, less_than_or_equal_to: 1)
    |> foreign_key_constraint(:owner_visitor_id)
    |> foreign_key_constraint(:supersedes_record_id)
    |> unique_constraint([:owner_visitor_id, :category, :claim_fingerprint],
      name: :profile_memory_records_active_claim_index
    )
    |> unique_constraint([:owner_visitor_id, :category],
      name: :profile_memory_records_active_singleton_index
    )
  end

  def transition_changeset(record, attributes) do
    record
    |> cast(attributes, [
      :status,
      :active_generation,
      :terminal_generation,
      :confirmed_at,
      :expires_at
    ])
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses)
    |> optimistic_lock(:generation)
    |> unique_constraint([:owner_visitor_id, :category, :claim_fingerprint],
      name: :profile_memory_records_active_claim_index
    )
    |> unique_constraint([:owner_visitor_id, :category],
      name: :profile_memory_records_active_singleton_index
    )
  end

  def categories, do: @categories
  def statuses, do: @statuses
  def creators, do: @creators
end
