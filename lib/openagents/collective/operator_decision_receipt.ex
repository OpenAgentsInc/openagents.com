defmodule OpenAgents.Collective.OperatorDecisionReceipt do
  @moduledoc "Append-only authenticated operator approval or rejection of a reviewed candidate."

  use Ecto.Schema
  import Ecto.Changeset

  @digest_regex ~r/\A[0-9a-f]{64}\z/

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "collective_operator_decision_receipts" do
    belongs_to :candidate, OpenAgents.Collective.Candidate
    belongs_to :review_receipt, OpenAgents.Collective.ReviewReceipt
    field :decision, :string
    field :candidate_digest, :string
    field :review_digest, :string
    field :operator_actor_id, :string
    field :operator_auth_method, :string
    field :approval_receipt_ref, :string
    field :reason, :string
    timestamps()
  end

  def changeset(receipt, attributes) do
    receipt
    |> cast(attributes, [
      :candidate_id,
      :review_receipt_id,
      :decision,
      :candidate_digest,
      :review_digest,
      :operator_actor_id,
      :operator_auth_method,
      :approval_receipt_ref,
      :reason
    ])
    |> validate_required([
      :candidate_id,
      :review_receipt_id,
      :decision,
      :candidate_digest,
      :review_digest,
      :operator_actor_id,
      :operator_auth_method,
      :approval_receipt_ref,
      :reason
    ])
    |> validate_inclusion(:decision, ~w(approved rejected))
    |> validate_format(:candidate_digest, @digest_regex)
    |> validate_format(:review_digest, @digest_regex)
    |> validate_length(:operator_actor_id, min: 1, max: 256)
    |> validate_length(:operator_auth_method, min: 1, max: 128)
    |> validate_length(:approval_receipt_ref, min: 1, max: 256)
    |> validate_length(:reason, min: 1, max: 1_000)
    |> foreign_key_constraint(:candidate_id)
    |> foreign_key_constraint(:review_receipt_id)
    |> unique_constraint(:candidate_id)
    |> unique_constraint(:approval_receipt_ref)
  end
end
