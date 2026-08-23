defmodule OpenAgents.Reputation.Attestation do
  @moduledoc """
  One signed reputation event about one accepted outcome.

  The `claim` map is the exact object the signature covers. Every column
  beside it is a projection of that claim kept for querying, so a client can
  ignore the columns, canonicalize the claim, and check the signature itself.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Repositories.Repository

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  @event_types ~w(completion verification review payment reversal revocation)
  @invalidating_event_types ~w(reversal revocation)
  @transparency_tiers ~w(public repository private)

  schema "reputation_attestations" do
    belongs_to :repository, Repository
    field :issue_number, :integer
    field :event_type, :string
    field :subject_id, :string
    field :issuer_key_id, :string
    field :outcome_kind, :string
    field :outcome_ref, :string
    field :outcome_digest, :string
    field :revision, :string
    field :artifact_digest, :string
    field :policy_id, :string
    field :policy_version, :integer
    field :policy_digest, :string
    field :confidence_ppm, :integer
    field :transparency_tier, :string
    field :attested_at, :utc_datetime_usec
    field :nonce, :string
    field :claim, :map
    field :claim_digest, :string
    field :signature, :string
    field :signature_algorithm, :string
    field :supersedes_digest, :string
    field :revoked_at, :utc_datetime_usec
    field :revocation_reason_code, :string
    field :revoked_by_id, Ecto.UUID
    belongs_to :revokes, __MODULE__
    timestamps()
  end

  @type t :: %__MODULE__{}

  def event_types, do: @event_types
  def invalidating_event_types, do: @invalidating_event_types
  def transparency_tiers, do: @transparency_tiers

  def changeset(record, attributes) do
    required =
      ~w(repository_id issue_number event_type subject_id issuer_key_id outcome_kind outcome_ref
         outcome_digest revision artifact_digest policy_id policy_version policy_digest
         confidence_ppm transparency_tier attested_at nonce claim claim_digest signature
         signature_algorithm)a

    record
    |> cast(attributes, required ++ ~w(supersedes_digest revokes_id)a)
    |> validate_required(required)
    |> validate_inclusion(:event_type, @event_types)
    |> validate_inclusion(:transparency_tier, @transparency_tiers)
    |> validate_number(:issue_number, greater_than: 0)
    |> validate_number(:policy_version, greater_than: 0)
    |> validate_number(:confidence_ppm,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 1_000_000
    )
    |> validate_format(:outcome_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:artifact_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:policy_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:claim_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:issuer_key_id, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:nonce, ~r/\A[0-9a-f]{32}\z/)
    |> validate_length(:subject_id, min: 1, max: 256)
    |> validate_length(:outcome_kind, min: 1, max: 64)
    |> validate_length(:outcome_ref, min: 1, max: 256)
    |> validate_length(:revision, min: 1, max: 128)
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:revokes_id)
    |> unique_constraint(:claim_digest)
    |> unique_constraint(:revokes_id)
    |> unique_constraint([:issuer_key_id, :subject_id, :outcome_kind, :outcome_ref, :event_type],
      name: :reputation_attestations_outcome_event_index
    )
  end

  def revocation_changeset(record, attributes) do
    record
    |> cast(attributes, ~w(revoked_at revocation_reason_code revoked_by_id)a)
    |> validate_required(~w(revoked_at revocation_reason_code)a)
    |> validate_length(:revocation_reason_code, min: 1, max: 64)
  end
end
