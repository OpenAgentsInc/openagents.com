defmodule OpenAgents.Forge.PushReceipt do
  @moduledoc """
  Derived record of one accepted forge push (`forge_pushes`). Derived from
  the WAL and idempotent by `{repo, wal_seq}` — never ref authority (audit
  A7: refs live in the WAL; Postgres holds projections and receipts).
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
    timestamps(updated_at: false)
  end

  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [:repo, :wal_seq, :principal, :refs, :duration_ms])
    |> validate_required([:repo, :wal_seq, :principal])
    |> validate_number(:wal_seq, greater_than_or_equal_to: 0)
    |> unique_constraint([:repo, :wal_seq])
  end
end
