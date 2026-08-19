defmodule OpenAgents.Collective.ConsentReceipt do
  @moduledoc "Person-granted contribution consent for one exact private source set."

  use Ecto.Schema
  import Ecto.Changeset

  @categories ~w(evaluation_case prompt_example module_pattern reusable_work_pattern)
  @digest_regex ~r/\A[0-9a-f]{64}\z/

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "collective_consent_receipts" do
    belongs_to :owner, OpenAgents.Conversations.Visitor, foreign_key: :visitor_id
    field :source_scope_ref, :string
    field :source_scope_digest, :string
    field :source_refs, {:array, :string}
    field :source_digest, :string
    field :category, :string
    field :intended_use, :string
    field :attribution_disclosure, :string
    field :compensation_disclosure, :string
    field :policy_id, :string
    field :policy_version, :integer
    field :policy_digest, :string
    field :confirmation_digest, :string
    field :status, :string, default: "active"
    field :granted_at, :utc_datetime_usec
    field :withdrawn_at, :utc_datetime_usec
    field :withdrawal_reason, :string
    timestamps()
  end

  @type t :: %__MODULE__{}

  def grant_changeset(receipt, attributes) do
    receipt
    |> cast(attributes, [
      :visitor_id,
      :source_scope_ref,
      :source_scope_digest,
      :source_refs,
      :source_digest,
      :category,
      :intended_use,
      :attribution_disclosure,
      :compensation_disclosure,
      :policy_id,
      :policy_version,
      :policy_digest,
      :confirmation_digest,
      :status,
      :granted_at
    ])
    |> validate_required([
      :visitor_id,
      :source_scope_ref,
      :source_scope_digest,
      :source_refs,
      :source_digest,
      :category,
      :intended_use,
      :attribution_disclosure,
      :compensation_disclosure,
      :policy_id,
      :policy_version,
      :policy_digest,
      :confirmation_digest,
      :status,
      :granted_at
    ])
    |> validate_inclusion(:category, @categories)
    |> validate_inclusion(:status, ["active"])
    |> validate_number(:policy_version, greater_than: 0)
    |> validate_length(:source_scope_ref, min: 1, max: 128)
    |> validate_length(:intended_use, min: 1, max: 500)
    |> validate_length(:attribution_disclosure, min: 1, max: 500)
    |> validate_length(:compensation_disclosure, min: 1, max: 500)
    |> validate_length(:policy_id, min: 1, max: 128)
    |> validate_digests()
    |> validate_source_refs()
    |> foreign_key_constraint(:visitor_id)
    |> unique_constraint(:confirmation_digest)
  end

  def withdraw_changeset(receipt, attributes) do
    receipt
    |> cast(attributes, [:status, :withdrawn_at, :withdrawal_reason])
    |> validate_required([:status, :withdrawn_at, :withdrawal_reason])
    |> validate_inclusion(:status, ["withdrawn"])
    |> validate_length(:withdrawal_reason, min: 1, max: 500)
  end

  defp validate_digests(changeset) do
    Enum.reduce(
      [:source_scope_digest, :source_digest, :policy_digest, :confirmation_digest],
      changeset,
      &validate_format(&2, &1, @digest_regex)
    )
  end

  defp validate_source_refs(changeset) do
    validate_change(changeset, :source_refs, fn :source_refs, refs ->
      if is_list(refs) and refs != [] and length(refs) <= 16 and
           refs == Enum.sort(Enum.uniq(refs)) and
           Enum.all?(refs, &(is_binary(&1) and byte_size(&1) in 1..128)),
         do: [],
         else: [source_refs: "must be a sorted bounded exact source set"]
    end)
  end
end
