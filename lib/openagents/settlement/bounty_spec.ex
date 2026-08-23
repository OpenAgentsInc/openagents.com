defmodule OpenAgents.Settlement.BountySpec do
  @moduledoc """
  One priced specification for one forge issue, fingerprinted before a claim.

  Revisions are append-only. Repricing an issue writes a new revision with a
  new fingerprint, which strands every claim pinned to the previous
  fingerprint instead of paying against a specification nobody agreed to.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Issues.Issue
  alias OpenAgents.Settlement.TreasuryPolicy

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  @fields ~w(treasury_policy_id issue_id revision buyer_ref amount_sats acceptance_criteria
             verification_policy destination_kind expires_at spec_fingerprint actor_id
             auth_method approval_receipt_ref)a

  schema "settlement_bounty_specs" do
    field :revision, :integer
    field :buyer_ref, :string
    field :amount_sats, :integer
    field :acceptance_criteria, {:array, :string}
    field :verification_policy, :map
    field :destination_kind, :string
    field :expires_at, :utc_datetime_usec
    field :spec_fingerprint, :string
    field :actor_id, :string
    field :auth_method, :string
    field :approval_receipt_ref, :string
    belongs_to :treasury_policy, TreasuryPolicy, type: :binary_id
    belongs_to :issue, Issue
    timestamps()
  end

  @type t :: %__MODULE__{}

  def changeset(record, attributes) do
    record
    |> cast(attributes, @fields)
    |> validate_required(@fields)
    |> validate_number(:revision, greater_than: 0)
    |> validate_number(:amount_sats, greater_than: 0)
    |> validate_format(:spec_fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> validate_length(:buyer_ref, min: 1, max: 256)
    |> validate_length(:destination_kind, min: 1, max: 64)
    |> validate_length(:acceptance_criteria, min: 1)
    |> validate_length(:approval_receipt_ref, min: 1, max: 256)
    |> unique_constraint([:issue_id, :revision])
    |> unique_constraint(:spec_fingerprint)
    |> unique_constraint(:approval_receipt_ref)
    |> foreign_key_constraint(:issue_id)
    |> foreign_key_constraint(:treasury_policy_id)
  end
end
