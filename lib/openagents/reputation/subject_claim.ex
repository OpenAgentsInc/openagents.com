defmodule OpenAgents.Reputation.SubjectClaim do
  @moduledoc """
  One account's claim on one attestation subject.

  `OpenAgents.Reputation.Attestation` names its subject with a bare string the
  issuer supplies. This row says what that string names and which account holds
  it, and only a `linked` status resolves it — the rule
  `OpenAgents.Forum.ActorLink` already applies to a legacy forum identity.

  A subject is one of three things, and collapsing them is what produced a bare
  string in the first place:

    * `account` — this forge's own actor reference, `user:<account-id>`. The
      string names the account, so the database checks it rather than an
      operator.
    * `forum_actor` — a legacy forum identity that may have no account of its
      own. The claim carries the `forum_actor_links` row that established it.
    * `agent` — a registered agent. The claim carries the `agents` row.

  The kind is not on the attestation. An attestation's `subject_id` is inside
  the signed claim, so a kind column there would either go unsigned or
  invalidate every published signature.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias OpenAgents.Accounts.User
  alias OpenAgents.Agents.Agent
  alias OpenAgents.Forum.ActorLink

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @subject_kinds ~w(account forum_actor agent)
  @statuses ~w(pending linked rejected)

  schema "reputation_subject_claims" do
    field :subject_kind, :string
    field :subject_id, :string
    field :status, :string, default: "pending"
    field :proof_method, :string
    field :proof_evidence, :map
    field :linked_at, :utc_datetime_usec
    field :rejected_at, :utc_datetime_usec

    belongs_to :user, User
    belongs_to :forum_actor_link, ActorLink
    belongs_to :agent, Agent

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def subject_kinds, do: @subject_kinds
  def statuses, do: @statuses

  def changeset(claim, attributes) do
    claim
    |> cast(
      attributes,
      ~w(subject_kind subject_id user_id forum_actor_link_id agent_id status proof_method
         proof_evidence linked_at rejected_at)a
    )
    |> validate_required(~w(subject_kind subject_id user_id status)a)
    |> validate_inclusion(:subject_kind, @subject_kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:subject_id, min: 1, max: 256)
    |> unique_constraint(:subject_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:forum_actor_link_id)
    |> foreign_key_constraint(:agent_id)
    |> check_constraint(:subject_kind, name: :reputation_subject_claims_kind_check)
    |> check_constraint(:status, name: :reputation_subject_claims_status_check)
    |> check_constraint(:subject_id, name: :reputation_subject_claims_reference_check)
  end
end
