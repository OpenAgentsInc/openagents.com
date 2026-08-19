defmodule OpenAgents.Memory.Portability.ImportReceipt do
  @moduledoc "Destination-bound replay, conflict, tombstone, and revocation receipt."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "portable_import_receipts" do
    field :owner_visitor_id, :binary_id
    field :source_installation_ref, :string
    field :export_sequence, :integer
    field :envelope_digest, :string
    field :confirmation_digest, :string
    field :status, :string
    field :imported_count, :integer
    field :unchanged_count, :integer
    field :conflict_count, :integer
    field :tombstone_count, :integer
    field :revoked_at, :utc_datetime_usec
    field :revocation_digest, :string
    timestamps()
  end

  def create_changeset(row, attrs),
    do:
      row
      |> cast(attrs, [
        :owner_visitor_id,
        :source_installation_ref,
        :export_sequence,
        :envelope_digest,
        :confirmation_digest,
        :status,
        :imported_count,
        :unchanged_count,
        :conflict_count,
        :tombstone_count
      ])
      |> validate_required([
        :owner_visitor_id,
        :source_installation_ref,
        :export_sequence,
        :envelope_digest,
        :confirmation_digest,
        :status,
        :imported_count,
        :unchanged_count,
        :conflict_count,
        :tombstone_count
      ])

  def revoke_changeset(row, attrs),
    do: cast(row, attrs, [:status, :revoked_at, :revocation_digest])
end
