defmodule OpenAgents.Repo.Migrations.CreateReputationSubjectClaims do
  use Ecto.Migration

  @moduledoc """
  Binds an attestation subject to an account.

  `reputation_attestations.subject_id` is a bare string the issuer supplies.
  Nothing resolved it, and nothing stopped it from resolving to two things.
  This table is the binding: a claim an account makes and an operator decides,
  the way `forum_actor_links` resolves a legacy forum identity.

  The kind lives here rather than on the attestation. The attestation's
  `subject_id` sits inside the Ed25519-signed claim, so a `subject_kind`
  column on `reputation_attestations` would either stay outside the signature
  — a field a verifier must not trust — or change the claim shape and
  invalidate every signature already published. REPUTATION-001 keeps
  verification independent of the interface, so the typing goes where a
  verifier never has to read it.
  """

  def change do
    create table(:reputation_subject_claims, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      # What the string names: an account on this forge, a legacy forum actor
      # that may have no account of its own, or a registered agent. Collapsing
      # the three is how a bare string got here.
      add :subject_kind, :string, null: false

      # The exact string `reputation_attestations.subject_id` carries.
      add :subject_id, :string, null: false

      add :user_id, references(:users, type: :uuid, on_delete: :restrict), null: false

      # The row in the namespace that already established this identity. One
      # per kind, and null for the kinds it does not describe.
      add :forum_actor_link_id, references(:forum_actor_links, type: :uuid, on_delete: :restrict)
      add :agent_id, references(:agents, type: :binary_id, on_delete: :restrict)

      add :status, :string, null: false, default: "pending"
      add :proof_method, :string
      add :proof_evidence, :map
      add :linked_at, :utc_datetime_usec
      add :rejected_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # A subject already claimed by one account cannot be claimed by another.
    # An attestation names its subject with the bare string, so the string
    # alone — not the kind and the string together — is what has to resolve to
    # at most one account. Two kinds carrying one string would put the
    # ambiguity straight back.
    create unique_index(:reputation_subject_claims, [:subject_id])
    create index(:reputation_subject_claims, [:user_id, :status])

    create constraint(:reputation_subject_claims, :reputation_subject_claims_kind_check,
             check: "subject_kind IN ('account', 'forum_actor', 'agent')"
           )

    create constraint(:reputation_subject_claims, :reputation_subject_claims_status_check,
             check: "status IN ('pending', 'linked', 'rejected')"
           )

    # One constraint per kind, in the database rather than in a changeset.
    # An `account` subject names the account itself, so the string is checkable
    # here and the operator has nothing to decide beyond that it is well
    # formed. A `forum_actor` or `agent` subject names a row in another
    # namespace, so the claim has to carry that row.
    create constraint(:reputation_subject_claims, :reputation_subject_claims_reference_check,
             check: """
             CASE subject_kind
               WHEN 'account' THEN
                 forum_actor_link_id IS NULL AND agent_id IS NULL
                 AND subject_id = 'user:' || user_id::text
               WHEN 'forum_actor' THEN
                 forum_actor_link_id IS NOT NULL AND agent_id IS NULL
               WHEN 'agent' THEN
                 agent_id IS NOT NULL AND forum_actor_link_id IS NULL
               ELSE false
             END
             """
           )
  end
end
