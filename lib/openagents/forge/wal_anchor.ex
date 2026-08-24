defmodule OpenAgents.Forge.WALAnchor do
  @moduledoc """
  One published anchor document (`forge_wal_anchors`).

  The row holds the exact bytes that were served, not the fields they were
  built from, because the digest a reader computes is a digest of the bytes
  they fetched. Re-rendering a document from columns would let key order drift
  between releases and turn every archived copy into apparent tampering, which
  is the same reason `OpenAgents.Forge.WAL`'s chain encoding is not JSON.

  `previous_digest` names the digest of the anchor published before this one,
  so the published sequence is itself a hash chain: one archived anchor pins
  every anchor before it, the way an entry link pins every entry before it.

  This table is a publication record, never authority. Nothing reads it to
  decide what the forge serves, and `OpenAgents.Forge.Verification` reaches no
  database at all — a verifier consulting PostgreSQL would be asking the
  operator to confirm the operator.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "forge_wal_anchors" do
    field :anchor_seq, :integer
    field :digest, :string
    field :previous_digest, :string
    field :body, :string
    field :published_at, :utc_datetime_usec
    timestamps(updated_at: false)
  end

  def changeset(anchor, attrs) do
    anchor
    |> cast(attrs, [:anchor_seq, :digest, :previous_digest, :body, :published_at])
    |> validate_required([:anchor_seq, :digest, :body, :published_at])
    |> validate_number(:anchor_seq, greater_than_or_equal_to: 0)
    |> unique_constraint(:anchor_seq)
  end
end
