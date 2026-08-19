defmodule OpenAgents.Compensation.Statement do
  @moduledoc "Immutable contributor reconciliation statement with no payout authority."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "compensation_statements" do
    belongs_to :policy_receipt, OpenAgents.Compensation.PolicyReceipt
    field :contribution_ref, :string
    field :cutoff_at, :utc_datetime_usec
    field :gross_units, :integer
    field :adjustment_units, :integer
    field :net_units, :integer
    field :event_count, :integer
    field :state, :string
    field :statement_digest, :string
    field :actor_id, :string
    field :statement_receipt_ref, :string
    timestamps()
  end

  @type t :: %__MODULE__{}

  def changeset(record, attributes) do
    record
    |> cast(
      attributes,
      ~w(policy_receipt_id contribution_ref cutoff_at gross_units adjustment_units net_units event_count state statement_digest actor_id statement_receipt_ref)a
    )
    |> validate_required(
      ~w(policy_receipt_id contribution_ref cutoff_at gross_units adjustment_units net_units event_count state statement_digest actor_id statement_receipt_ref)a
    )
    |> validate_inclusion(:state, ~w(reconciled disputed))
    |> validate_number(:gross_units, greater_than_or_equal_to: 0)
    |> validate_number(:net_units, greater_than_or_equal_to: 0)
    |> validate_number(:event_count, greater_than_or_equal_to: 0)
    |> validate_format(:statement_digest, ~r/\A[0-9a-f]{64}\z/)
    |> foreign_key_constraint(:policy_receipt_id)
    |> unique_constraint(:statement_receipt_ref)
  end
end
