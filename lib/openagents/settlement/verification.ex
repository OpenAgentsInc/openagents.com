defmodule OpenAgents.Settlement.Verification do
  @moduledoc """
  The qualification receipt for one claim at one exact commit.

  A verification is append-only and pins the specification fingerprint and the
  commit it graded, so a later commit cannot inherit an earlier acceptance.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Settlement.Claim

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  @outcomes ~w(accepted rejected)

  @fields ~w(claim_id spec_fingerprint commit_sha work_job_ref verifier_ref
             verifier_policy_digest evidence_digest outcome reason_code auth_method
             decision_receipt_ref)a

  schema "settlement_verifications" do
    field :spec_fingerprint, :string
    field :commit_sha, :string
    field :work_job_ref, :string
    field :verifier_ref, :string
    field :verifier_policy_digest, :string
    field :evidence_digest, :string
    field :outcome, :string
    field :reason_code, :string
    field :auth_method, :string
    field :decision_receipt_ref, :string
    belongs_to :claim, Claim, type: :binary_id
    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc "Every verification outcome."
  def outcomes, do: @outcomes

  def changeset(record, attributes) do
    record
    |> cast(attributes, @fields)
    |> validate_required(@fields)
    |> validate_inclusion(:outcome, @outcomes)
    |> validate_format(:commit_sha, ~r/\A[0-9a-f]{40}\z/)
    |> validate_format(:spec_fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:verifier_policy_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:evidence_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_length(:verifier_ref, min: 1, max: 256)
    |> validate_length(:work_job_ref, min: 1, max: 256)
    |> validate_length(:reason_code, min: 1, max: 128)
    |> validate_length(:decision_receipt_ref, min: 1, max: 256)
    |> unique_constraint([:claim_id, :commit_sha])
    |> unique_constraint(:decision_receipt_ref)
    |> foreign_key_constraint(:claim_id)
  end
end
