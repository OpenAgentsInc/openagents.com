defmodule OpenAgents.Settlement.Claim do
  @moduledoc """
  One claimant's pinned commitment to a priced specification.

  The claim carries the fingerprint it agreed to and the self-custodial
  destination that a payment may reach. Only one claim per specification is
  live at a time; expired and rejected claims release the specification.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Settlement.BountySpec

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @states ~w(claimed verified rejected paid expired disputed refunded)

  @fields ~w(bounty_spec_id spec_fingerprint claimant_ref work_job_ref destination_kind
             destination destination_digest state claim_digest expires_at)a

  schema "settlement_claims" do
    field :spec_fingerprint, :string
    field :claimant_ref, :string
    field :work_job_ref, :string
    field :destination_kind, :string
    field :destination, :string
    field :destination_digest, :string
    field :state, :string
    field :claim_digest, :string
    field :expires_at, :utc_datetime_usec
    belongs_to :bounty_spec, BountySpec, type: :binary_id
    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc "Every claim state."
  def states, do: @states

  @doc "The states that hold a specification against a new claim."
  def live_states, do: @states -- ~w(expired rejected)

  def changeset(record, attributes) do
    record
    |> cast(attributes, @fields)
    |> validate_required(@fields)
    |> validate_inclusion(:state, @states)
    |> validate_format(:spec_fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:destination_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_length(:claimant_ref, min: 1, max: 256)
    |> validate_length(:work_job_ref, min: 1, max: 256)
    |> validate_length(:destination, min: 1, max: 2048)
    |> unique_constraint(:bounty_spec_id, name: :settlement_claim_single_live_claim)
    |> foreign_key_constraint(:bounty_spec_id)
  end

  def state_changeset(record, state) when state in @states do
    record
    |> change(state: state)
    |> unique_constraint(:bounty_spec_id, name: :settlement_claim_single_live_claim)
  end
end
