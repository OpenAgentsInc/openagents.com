defmodule OpenAgents.Compensation.Adjustment do
  @moduledoc "Append-only refund, chargeback, fraud, dispute, or policy-migration adjustment."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "compensation_adjustments" do
    belongs_to :event, OpenAgents.Compensation.Event
    belongs_to :policy_receipt, OpenAgents.Compensation.PolicyReceipt
    field :contribution_ref, :string
    field :kind, :string
    field :delta_units, :integer
    field :reason_code, :string
    field :actor_id, :string
    field :auth_method, :string
    field :adjustment_receipt_ref, :string
    field :adjustment_digest, :string
    timestamps()
  end

  @type t :: %__MODULE__{}

  def changeset(record, attributes) do
    record
    |> cast(
      attributes,
      ~w(event_id policy_receipt_id contribution_ref kind delta_units reason_code actor_id auth_method adjustment_receipt_ref adjustment_digest)a
    )
    |> validate_required(
      ~w(event_id policy_receipt_id contribution_ref kind delta_units reason_code actor_id auth_method adjustment_receipt_ref adjustment_digest)a
    )
    |> validate_inclusion(
      :kind,
      ~w(refund chargeback fraud_hold dispute_resolution policy_migration)
    )
    |> validate_exclusion(:delta_units, [0])
    |> validate_format(:adjustment_digest, ~r/\A[0-9a-f]{64}\z/)
    |> foreign_key_constraint(:event_id)
    |> foreign_key_constraint(:policy_receipt_id)
    |> unique_constraint(:adjustment_receipt_ref)
  end
end
