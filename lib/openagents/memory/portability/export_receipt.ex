defmodule OpenAgents.Memory.Portability.ExportReceipt do
  @moduledoc "Metadata-only receipt for a person-held encrypted export."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "portable_export_receipts" do
    field :owner_visitor_id, :binary_id
    field :source_installation_ref, :string
    field :sequence, :integer
    field :envelope_digest, :string
    field :profile_record_count, :integer
    field :kdf_id, :string
    field :cipher_id, :string
    field :status, :string
    field :previous_export_id, :binary_id
    field :rotated_at, :utc_datetime_usec
    field :tombstoned_at, :utc_datetime_usec
    timestamps()
  end

  def create_changeset(row, attrs),
    do:
      row
      |> cast(attrs, [
        :owner_visitor_id,
        :source_installation_ref,
        :sequence,
        :envelope_digest,
        :profile_record_count,
        :kdf_id,
        :cipher_id,
        :status,
        :previous_export_id
      ])
      |> validate_required([
        :owner_visitor_id,
        :source_installation_ref,
        :sequence,
        :envelope_digest,
        :profile_record_count,
        :kdf_id,
        :cipher_id,
        :status
      ])

  def transition_changeset(row, attrs),
    do: cast(row, attrs, [:status, :rotated_at, :tombstoned_at])
end
