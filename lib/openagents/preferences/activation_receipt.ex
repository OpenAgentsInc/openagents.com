defmodule OpenAgents.Preferences.ActivationReceipt do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "preference_activation_receipts" do
    belongs_to :preference, OpenAgents.Preferences.Preference
    field :owner_visitor_id, :binary_id
    field :scope_generation, :integer
    field :confirmation_ref, :string
    field :effect_digest, :string
    field :policy_id, :string
    field :policy_version, :integer
    field :receipt_digest, :string
    timestamps()
  end

  def changeset(receipt, attributes) do
    receipt
    |> cast(attributes, [
      :preference_id,
      :owner_visitor_id,
      :scope_generation,
      :confirmation_ref,
      :effect_digest,
      :policy_id,
      :policy_version,
      :receipt_digest
    ])
    |> validate_required([
      :preference_id,
      :owner_visitor_id,
      :scope_generation,
      :confirmation_ref,
      :effect_digest,
      :policy_id,
      :policy_version,
      :receipt_digest
    ])
    |> validate_number(:scope_generation, greater_than: 0)
    |> validate_format(:effect_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:receipt_digest, ~r/\A[0-9a-f]{64}\z/)
  end
end
