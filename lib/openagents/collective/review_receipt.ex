defmodule OpenAgents.Collective.ReviewReceipt do
  @moduledoc "Append-only independent evaluation receipt for one generalized candidate."

  use Ecto.Schema
  import Ecto.Changeset

  @digest_regex ~r/\A[0-9a-f]{64}\z/

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "collective_review_receipts" do
    belongs_to :candidate, OpenAgents.Collective.Candidate
    belongs_to :generalization_receipt, OpenAgents.Collective.GeneralizationReceipt
    field :decision, :string
    field :reason_codes, {:array, :string}, default: []
    field :evaluator_artifact_ref, :string
    field :evaluator_artifact_digest, :string
    field :dataset_ref, :string
    field :dataset_digest, :string
    field :policy_id, :string
    field :policy_version, :integer
    field :policy_digest, :string
    field :candidate_digest, :string
    field :evaluation_digest, :string
    field :dimensions, :map
    field :reviewer_actor_id, :string
    field :reviewer_auth_method, :string
    timestamps()
  end

  @type t :: %__MODULE__{}

  def changeset(receipt, attributes) do
    receipt
    |> cast(attributes, [
      :candidate_id,
      :generalization_receipt_id,
      :decision,
      :reason_codes,
      :evaluator_artifact_ref,
      :evaluator_artifact_digest,
      :dataset_ref,
      :dataset_digest,
      :policy_id,
      :policy_version,
      :policy_digest,
      :candidate_digest,
      :evaluation_digest,
      :dimensions,
      :reviewer_actor_id,
      :reviewer_auth_method
    ])
    |> validate_required([
      :candidate_id,
      :generalization_receipt_id,
      :decision,
      :reason_codes,
      :evaluator_artifact_ref,
      :evaluator_artifact_digest,
      :dataset_ref,
      :dataset_digest,
      :policy_id,
      :policy_version,
      :policy_digest,
      :candidate_digest,
      :evaluation_digest,
      :dimensions,
      :reviewer_actor_id,
      :reviewer_auth_method
    ])
    |> validate_inclusion(:decision, ~w(passed rejected))
    |> validate_number(:policy_version, greater_than: 0)
    |> validate_format(:evaluator_artifact_digest, @digest_regex)
    |> validate_format(:dataset_digest, @digest_regex)
    |> validate_format(:policy_digest, @digest_regex)
    |> validate_format(:candidate_digest, @digest_regex)
    |> validate_format(:evaluation_digest, @digest_regex)
    |> validate_length(:evaluator_artifact_ref, min: 1, max: 256)
    |> validate_length(:dataset_ref, min: 1, max: 256)
    |> validate_length(:policy_id, min: 1, max: 128)
    |> validate_length(:reviewer_actor_id, min: 1, max: 256)
    |> validate_length(:reviewer_auth_method, min: 1, max: 128)
    |> validate_reason_codes()
    |> foreign_key_constraint(:candidate_id)
    |> foreign_key_constraint(:generalization_receipt_id)
    |> unique_constraint(:candidate_id)
  end

  defp validate_reason_codes(changeset) do
    validate_change(changeset, :reason_codes, fn :reason_codes, codes ->
      if is_list(codes) and length(codes) <= 16 and
           Enum.all?(codes, &(is_binary(&1) and byte_size(&1) in 1..64)),
         do: [],
         else: [reason_codes: "must contain bounded reason codes"]
    end)
  end
end
