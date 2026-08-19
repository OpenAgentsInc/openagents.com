defmodule OpenAgents.Collective.PublicationReceipt do
  @moduledoc "Append-only operator decision and collective artifact lifecycle receipt."

  use Ecto.Schema
  import Ecto.Changeset

  @digest_regex ~r/\A[0-9a-f]{64}\z/

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "collective_publication_receipts" do
    belongs_to :candidate, OpenAgents.Collective.Candidate
    belongs_to :review_receipt, OpenAgents.Collective.ReviewReceipt
    field :generation, :integer
    field :action, :string
    field :state, :string
    field :module_id, :string
    field :module_version, :integer
    field :artifact, :map
    field :artifact_digest, :string
    field :predecessor, :map
    field :attribution_lineage, {:array, :string}, default: []
    field :operator_actor_id, :string
    field :operator_auth_method, :string
    field :approval_receipt_ref, :string
    field :reason, :string
    field :derived_data_plan, :map
    field :plan_digest, :string
    timestamps()
  end

  @type t :: %__MODULE__{}

  def changeset(receipt, attributes) do
    receipt
    |> cast(attributes, [
      :candidate_id,
      :review_receipt_id,
      :generation,
      :action,
      :state,
      :module_id,
      :module_version,
      :artifact,
      :artifact_digest,
      :predecessor,
      :attribution_lineage,
      :operator_actor_id,
      :operator_auth_method,
      :approval_receipt_ref,
      :reason,
      :derived_data_plan,
      :plan_digest
    ])
    |> validate_required([
      :candidate_id,
      :review_receipt_id,
      :generation,
      :action,
      :state,
      :module_id,
      :module_version,
      :artifact,
      :artifact_digest,
      :attribution_lineage,
      :operator_actor_id,
      :operator_auth_method,
      :approval_receipt_ref,
      :reason,
      :derived_data_plan,
      :plan_digest
    ])
    |> validate_inclusion(:action, ~w(publish revoke rollback))
    |> validate_inclusion(:state, ~w(staged revoked))
    |> validate_number(:generation, greater_than: 0)
    |> validate_number(:module_version, greater_than: 0)
    |> validate_format(:artifact_digest, @digest_regex)
    |> validate_format(:plan_digest, @digest_regex)
    |> validate_length(:module_id, min: 1, max: 128)
    |> validate_length(:operator_actor_id, min: 1, max: 256)
    |> validate_length(:operator_auth_method, min: 1, max: 128)
    |> validate_length(:approval_receipt_ref, min: 1, max: 256)
    |> validate_length(:reason, min: 1, max: 1_000)
    |> validate_lineage()
    |> foreign_key_constraint(:candidate_id)
    |> foreign_key_constraint(:review_receipt_id)
    |> unique_constraint([:candidate_id, :generation])
    |> unique_constraint(:approval_receipt_ref)
  end

  defp validate_lineage(changeset) do
    validate_change(changeset, :attribution_lineage, fn :attribution_lineage, refs ->
      if is_list(refs) and refs != [] and length(refs) <= 16 and
           Enum.all?(refs, &(is_binary(&1) and byte_size(&1) in 1..256)),
         do: [],
         else: [attribution_lineage: "must contain bounded opaque references"]
    end)
  end
end
