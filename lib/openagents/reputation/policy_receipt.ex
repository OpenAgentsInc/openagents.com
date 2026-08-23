defmodule OpenAgents.Reputation.PolicyReceipt do
  @moduledoc "The admitted verifier policy one attestation was issued under."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "reputation_verifier_policies" do
    field :policy_id, :string
    field :version, :integer
    field :policy_digest, :string
    field :rules, :map
    field :actor_id, :string
    field :auth_method, :string
    field :approval_receipt_ref, :string
    timestamps()
  end

  @type t :: %__MODULE__{}

  def changeset(record, attributes) do
    fields =
      ~w(policy_id version policy_digest rules actor_id auth_method approval_receipt_ref)a

    record
    |> cast(attributes, fields)
    |> validate_required(fields)
    |> validate_number(:version, greater_than: 0)
    |> validate_format(:policy_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_length(:policy_id, min: 1, max: 128)
    |> validate_length(:actor_id, min: 1, max: 256)
    |> validate_length(:auth_method, min: 1, max: 128)
    |> validate_length(:approval_receipt_ref, min: 1, max: 256)
    |> unique_constraint([:policy_id, :version])
    |> unique_constraint(:approval_receipt_ref)
  end
end
