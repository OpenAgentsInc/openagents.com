defmodule OpenAgents.Forge.PushReceipt do
  @moduledoc """
  Stub push receipt struct used to keep the lifted Sarah forge tests compiling
  while the runtime is still stubbed out.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "forge_push_receipts" do
    field :repo, :string
    field :wal_seq, :integer
    field :principal, :string
    field :refs, :map
    field :result, :string
    field :push_to_live_ms, :integer

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(receipt, attrs) do
    Ecto.Changeset.cast(receipt, attrs, [
      :repo,
      :wal_seq,
      :principal,
      :refs,
      :result,
      :push_to_live_ms
    ])
  end
end
