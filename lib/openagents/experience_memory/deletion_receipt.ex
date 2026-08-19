defmodule OpenAgents.ExperienceMemory.DeletionReceipt do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]
  schema "experience_deletion_receipts" do
    field :owner_visitor_id, :binary_id
    field :work_scope, :string
    field :record_ref, :string
    field :source_ref_count, :integer
    field :bank_item_count, :integer
    field :pattern_count, :integer
    field :reason_code, :string
    field :receipt_digest, :string
    timestamps()
  end

  def changeset(receipt, attrs),
    do:
      receipt
      |> cast(attrs, [
        :owner_visitor_id,
        :work_scope,
        :record_ref,
        :source_ref_count,
        :bank_item_count,
        :pattern_count,
        :reason_code,
        :receipt_digest
      ])
      |> validate_required([
        :owner_visitor_id,
        :work_scope,
        :record_ref,
        :source_ref_count,
        :bank_item_count,
        :pattern_count,
        :reason_code,
        :receipt_digest
      ])
      |> validate_format(:receipt_digest, ~r/\A[0-9a-f]{64}\z/)
end
