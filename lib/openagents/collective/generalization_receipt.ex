defmodule OpenAgents.Collective.GeneralizationReceipt do
  @moduledoc "Content-free receipt for deterministic collective redaction/generalization."

  use Ecto.Schema
  import Ecto.Changeset

  @digest_regex ~r/\A[0-9a-f]{64}\z/

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "collective_generalization_receipts" do
    belongs_to :candidate, OpenAgents.Collective.Candidate
    belongs_to :owner, OpenAgents.Conversations.Visitor, foreign_key: :visitor_id
    field :candidate_digest, :string
    field :source_digest, :string
    field :policy_id, :string
    field :policy_version, :integer
    field :policy_digest, :string
    field :generalizer_id, :string
    field :generalizer_version, :integer
    field :generalizer_digest, :string
    field :status, :string
    field :reason_codes, {:array, :string}, default: []
    field :risk, :string
    field :utility, :string
    field :support_signal, :string
    field :source_count, :integer
    field :output_digest, :string
    field :reviewer_actor_id, :string
    field :reviewer_auth_method, :string
    timestamps()
  end

  @type t :: %__MODULE__{}

  def changeset(receipt, attributes) do
    receipt
    |> cast(attributes, [
      :candidate_id,
      :visitor_id,
      :candidate_digest,
      :source_digest,
      :policy_id,
      :policy_version,
      :policy_digest,
      :generalizer_id,
      :generalizer_version,
      :generalizer_digest,
      :status,
      :reason_codes,
      :risk,
      :utility,
      :support_signal,
      :source_count,
      :output_digest,
      :reviewer_actor_id,
      :reviewer_auth_method
    ])
    |> validate_required([
      :candidate_id,
      :visitor_id,
      :candidate_digest,
      :source_digest,
      :policy_id,
      :policy_version,
      :policy_digest,
      :generalizer_id,
      :generalizer_version,
      :generalizer_digest,
      :status,
      :reason_codes,
      :risk,
      :utility,
      :source_count,
      :reviewer_actor_id,
      :reviewer_auth_method
    ])
    |> validate_inclusion(:status, ~w(generalized rejected))
    |> validate_inclusion(:risk, ~w(low high))
    |> validate_inclusion(:utility, ~w(sufficient insufficient))
    |> validate_number(:policy_version, greater_than: 0)
    |> validate_number(:generalizer_version, greater_than: 0)
    |> validate_number(:source_count, greater_than: 0, less_than_or_equal_to: 16)
    |> validate_format(:candidate_digest, @digest_regex)
    |> validate_format(:source_digest, @digest_regex)
    |> validate_format(:policy_digest, @digest_regex)
    |> validate_format(:generalizer_digest, @digest_regex)
    |> validate_optional_digest(:output_digest)
    |> validate_length(:policy_id, min: 1, max: 128)
    |> validate_length(:generalizer_id, min: 1, max: 128)
    |> validate_length(:support_signal, max: 64)
    |> validate_length(:reviewer_actor_id, min: 1, max: 256)
    |> validate_length(:reviewer_auth_method, min: 1, max: 128)
    |> validate_reasons()
    |> foreign_key_constraint(:candidate_id)
    |> foreign_key_constraint(:visitor_id)
    |> unique_constraint(:candidate_id)
  end

  defp validate_optional_digest(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_binary(value) and Regex.match?(@digest_regex, value),
        do: [],
        else: [{field, "must be a SHA-256 digest"}]
    end)
  end

  defp validate_reasons(changeset) do
    validate_change(changeset, :reason_codes, fn :reason_codes, reasons ->
      if is_list(reasons) and length(reasons) <= 16 and
           Enum.all?(reasons, &(is_binary(&1) and byte_size(&1) in 1..64)),
         do: [],
         else: [reason_codes: "must contain bounded reason codes"]
    end)
  end
end
