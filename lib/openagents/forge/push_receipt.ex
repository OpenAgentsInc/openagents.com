defmodule OpenAgents.Forge.PushReceipt do
  @moduledoc """
  Derived record of one accepted forge push (`forge_pushes`). Derived from
  the WAL and idempotent by `{repo, wal_seq}` — never ref authority (audit
  A7: refs live in the WAL; Postgres holds projections and receipts).

  `link` is the WAL chain link of the entry this receipt derives from
  (`EXIT-005`), copied from the entry and never computed from this row. It is
  `nil` for a receipt derived from an entry written before the chain existed,
  and no backfill fills it in: a link the operator computes over entries the
  operator holds proves nothing. Nothing reads this column to decide anything
  — `OpenAgents.Forge.Verification` recomputes the chain from the WAL, and a
  verifier that consulted PostgreSQL would be asking the operator to confirm
  the operator. What the column buys is that a rewrite of an accepted push
  now has to edit object storage and PostgreSQL consistently rather than
  object storage alone.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "forge_pushes" do
    field :repo, :string
    field :wal_seq, :integer
    field :principal, :string
    field :refs, :map, default: %{}
    field :duration_ms, :integer
    field :link, :string
    timestamps(updated_at: false)
  end

  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [:repo, :wal_seq, :principal, :refs, :duration_ms, :link])
    |> validate_required([:repo, :wal_seq, :principal])
    |> validate_number(:wal_seq, greater_than_or_equal_to: 0)
    |> unique_constraint([:repo, :wal_seq])
  end
end
