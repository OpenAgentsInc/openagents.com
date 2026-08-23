defmodule OpenAgents.Forum.TipReceipt do
  @moduledoc """
  The append-only record of what happened to one tip.

  A settled receipt carries the payment hash, which is what lets the recipient
  find the same payment in their own wallet. A database trigger refuses updates
  and deletes, and one receipt kind per intent means a retried settlement
  cannot append a second one.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Forum.TipIntent

  @kinds ["settled", "failed", "refunded"]

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "forum_tip_receipts" do
    field :kind, :string
    field :amount_sats, :integer
    field :fee_sats, :integer, default: 0
    field :payment_hash, :string
    field :failure_code, :string
    field :occurred_at, :utc_datetime_usec

    belongs_to :intent, TipIntent, type: :binary_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def kinds, do: @kinds

  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [
      :intent_id,
      :kind,
      :amount_sats,
      :fee_sats,
      :payment_hash,
      :failure_code,
      :occurred_at
    ])
    |> validate_required([:intent_id, :kind, :amount_sats, :occurred_at])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:payment_hash, max: 128)
    |> validate_length(:failure_code, max: 64)
    |> unique_constraint([:intent_id, :kind])
  end
end
