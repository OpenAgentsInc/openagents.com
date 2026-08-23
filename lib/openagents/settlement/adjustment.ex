defmodule OpenAgents.Settlement.Adjustment do
  @moduledoc """
  An append-only expiry, dispute, or refund record for one claim.

  An adjustment never rewrites a payment receipt. It records the decision that
  changed what the claim may still do, with the operator authority behind it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Settlement.Claim

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  @kinds ~w(expiry dispute refund)

  @fields ~w(claim_id kind reason_code actor_id auth_method approval_receipt_ref
             adjustment_digest)a

  schema "settlement_adjustments" do
    field :kind, :string
    field :reason_code, :string
    field :actor_id, :string
    field :auth_method, :string
    field :approval_receipt_ref, :string
    field :adjustment_digest, :string
    belongs_to :claim, Claim, type: :binary_id
    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc "Every adjustment kind."
  def kinds, do: @kinds

  def changeset(record, attributes) do
    record
    |> cast(attributes, @fields)
    |> validate_required(@fields)
    |> validate_inclusion(:kind, @kinds)
    |> validate_format(:adjustment_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_length(:reason_code, min: 1, max: 128)
    |> validate_length(:approval_receipt_ref, min: 1, max: 256)
    |> unique_constraint([:claim_id, :kind, :approval_receipt_ref])
    |> foreign_key_constraint(:claim_id)
  end
end
