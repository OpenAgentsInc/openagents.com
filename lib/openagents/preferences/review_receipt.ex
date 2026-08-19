defmodule OpenAgents.Preferences.ReviewReceipt do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "preference_review_receipts" do
    belongs_to :preference, OpenAgents.Preferences.Preference
    field :owner_visitor_id, :binary_id
    field :reviewer_id, :string
    field :decision, :string
    field :reason_code, :string
    field :effect_digest, :string
    field :receipt_digest, :string
    timestamps()
  end

  def changeset(receipt, attributes) do
    receipt
    |> cast(attributes, [
      :preference_id,
      :owner_visitor_id,
      :reviewer_id,
      :decision,
      :reason_code,
      :effect_digest,
      :receipt_digest
    ])
    |> validate_required([
      :preference_id,
      :owner_visitor_id,
      :reviewer_id,
      :decision,
      :reason_code,
      :effect_digest,
      :receipt_digest
    ])
    |> validate_inclusion(:decision, ~w(accepted rejected))
    |> validate_format(:effect_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:receipt_digest, ~r/\A[0-9a-f]{64}\z/)
  end
end
