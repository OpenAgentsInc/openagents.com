defmodule OpenAgents.Memory.Portability.ImportItem do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]
  schema "portable_import_items" do
    field :import_receipt_id, :binary_id
    field :origin_record_ref, :string
    field :destination_record_id, :binary_id
    field :source_status, :string
    field :disposition, :string
    timestamps()
  end

  def changeset(row, attrs),
    do:
      row
      |> cast(attrs, [
        :import_receipt_id,
        :origin_record_ref,
        :destination_record_id,
        :source_status,
        :disposition
      ])
      |> validate_required([:import_receipt_id, :origin_record_ref, :source_status, :disposition])
end
