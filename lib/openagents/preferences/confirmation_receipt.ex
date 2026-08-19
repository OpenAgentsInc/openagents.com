defmodule OpenAgents.Preferences.ConfirmationReceipt do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "preference_confirmation_receipts" do
    belongs_to :preference, OpenAgents.Preferences.Preference
    field :owner_visitor_id, :binary_id
    field :kind, :string
    field :evidence_ref, :string
    field :effect_digest, :string
    field :receipt_digest, :string
    timestamps()
  end

  def changeset(receipt, attributes) do
    receipt
    |> cast(attributes, [
      :preference_id,
      :owner_visitor_id,
      :kind,
      :evidence_ref,
      :effect_digest,
      :receipt_digest
    ])
    |> validate_required([
      :preference_id,
      :owner_visitor_id,
      :kind,
      :evidence_ref,
      :effect_digest,
      :receipt_digest
    ])
    |> validate_inclusion(:kind, ~w(exact_confirmation first_party_ui))
    |> validate_format(:effect_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:receipt_digest, ~r/\A[0-9a-f]{64}\z/)
  end
end
