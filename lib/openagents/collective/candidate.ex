defmodule OpenAgents.Collective.Candidate do
  @moduledoc "Private pre-publication collective candidate with opaque source provenance."

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(consented generalized rejected review_rejected reviewed operator_rejected published revoked withdrawn revocation_pending)
  @digest_regex ~r/\A[0-9a-f]{64}\z/

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "collective_candidates" do
    belongs_to :owner, OpenAgents.Conversations.Visitor, foreign_key: :visitor_id
    belongs_to :consent_receipt, OpenAgents.Collective.ConsentReceipt
    field :source_scope_digest, :string
    field :provenance_refs, {:array, :string}
    field :redaction_policy_id, :string
    field :redaction_policy_version, :integer
    field :redaction_policy_digest, :string
    field :generalized_kind, :string
    field :generalized_payload, :map
    field :evaluator_ref, :string
    field :status, :string, default: "consented"
    field :review_refs, {:array, :string}, default: []
    field :publication_refs, {:array, :string}, default: []
    timestamps()
  end

  @type t :: %__MODULE__{}

  def create_changeset(candidate, attributes) do
    candidate
    |> cast(attributes, [
      :visitor_id,
      :consent_receipt_id,
      :source_scope_digest,
      :provenance_refs,
      :redaction_policy_id,
      :redaction_policy_version,
      :redaction_policy_digest,
      :generalized_kind,
      :generalized_payload,
      :evaluator_ref,
      :status,
      :review_refs,
      :publication_refs
    ])
    |> validate_required([
      :visitor_id,
      :consent_receipt_id,
      :source_scope_digest,
      :provenance_refs,
      :redaction_policy_id,
      :redaction_policy_version,
      :redaction_policy_digest,
      :generalized_kind,
      :status
    ])
    |> validate_inclusion(:status, ["consented"])
    |> validate_number(:redaction_policy_version, greater_than: 0)
    |> validate_format(:source_scope_digest, @digest_regex)
    |> validate_format(:redaction_policy_digest, @digest_regex)
    |> validate_length(:redaction_policy_id, min: 1, max: 128)
    |> validate_length(:generalized_kind, min: 1, max: 64)
    |> validate_refs(:provenance_refs, 16)
    |> validate_refs(:review_refs, 32)
    |> validate_refs(:publication_refs, 32)
    |> foreign_key_constraint(:visitor_id)
    |> foreign_key_constraint(:consent_receipt_id)
    |> unique_constraint(:consent_receipt_id)
  end

  def status_changeset(candidate, attributes) do
    candidate
    |> cast(attributes, [:status])
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses)
  end

  def review_changeset(candidate, attributes) do
    candidate
    |> cast(attributes, [:status, :evaluator_ref, :review_refs])
    |> validate_required([:status, :evaluator_ref, :review_refs])
    |> validate_inclusion(:status, ~w(review_rejected reviewed))
    |> validate_length(:evaluator_ref, min: 1, max: 256)
    |> validate_refs(:review_refs, 32)
  end

  def publication_changeset(candidate, attributes) do
    candidate
    |> cast(attributes, [:status, :publication_refs])
    |> validate_required([:status, :publication_refs])
    |> validate_inclusion(:status, ~w(published revoked revocation_pending))
    |> validate_refs(:publication_refs, 32)
  end

  def operator_rejection_changeset(candidate) do
    candidate
    |> change(status: "operator_rejected")
    |> validate_inclusion(:status, ["operator_rejected"])
  end

  defp validate_refs(changeset, field, maximum_count) do
    validate_change(changeset, field, fn ^field, refs ->
      if is_list(refs) and length(refs) <= maximum_count and
           Enum.all?(refs, &(is_binary(&1) and byte_size(&1) in 1..256)),
         do: [],
         else: [{field, "must contain bounded opaque references"}]
    end)
  end
end
