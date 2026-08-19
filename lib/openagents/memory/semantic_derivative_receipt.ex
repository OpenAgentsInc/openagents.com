defmodule OpenAgents.Memory.SemanticDerivativeReceipt do
  @moduledoc "Content-free append-only receipt for semantic invalidation, deletion, or rebuild."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "semantic_derivative_receipts" do
    field :message_id, :binary_id
    field :conversation_id, :binary_id
    field :content_digest, :string
    field :action, :string
    field :reason_code, :string
    field :generation, :integer
    field :deleted_embedding_count, :integer
    field :invalidated_job_count, :integer
    field :receipt_digest, :string
    timestamps()
  end

  def changeset(record, attributes) do
    record
    |> cast(
      attributes,
      ~w(message_id conversation_id content_digest action reason_code generation deleted_embedding_count invalidated_job_count receipt_digest)a
    )
    |> validate_required(
      ~w(message_id conversation_id content_digest action reason_code generation deleted_embedding_count invalidated_job_count receipt_digest)a
    )
    |> validate_inclusion(:action, ~w(invalidate delete rebuild))
    |> validate_number(:generation, greater_than: 0)
    |> validate_number(:deleted_embedding_count, greater_than_or_equal_to: 0)
    |> validate_number(:invalidated_job_count, greater_than_or_equal_to: 0)
    |> validate_format(:content_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:receipt_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_length(:reason_code, min: 1, max: 64)
  end
end
