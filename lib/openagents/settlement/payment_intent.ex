defmodule OpenAgents.Settlement.PaymentIntent do
  @moduledoc """
  The idempotent record of an authorized payment attempt.

  One idempotency key names one intent for the lifetime of the settlement. A
  retry, a duplicate request, and a lost acknowledgement all resolve to the
  same intent, and only one intent per claim can reach `paid`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Settlement.{Claim, Verification}

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @states ~w(pending paid failed refunded)

  @fields ~w(claim_id verification_id idempotency_key amount_sats commit_sha destination_digest
             spec_fingerprint state attempts failure_reason_code intent_digest actor_id
             auth_method approval_receipt_ref)a

  @required @fields -- ~w(failure_reason_code)a

  schema "settlement_payment_intents" do
    field :idempotency_key, :string
    field :amount_sats, :integer
    field :commit_sha, :string
    field :destination_digest, :string
    field :spec_fingerprint, :string
    field :state, :string
    field :attempts, :integer, default: 0
    field :failure_reason_code, :string
    field :intent_digest, :string
    field :actor_id, :string
    field :auth_method, :string
    field :approval_receipt_ref, :string
    belongs_to :claim, Claim, type: :binary_id
    belongs_to :verification, Verification, type: :binary_id
    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc "Every payment intent state."
  def states, do: @states

  def changeset(record, attributes) do
    record
    |> cast(attributes, @fields)
    |> validate_required(@required)
    |> validate_inclusion(:state, @states)
    |> validate_number(:amount_sats, greater_than: 0)
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> validate_format(:commit_sha, ~r/\A[0-9a-f]{40}\z/)
    |> validate_format(:intent_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_length(:idempotency_key, min: 8, max: 256)
    |> validate_length(:approval_receipt_ref, min: 1, max: 256)
    |> unique_constraint(:idempotency_key)
    |> unique_constraint(:claim_id, name: :settlement_payment_intent_single_paid)
    |> foreign_key_constraint(:claim_id)
    |> foreign_key_constraint(:verification_id)
  end

  def result_changeset(record, attributes) do
    record
    |> cast(attributes, ~w(state attempts failure_reason_code)a)
    |> validate_inclusion(:state, @states)
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> unique_constraint(:claim_id, name: :settlement_payment_intent_single_paid)
  end
end
