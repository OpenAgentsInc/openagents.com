defmodule OpenAgents.Settlement.PaymentReceipt do
  @moduledoc """
  The exact evidence of one settled payment.

  One receipt exists per payment intent, and the payment hash is unique across
  the ledger, so a replayed acknowledgement cannot become a second payment.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Settlement.{Claim, PaymentIntent}

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  @fields ~w(payment_intent_id claim_id amount_sats fee_sats payment_hash preimage_digest
             gateway_ref paid_at receipt_digest)a

  schema "settlement_payment_receipts" do
    field :amount_sats, :integer
    field :fee_sats, :integer
    field :payment_hash, :string
    field :preimage_digest, :string
    field :gateway_ref, :string
    field :paid_at, :utc_datetime_usec
    field :receipt_digest, :string
    belongs_to :payment_intent, PaymentIntent, type: :binary_id
    belongs_to :claim, Claim, type: :binary_id
    timestamps()
  end

  @type t :: %__MODULE__{}

  def changeset(record, attributes) do
    record
    |> cast(attributes, @fields)
    |> validate_required(@fields)
    |> validate_number(:amount_sats, greater_than: 0)
    |> validate_number(:fee_sats, greater_than_or_equal_to: 0)
    |> validate_format(:payment_hash, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:preimage_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:receipt_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_length(:gateway_ref, min: 1, max: 256)
    |> unique_constraint(:payment_intent_id)
    |> unique_constraint(:payment_hash)
    |> foreign_key_constraint(:claim_id)
    |> foreign_key_constraint(:payment_intent_id)
  end
end
