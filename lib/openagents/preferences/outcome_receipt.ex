defmodule OpenAgents.Preferences.OutcomeReceipt do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "preference_outcome_receipts" do
    belongs_to :preference, OpenAgents.Preferences.Preference
    belongs_to :turn, OpenAgents.Conversations.Turn
    field :owner_visitor_id, :binary_id
    belongs_to :activation_receipt, OpenAgents.Preferences.ActivationReceipt
    field :outcome, :string
    field :evidence_ref, :string
    field :reason_code, :string
    field :receipt_digest, :string
    timestamps()
  end

  def changeset(receipt, attributes) do
    receipt
    |> cast(attributes, [
      :preference_id,
      :turn_id,
      :owner_visitor_id,
      :activation_receipt_id,
      :outcome,
      :evidence_ref,
      :reason_code,
      :receipt_digest
    ])
    |> validate_required([
      :preference_id,
      :turn_id,
      :owner_visitor_id,
      :activation_receipt_id,
      :outcome,
      :evidence_ref,
      :reason_code,
      :receipt_digest
    ])
    |> validate_inclusion(:outcome, ~w(benefited neutral corrected rejected))
    |> validate_format(:receipt_digest, ~r/\A[0-9a-f]{64}\z/)
  end
end
