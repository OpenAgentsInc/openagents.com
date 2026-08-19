defmodule OpenAgents.Compensation.ModuleAllocation do
  @moduledoc "Immutable contribution share assigned to an exact module artifact and policy."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "compensation_module_allocations" do
    belongs_to :policy_receipt, OpenAgents.Compensation.PolicyReceipt
    field :module_id, :string
    field :module_version, :integer
    field :artifact_digest, :string
    field :contribution_ref, :string
    field :allocation_ppm, :integer
    field :lineage_digest, :string
    field :actor_id, :string
    field :approval_receipt_ref, :string
    timestamps()
  end

  @type t :: %__MODULE__{}

  def changeset(record, attributes) do
    record
    |> cast(
      attributes,
      ~w(policy_receipt_id module_id module_version artifact_digest contribution_ref allocation_ppm lineage_digest actor_id approval_receipt_ref)a
    )
    |> validate_required(
      ~w(policy_receipt_id module_id module_version artifact_digest contribution_ref allocation_ppm lineage_digest actor_id approval_receipt_ref)a
    )
    |> validate_number(:module_version, greater_than: 0)
    |> validate_number(:allocation_ppm, greater_than: 0, less_than_or_equal_to: 1_000_000)
    |> validate_format(:artifact_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:lineage_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_length(:contribution_ref, min: 1, max: 256)
    |> foreign_key_constraint(:policy_receipt_id)
    |> unique_constraint([:policy_receipt_id, :module_id, :module_version, :contribution_ref])
  end
end
