defmodule OpenAgents.Reputation do
  @moduledoc """
  Portable, revocable reputation attestations for accepted outcomes.

  An attestation is a signed claim that one subject completed, verified,
  reviewed, was paid for, or lost credit for one accepted outcome, under one
  admitted verifier policy, in one repository, at one revision. It is scoped
  evidence a stranger can check, never a global social score: nothing here
  derives credit from presence, token volume, online time, or narration, and
  no function returns a universal ranking.

  The context owns four operations:

    * `admit_policy/1` and `admit_key/1` record the verifier policy and the
      issuer public key an attestation binds to.
    * `issue/3` signs a claim, and only after the accepted-outcome contract it
      names reached an admitted terminal state.
    * `verify/2` recomputes the digest, checks the signature against the
      admitted key, and reports policy, binding, evidence, and revocation
      state. It trusts no column and no caller.
    * `revoke/4` and `correct/4` publish a linked invalidating event.

  A subject is a bare string inside the signed claim, so the context also
  owns the binding that resolves one to an account: `claim_subject/2`,
  `approve_subject_claim/1`, and `reject_subject_claim/1`. Only a `linked`
  claim resolves a subject, and `linked_subject_ids/1` is the one filter an
  account-scoped read may use.

  Reads project the stored claim verbatim, so a client can verify an
  attestation the forge serves without trusting the surface that displayed it.
  """

  import Ecto.Query

  alias OpenAgents.Compensation.OutcomeDecision
  alias OpenAgents.Forge.Visibility
  alias OpenAgents.Issues.Issue
  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Repo
  alias OpenAgents.Repositories.Repository
  alias OpenAgents.Accounts.User
  alias OpenAgents.Forum.ActorLink
  alias OpenAgents.Reputation.{Attestation, Claim, PolicyReceipt, SigningKey, SubjectClaim}

  @policy_id "openagents.reputation.verifier.v1"
  @policy_version 1
  @policy_rules %{
    "unit" => "scoped_evidence",
    "signature_algorithm" => "ed25519",
    "event_types" => Attestation.event_types(),
    "accepted_outcome_kinds" => ["compensation_outcome_decision"],
    "accepted_terminal_state" => "accepted",
    "minimum_confidence_ppm" => 500_000,
    "evidence_max_age_seconds" => 7_776_000,
    "evidence_kinds" => ["outcome", "issue", "repository", "attestation"],
    "global_score" => false
  }

  @doc "The verifier policy identifier every attestation binds to."
  def policy_id, do: @policy_id

  @doc "The rules of the current verifier policy version."
  def policy_rules, do: @policy_rules

  @doc "The digest of one policy version's rules."
  @spec policy_digest(String.t(), pos_integer(), map()) :: String.t()
  def policy_digest(policy_id, version, rules) do
    Canonical.digest!(%{"policy_id" => policy_id, "version" => version, "rules" => rules})
  end

  @doc """
  Admits the current verifier policy version under operator authority.

  The receipt is append-only, and its digest is what a client compares a
  claim's `verifier.policy_digest` against.
  """
  @spec admit_policy(map()) :: {:ok, PolicyReceipt.t()} | {:error, term()}
  def admit_policy(operator) do
    with :ok <- validate_operator(operator) do
      %PolicyReceipt{}
      |> PolicyReceipt.changeset(%{
        policy_id: @policy_id,
        version: @policy_version,
        policy_digest: policy_digest(@policy_id, @policy_version, @policy_rules),
        rules: @policy_rules,
        actor_id: operator.actor_id,
        auth_method: operator.auth_method,
        approval_receipt_ref: operator.approval_receipt_ref
      })
      |> Repo.insert()
    end
  end

  @doc "The admitted policy receipt for one version, if any."
  @spec policy(String.t(), pos_integer()) :: PolicyReceipt.t() | nil
  def policy(policy_id \\ @policy_id, version \\ @policy_version),
    do: Repo.get_by(PolicyReceipt, policy_id: policy_id, version: version)

  @doc "Every admitted policy version, oldest first."
  @spec policies() :: [PolicyReceipt.t()]
  def policies,
    do:
      Repo.all(
        from receipt in PolicyReceipt, order_by: [asc: receipt.policy_id, asc: receipt.version]
      )

  @doc """
  The published form of one policy version: the rules a client hashes to
  reproduce `policy_digest` itself.
  """
  @spec policy_projection(PolicyReceipt.t()) :: map()
  def policy_projection(%PolicyReceipt{} = receipt) do
    %{
      "policy_id" => receipt.policy_id,
      "version" => receipt.version,
      "policy_digest" => receipt.policy_digest,
      "rules" => receipt.rules,
      "admitted_at" => receipt.inserted_at
    }
  end

  @doc """
  Admits an issuer public key.

  Only the public half is stored. The private key stays in runtime
  configuration, so the table a verifier reads can never mint a claim.
  """
  @spec admit_key(map()) :: {:ok, SigningKey.t()} | {:error, term()}
  def admit_key(attributes) do
    public_key = Map.fetch!(attributes, :public_key)

    %SigningKey{}
    |> SigningKey.changeset(%{
      key_id: Map.get(attributes, :key_id) || Claim.key_id(public_key),
      algorithm: Map.get(attributes, :algorithm, Claim.algorithm()),
      public_key: public_key,
      issuer: Map.fetch!(attributes, :issuer),
      activated_at: Map.get(attributes, :activated_at) || DateTime.utc_now(),
      retired_at: Map.get(attributes, :retired_at)
    })
    |> Repo.insert()
  end

  @doc "Retires an issuer key. Attestations it already signed keep verifying."
  @spec retire_key(SigningKey.t(), DateTime.t()) :: {:ok, SigningKey.t()} | {:error, term()}
  def retire_key(%SigningKey{} = key, retired_at \\ DateTime.utc_now()) do
    key |> SigningKey.retire_changeset(retired_at) |> Repo.update()
  end

  @doc "Every admitted issuer key, for independent verification."
  @spec keys() :: [SigningKey.t()]
  def keys, do: Repo.all(from key in SigningKey, order_by: [asc: key.activated_at])

  @doc """
  Issues one attestation for an accepted outcome.

  `signer` carries the admitted `key_id` and the runtime-only `private_key`.
  Issuance fails when the outcome is missing or not accepted, when the key is
  unknown, retired, or does not match the admitted public key, when the
  confidence falls below the policy, when the requested transparency tier
  exceeds the repository's authority, or when the same issuer already
  attested this event for this subject and outcome.
  """
  @spec issue(PolicyReceipt.t(), map(), map()) :: {:ok, Attestation.t()} | {:error, term()}
  def issue(%PolicyReceipt{} = policy, signer, attributes) do
    with :ok <- validate_policy(policy),
         :ok <- validate_event_type(attributes[:event_type], attributes[:revokes_id]),
         :ok <- validate_confidence(policy, attributes[:confidence_ppm]),
         {:ok, repository} <- fetch_repository(attributes[:repository]),
         :ok <- validate_issue_number(repository, attributes[:issue_number]),
         :ok <- validate_tier(repository, attributes[:transparency_tier]),
         {:ok, evidence} <- validate_evidence(policy, repository, attributes[:evidence]),
         {:ok, outcome} <- resolve_outcome(policy, attributes[:outcome]),
         {:ok, key} <- fetch_signing_key(signer, attributes[:attested_at]) do
      persist(policy, key, signer, repository, outcome, evidence, attributes)
    end
  end

  @doc """
  Publishes a linked invalidating event for `attestation`.

  `event_type` is `reversal` for an outcome that was undone and `revocation`
  for a claim that should no longer count. The original row keeps its claim
  and signature; only its revocation fields are set, and only once.
  """
  @spec revoke(Attestation.t(), PolicyReceipt.t(), map(), map()) ::
          {:ok, %{revocation: Attestation.t(), attestation: Attestation.t()}} | {:error, term()}
  def revoke(%Attestation{} = attestation, %PolicyReceipt{} = policy, signer, attributes) do
    event_type = Map.get(attributes, :event_type, "revocation")
    reason_code = Map.get(attributes, :reason_code)

    with :ok <- validate_invalidating_event(event_type),
         :ok <- validate_reason_code(reason_code),
         :ok <- require_live(attestation) do
      Repo.transaction(fn ->
        case issue_invalidation(attestation, policy, signer, attributes, event_type) do
          {:ok, revocation} ->
            %{
              revocation: revocation,
              attestation: mark_revoked!(attestation, revocation, reason_code)
            }

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
    end
  end

  @doc """
  Corrects `attestation`: revokes it and issues a replacement that names the
  revoked claim digest in `supersedes`.
  """
  @spec correct(Attestation.t(), PolicyReceipt.t(), map(), map()) ::
          {:ok, %{revocation: Attestation.t(), correction: Attestation.t()}} | {:error, term()}
  def correct(%Attestation{} = attestation, %PolicyReceipt{} = policy, signer, attributes) do
    reason_code = Map.get(attributes, :reason_code, "corrected")

    Repo.transaction(fn ->
      with {:ok, revoked} <-
             revoke(attestation, policy, signer, %{
               event_type: "revocation",
               reason_code: reason_code,
               subject_id: attestation.subject_id
             }),
           {:ok, correction} <-
             issue(
               policy,
               signer,
               attributes
               |> Map.put(:supersedes_digest, attestation.claim_digest)
               |> Map.put_new(:evidence, evidence_for_link(attestation))
             ) do
        %{revocation: revoked.revocation, correction: correction}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Verifies one attestation the way a skeptical client does: recompute the
  claim digest, check the Ed25519 signature against the admitted public key,
  compare the policy and the binding, resolve the evidence, and read the
  revocation state.

  `expectation` is what the caller believes it is looking at — any of
  `:repository`, `:issue_number`, `:subject_id`, `:revision`, `:event_type`,
  `:outcome_ref`, or `:policy_id`. A mismatch is reported, which is what stops
  a valid attestation from being replayed for another issue, revision,
  verifier, or actor.
  """
  @spec verify(Attestation.t() | String.t(), map()) :: map()
  def verify(attestation, expectation \\ %{})

  def verify(claim_digest, expectation) when is_binary(claim_digest) do
    case Repo.get_by(Attestation, claim_digest: claim_digest) do
      nil ->
        %{"claim_digest" => claim_digest, "verified" => false, "reasons" => ["unknown_claim"]}

      attestation ->
        verify(attestation, expectation)
    end
  end

  def verify(%Attestation{} = attestation, expectation) do
    attestation = Repo.preload(attestation, :repository)
    key = Repo.get_by(SigningKey, key_id: attestation.issuer_key_id)
    digest_match? = Canonical.digest!(attestation.claim) == attestation.claim_digest
    signature = signature_report(attestation, key, digest_match?)
    policy = policy_report(attestation)
    binding = binding_report(attestation, expectation)
    evidence = evidence_report(attestation)
    revocation = revocation_report(attestation)

    report = %{
      "attestation_id" => attestation.id,
      "claim_digest" => attestation.claim_digest,
      "digest_match" => digest_match?,
      "signature" => signature,
      "policy" => policy,
      "binding" => binding,
      "evidence" => evidence,
      "revocation" => revocation
    }

    Map.put(report, "verified", verified?(report))
  end

  @doc """
  The published form of one attestation: the exact signed claim, its
  signature, and the state a verifier needs. The claim is the stored object,
  never a rendering of it.
  """
  @spec projection(Attestation.t()) :: map()
  def projection(%Attestation{} = attestation) do
    %{
      "id" => attestation.id,
      "claim" => attestation.claim,
      "claim_digest" => attestation.claim_digest,
      "signature" => attestation.signature,
      "signature_algorithm" => attestation.signature_algorithm,
      "event_type" => attestation.event_type,
      "subject_id" => attestation.subject_id,
      "issuer_key_id" => attestation.issuer_key_id,
      "transparency_tier" => attestation.transparency_tier,
      "attested_at" => attestation.attested_at,
      "supersedes" => attestation.supersedes_digest,
      "revokes" => attestation.revokes_id,
      "revocation" => %{
        "revoked" => not is_nil(attestation.revoked_at),
        "revoked_at" => attestation.revoked_at,
        "reason_code" => attestation.revocation_reason_code
      }
    }
  end

  @doc "The published form of one admitted key."
  @spec key_projection(SigningKey.t()) :: map()
  def key_projection(%SigningKey{} = key) do
    %{
      "key_id" => key.key_id,
      "algorithm" => key.algorithm,
      "public_key" => key.public_key,
      "issuer" => key.issuer,
      "activated_at" => key.activated_at,
      "retired_at" => key.retired_at,
      "status" => if(is_nil(key.retired_at), do: "active", else: "retired")
    }
  end

  @doc """
  The attestations on one issue that `tiers` may disclose.

  A `repository` tier attestation discloses evidence references to repository
  members, so callers pass the tiers the reader holds authority for.
  """
  @spec list_for_issue(Repository.t(), pos_integer(), [String.t()]) :: [Attestation.t()]
  def list_for_issue(%Repository{id: repository_id}, issue_number, tiers) do
    Repo.all(
      from attestation in Attestation,
        where:
          attestation.repository_id == ^repository_id and
            attestation.issue_number == ^issue_number and
            attestation.transparency_tier in ^tiers,
        order_by: [asc: attestation.attested_at, asc: attestation.id]
    )
  end

  @doc "One attestation in one repository, or `nil`."
  @spec get(Repository.t(), String.t(), [String.t()]) :: Attestation.t() | nil
  def get(%Repository{id: repository_id}, id, tiers) do
    Repo.one(
      from attestation in Attestation,
        where:
          attestation.repository_id == ^repository_id and attestation.id == ^id and
            attestation.transparency_tier in ^tiers
    )
  rescue
    Ecto.Query.CastError -> nil
  end

  @doc """
  Scoped evidence about one subject in one repository.

  The projection counts live and revoked events per policy inside one
  repository. `score` is always `nil`: a ranking system may weigh these
  counts, but nothing here publishes a universal number, and evidence from
  one repository never leaks into another's summary.
  """
  @spec subject_evidence(String.t(), Repository.t()) :: map()
  def subject_evidence(subject_id, %Repository{} = repository) do
    attestations =
      Repo.all(
        from attestation in Attestation,
          where:
            attestation.repository_id == ^repository.id and
              attestation.subject_id == ^subject_id
      )

    {live, revoked} = Enum.split_with(attestations, &is_nil(&1.revoked_at))

    %{
      "subject_id" => subject_id,
      "scope" => "repository",
      "repository" => path(repository),
      "policy_id" => @policy_id,
      "counts" => Enum.frequencies_by(live, & &1.event_type),
      "revoked" => length(revoked),
      "score" => nil
    }
  end

  ## ── the subject binding ────────────────────────────────────────────────

  @doc """
  Records an account's claim on an attestation subject.

  The claim starts `pending`: nothing has established that the subject is this
  account's, so nothing resolves yet. `attributes` carries `:subject_kind`,
  `:subject_id`, and for the two kinds that name another namespace, the row
  that already established the identity — `:forum_actor_link_id` for a legacy
  forum actor, `:agent_id` for an agent.

  The cross-namespace checks live here because a `CHECK` constraint cannot read
  another table: a `forum_actor` claim must name a `linked` `forum_actor_links`
  row belonging to this account whose `actor_ref` is the subject, and an
  `agent` claim must name a `linked` `agent_user_links` row for this account.
  The shape checks — which kind admits which reference, and that an `account`
  subject is this account's own actor reference — are constraints on the table.
  """
  @spec claim_subject(User.t(), map()) :: {:ok, SubjectClaim.t()} | {:error, term()}
  def claim_subject(%User{} = user, attributes) do
    attributes = Map.new(attributes, fn {key, value} -> {to_string(key), value} end)

    with :ok <- validate_subject_reference(user, attributes) do
      %SubjectClaim{}
      |> SubjectClaim.changeset(
        Map.merge(attributes, %{
          "user_id" => user.id,
          "status" => "pending",
          "proof_evidence" => %{"started_at" => DateTime.to_iso8601(DateTime.utc_now())}
        })
      )
      |> Repo.insert()
    end
  end

  @doc "Approves a pending subject claim after its proof has been checked."
  @spec approve_subject_claim(SubjectClaim.t()) :: {:ok, SubjectClaim.t()} | {:error, term()}
  def approve_subject_claim(%SubjectClaim{status: "pending"} = claim) do
    now = DateTime.utc_now()

    claim
    |> SubjectClaim.changeset(%{
      status: "linked",
      linked_at: now,
      proof_evidence:
        Map.put(claim.proof_evidence || %{}, "approved_at", DateTime.to_iso8601(now))
    })
    |> Repo.update()
  end

  def approve_subject_claim(%SubjectClaim{}), do: {:error, :not_pending}

  @doc "Rejects a pending subject claim."
  @spec reject_subject_claim(SubjectClaim.t()) :: {:ok, SubjectClaim.t()} | {:error, term()}
  def reject_subject_claim(%SubjectClaim{status: "pending"} = claim) do
    claim
    |> SubjectClaim.changeset(%{status: "rejected", rejected_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def reject_subject_claim(%SubjectClaim{}), do: {:error, :not_pending}

  @doc "Every subject claim this account made, newest first."
  @spec list_subject_claims(User.t()) :: [SubjectClaim.t()]
  def list_subject_claims(%User{id: user_id}) do
    Repo.all(
      from claim in SubjectClaim,
        where: claim.user_id == ^user_id,
        order_by: [desc: claim.inserted_at, desc: claim.id]
    )
  end

  @doc "Every subject claim still waiting on an operator, oldest first."
  @spec list_pending_subject_claims() :: [SubjectClaim.t()]
  def list_pending_subject_claims do
    Repo.all(
      from claim in SubjectClaim,
        where: claim.status == "pending",
        order_by: [asc: claim.inserted_at, asc: claim.id]
    )
  end

  @doc "The subject claim behind `id`, or `{:error, :not_found}`."
  @spec fetch_subject_claim(String.t()) :: {:ok, SubjectClaim.t()} | {:error, :not_found}
  def fetch_subject_claim(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Repo.get(SubjectClaim, uuid) do
          %SubjectClaim{} = claim -> {:ok, claim}
          nil -> {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  The subject strings this account has established.

  Only a `linked` claim resolves a subject, so a pending or rejected claim
  widens nothing. An account with no linked claim gets `[]`, and a read
  filtered on `[]` returns nothing rather than everything.
  """
  @spec linked_subject_ids(User.t()) :: [String.t()]
  def linked_subject_ids(%User{id: user_id}) do
    Repo.all(
      from claim in SubjectClaim,
        where: claim.user_id == ^user_id and claim.status == "linked",
        select: claim.subject_id,
        order_by: [asc: claim.subject_id]
    )
  end

  @doc "The public projection of one subject claim."
  @spec subject_claim_projection(SubjectClaim.t()) :: map()
  def subject_claim_projection(%SubjectClaim{} = claim) do
    %{
      "id" => claim.id,
      "subject_kind" => claim.subject_kind,
      "subject_id" => claim.subject_id,
      "status" => claim.status,
      "proof_method" => claim.proof_method,
      "forum_actor_link_id" => claim.forum_actor_link_id,
      "agent_id" => claim.agent_id,
      "claimed_at" => iso8601(claim.inserted_at),
      "linked_at" => iso8601(claim.linked_at),
      "rejected_at" => iso8601(claim.rejected_at)
    }
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = at), do: DateTime.to_iso8601(at)

  # An `account` subject is checked by the table: the string has to be this
  # account's own actor reference. The other two kinds name a row in another
  # namespace, and only a link that namespace already established counts.
  defp validate_subject_reference(_user, %{"subject_kind" => "account"}), do: :ok

  defp validate_subject_reference(user, %{"subject_kind" => "forum_actor"} = attributes) do
    link =
      Repo.get_by(ActorLink,
        id: cast_uuid(attributes["forum_actor_link_id"]),
        user_id: user.id,
        status: "linked"
      )

    cond do
      is_nil(link) -> {:error, :forum_actor_not_linked}
      link.actor_ref != attributes["subject_id"] -> {:error, :subject_is_not_the_actor_ref}
      true -> :ok
    end
  end

  defp validate_subject_reference(user, %{"subject_kind" => "agent"} = attributes) do
    linked? =
      Repo.exists?(
        from link in OpenAgents.Agents.AgentUserLink,
          where:
            link.agent_id == ^cast_uuid(attributes["agent_id"]) and
              link.user_id == ^user.id and link.status == "linked"
      )

    if linked?, do: :ok, else: {:error, :agent_not_linked}
  end

  defp validate_subject_reference(_user, _attributes), do: {:error, :unsupported_subject_kind}

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> Ecto.UUID.generate()
    end
  end

  defp persist(policy, key, signer, repository, outcome, evidence, attributes) do
    attested_at = attributes[:attested_at] || DateTime.utc_now()

    claim =
      Claim.build(%{
        event_type: attributes[:event_type],
        issuer_key_id: key.key_id,
        issuer_public_key: key.public_key,
        subject_id: attributes[:subject_id],
        outcome_kind: outcome.kind,
        outcome_ref: outcome.ref,
        outcome_digest: outcome.digest,
        outcome_state: outcome.state,
        repository: path(repository),
        repository_id: repository.id,
        issue_number: attributes[:issue_number],
        revision: attributes[:revision],
        artifact_digest: attributes[:artifact_digest],
        policy_id: policy.policy_id,
        policy_version: policy.version,
        policy_digest: policy.policy_digest,
        confidence_ppm: attributes[:confidence_ppm],
        transparency_tier: attributes[:transparency_tier],
        evidence: evidence,
        attested_at: attested_at,
        nonce: attributes[:nonce] || Claim.nonce(),
        supersedes_digest: attributes[:supersedes_digest]
      })

    with {:ok, digest} <- Claim.digest(claim),
         {:ok, signature} <- Claim.sign(claim, Map.fetch!(signer, :private_key)) do
      %Attestation{}
      |> Attestation.changeset(%{
        repository_id: repository.id,
        issue_number: attributes[:issue_number],
        event_type: attributes[:event_type],
        subject_id: attributes[:subject_id],
        issuer_key_id: key.key_id,
        outcome_kind: outcome.kind,
        outcome_ref: outcome.ref,
        outcome_digest: outcome.digest,
        revision: attributes[:revision],
        artifact_digest: attributes[:artifact_digest],
        policy_id: policy.policy_id,
        policy_version: policy.version,
        policy_digest: policy.policy_digest,
        confidence_ppm: attributes[:confidence_ppm],
        transparency_tier: attributes[:transparency_tier],
        attested_at: attested_at,
        nonce: claim["nonce"],
        claim: claim,
        claim_digest: digest,
        signature: signature,
        signature_algorithm: Claim.algorithm(),
        supersedes_digest: attributes[:supersedes_digest],
        revokes_id: attributes[:revokes_id]
      })
      |> Repo.insert()
    end
  end

  defp issue_invalidation(attestation, policy, signer, attributes, event_type) do
    attestation = Repo.preload(attestation, :repository)

    issue(
      policy,
      signer,
      %{
        event_type: event_type,
        subject_id: Map.get(attributes, :subject_id, attestation.subject_id),
        outcome: %{kind: attestation.outcome_kind, ref: attestation.outcome_ref},
        repository: attestation.repository,
        issue_number: attestation.issue_number,
        revision: attestation.revision,
        artifact_digest: attestation.artifact_digest,
        confidence_ppm: Map.get(attributes, :confidence_ppm, 1_000_000),
        transparency_tier: attestation.transparency_tier,
        evidence: Map.get(attributes, :evidence) || evidence_for_link(attestation),
        supersedes_digest: attestation.claim_digest,
        revokes_id: attestation.id
      }
    )
  end

  defp mark_revoked!(attestation, revocation, reason_code) do
    attestation
    |> Attestation.revocation_changeset(%{
      revoked_at: revocation.attested_at,
      revocation_reason_code: reason_code,
      revoked_by_id: revocation.id
    })
    |> Repo.update!()
  end

  defp evidence_for_link(%Attestation{} = attestation) do
    [
      %{
        "kind" => "attestation",
        "ref" => attestation.claim_digest,
        "digest" => attestation.claim_digest,
        "observed_at" => DateTime.to_iso8601(attestation.attested_at)
      }
    ]
  end

  defp signature_report(attestation, nil, _digest_match?) do
    %{"valid" => false, "key_id" => attestation.issuer_key_id, "key_status" => "unknown"}
  end

  defp signature_report(attestation, %SigningKey{} = key, digest_match?) do
    valid? =
      digest_match? and
        attestation.signature_algorithm == key.algorithm and
        Claim.valid_signature?(attestation.claim, attestation.signature, key.public_key)

    %{
      "valid" => valid?,
      "key_id" => key.key_id,
      "key_status" => if(is_nil(key.retired_at), do: "active", else: "retired"),
      "key_active_at_attestation" => SigningKey.active_at?(key, attestation.attested_at)
    }
  end

  defp policy_report(attestation) do
    admitted =
      Repo.get_by(PolicyReceipt,
        policy_id: attestation.policy_id,
        version: attestation.policy_version
      )

    current = current_policy_version(attestation.policy_id)

    %{
      "policy_id" => attestation.policy_id,
      "version" => attestation.policy_version,
      "current_version" => current,
      "admitted" => not is_nil(admitted),
      "digest_match" =>
        not is_nil(admitted) and admitted.policy_digest == attestation.policy_digest,
      "superseded" => not is_nil(current) and current > attestation.policy_version
    }
  end

  defp current_policy_version(policy_id) do
    Repo.one(
      from receipt in PolicyReceipt,
        where: receipt.policy_id == ^policy_id,
        select: max(receipt.version)
    )
  end

  defp binding_report(attestation, expectation) do
    claimed = %{
      repository: attestation.claim["scope"]["repository"],
      issue_number: attestation.claim["scope"]["issue_number"],
      revision: attestation.claim["scope"]["revision"],
      subject_id: attestation.claim["subject"]["actor_id"],
      event_type: attestation.claim["event_type"],
      outcome_ref: attestation.claim["outcome"]["ref"],
      policy_id: attestation.claim["verifier"]["policy_id"]
    }

    mismatches =
      expectation
      |> Enum.filter(fn {field, expected} -> Map.get(claimed, field) != expected end)
      |> Enum.map(fn {field, expected} ->
        %{
          "field" => to_string(field),
          "expected" => expected,
          "claimed" => Map.get(claimed, field)
        }
      end)

    columns_match? =
      claimed.repository == path(attestation.repository) and
        claimed.issue_number == attestation.issue_number and
        claimed.subject_id == attestation.subject_id and
        claimed.event_type == attestation.event_type and
        claimed.revision == attestation.revision

    %{
      "matches" => mismatches == [] and columns_match?,
      "claim_matches_columns" => columns_match?,
      "mismatches" => mismatches
    }
  end

  defp evidence_report(attestation) do
    max_age = policy_rule(attestation, "evidence_max_age_seconds")

    entries =
      Enum.map(attestation.claim["evidence"] || [], fn entry ->
        age = evidence_age(entry, attestation.attested_at)

        Map.merge(entry, %{
          "available" => evidence_available?(entry, attestation),
          "age_seconds" => age,
          "stale" => is_integer(age) and is_integer(max_age) and age > max_age
        })
      end)

    %{
      "entries" => entries,
      "available" => entries != [] and Enum.all?(entries, & &1["available"]),
      "stale" => Enum.any?(entries, & &1["stale"])
    }
  end

  defp policy_rule(attestation, rule) do
    case Repo.get_by(PolicyReceipt,
           policy_id: attestation.policy_id,
           version: attestation.policy_version
         ) do
      nil -> Map.get(@policy_rules, rule)
      receipt -> Map.get(receipt.rules, rule)
    end
  end

  defp evidence_age(entry, attested_at) do
    with observed when is_binary(observed) <- entry["observed_at"],
         {:ok, observed_at, _offset} <- DateTime.from_iso8601(observed) do
      DateTime.diff(attested_at, observed_at)
    else
      _other -> nil
    end
  end

  defp evidence_available?(%{"disclosed" => false}, _attestation), do: false

  defp evidence_available?(entry, attestation) do
    case entry["kind"] do
      "outcome" ->
        resolvable_outcome?(attestation.outcome_kind, entry["ref"])

      "issue" ->
        issue_exists?(attestation.repository_id, entry["ref"])

      "repository" ->
        entry["ref"] == path(attestation.repository)

      "attestation" ->
        digest = entry["ref"]
        Repo.exists?(from other in Attestation, where: other.claim_digest == ^digest)

      _other ->
        false
    end
  end

  defp resolvable_outcome?("compensation_outcome_decision", ref) when is_binary(ref),
    do:
      Repo.exists?(from decision in OutcomeDecision, where: decision.decision_receipt_ref == ^ref)

  defp resolvable_outcome?(_kind, _ref), do: false

  defp issue_exists?(repository_id, ref) when is_binary(ref) do
    case Integer.parse(ref |> String.split("#") |> List.last() || "") do
      {number, ""} ->
        Repo.exists?(
          from issue in Issue,
            where: issue.repository_id == ^repository_id and issue.number == ^number
        )

      _other ->
        false
    end
  end

  defp issue_exists?(_repository_id, _ref), do: false

  defp revocation_report(attestation) do
    %{
      "revoked" => not is_nil(attestation.revoked_at),
      "revoked_at" => attestation.revoked_at,
      "reason_code" => attestation.revocation_reason_code,
      "revoked_by" => attestation.revoked_by_id,
      "supersedes" => attestation.supersedes_digest
    }
  end

  defp verified?(report) do
    private? = report["evidence"]["entries"] |> Enum.any?(&(&1["disclosed"] == false))

    report["digest_match"] and report["signature"]["valid"] and
      report["signature"]["key_active_at_attestation"] == true and
      report["policy"]["digest_match"] and report["binding"]["matches"] and
      not report["revocation"]["revoked"] and not report["evidence"]["stale"] and
      (report["evidence"]["available"] or private?)
  end

  defp validate_policy(%PolicyReceipt{} = policy) do
    expected = policy_digest(policy.policy_id, policy.version, policy.rules)

    if expected == policy.policy_digest, do: :ok, else: {:error, :policy_digest_mismatch}
  end

  # An invalidating event exists only as the linked successor of the claim it
  # invalidates, so it carries the attestation it revokes.
  defp validate_event_type(event_type, revokes_id) do
    invalidating? = event_type in Attestation.invalidating_event_types()

    cond do
      event_type not in Attestation.event_types() -> {:error, :event_type_unsupported}
      invalidating? and is_nil(revokes_id) -> {:error, :invalidation_requires_prior_attestation}
      not invalidating? and not is_nil(revokes_id) -> {:error, :event_type_not_invalidating}
      true -> :ok
    end
  end

  defp validate_invalidating_event(event_type) do
    if event_type in Attestation.invalidating_event_types(),
      do: :ok,
      else: {:error, :event_type_not_invalidating}
  end

  defp validate_reason_code(code) when is_binary(code) and byte_size(code) > 0, do: :ok
  defp validate_reason_code(_code), do: {:error, :reason_code_required}

  defp validate_confidence(policy, confidence) when is_integer(confidence) do
    minimum = Map.get(policy.rules, "minimum_confidence_ppm", 0)

    cond do
      confidence < 0 or confidence > 1_000_000 -> {:error, :confidence_out_of_range}
      confidence < minimum -> {:error, :confidence_below_policy}
      true -> :ok
    end
  end

  defp validate_confidence(_policy, _confidence), do: {:error, :confidence_required}

  defp fetch_repository(%Repository{} = repository), do: {:ok, repository}
  defp fetch_repository(_other), do: {:error, :repository_required}

  defp validate_issue_number(repository, number) when is_integer(number) and number > 0 do
    if Repo.exists?(
         from issue in Issue,
           where: issue.repository_id == ^repository.id and issue.number == ^number
       ),
       do: :ok,
       else: {:error, :issue_not_found}
  end

  defp validate_issue_number(_repository, _number), do: {:error, :issue_number_required}

  defp validate_tier(repository, tier) do
    cond do
      tier not in Attestation.transparency_tiers() ->
        {:error, :transparency_tier_unsupported}

      tier == "public" and not public_disclosure?(repository) ->
        {:error, :transparency_tier_exceeds_repository_authority}

      true ->
        :ok
    end
  end

  defp public_disclosure?(repository) do
    repository.visibility == "public" or Visibility.allows?(repository.name, :ledger)
  end

  defp validate_evidence(policy, repository, entries) when is_list(entries) and entries != [] do
    kinds = Map.get(policy.rules, "evidence_kinds", [])

    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, validated} ->
      normalized = Map.new(entry, fn {key, value} -> {to_string(key), value} end)

      case validate_evidence_entry(normalized, kinds, repository) do
        :ok -> {:cont, {:ok, [normalized | validated]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, validated} -> {:ok, Enum.reverse(validated)}
      error -> error
    end
  end

  defp validate_evidence(_policy, _repository, _entries), do: {:error, :evidence_required}

  defp validate_evidence_entry(entry, kinds, repository) do
    cond do
      entry["kind"] not in kinds ->
        {:error, :evidence_kind_unsupported}

      not is_binary(entry["ref"]) or entry["ref"] == "" ->
        {:error, :evidence_ref_required}

      not valid_digest?(entry["digest"]) ->
        {:error, :evidence_digest_invalid}

      not valid_timestamp?(entry["observed_at"]) ->
        {:error, :evidence_observed_at_invalid}

      entry["kind"] in ~w(issue repository) and not repository_scoped?(entry["ref"], repository) ->
        {:error, :evidence_outside_repository_authority}

      true ->
        :ok
    end
  end

  defp repository_scoped?(ref, repository) do
    path = path(repository)

    ref == path or String.starts_with?(ref, path <> "#")
  end

  defp valid_digest?(digest) when is_binary(digest),
    do: Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)

  defp valid_digest?(_digest), do: false

  defp valid_timestamp?(value) when is_binary(value) do
    match?({:ok, _instant, _offset}, DateTime.from_iso8601(value))
  end

  defp valid_timestamp?(_value), do: false

  # The accepted-outcome contract. `compensation_outcome_decision` is the
  # accepted-outcome receipt the application records today; verified bounty
  # settlement adds one clause here and no new attestation semantics.
  defp resolve_outcome(policy, %{kind: kind, ref: ref}) when is_binary(kind) and is_binary(ref) do
    if kind in Map.get(policy.rules, "accepted_outcome_kinds", []) do
      resolve_outcome_state(policy, kind, ref)
    else
      {:error, :outcome_kind_unsupported}
    end
  end

  defp resolve_outcome(_policy, _outcome), do: {:error, :outcome_required}

  defp resolve_outcome_state(policy, "compensation_outcome_decision" = kind, ref) do
    terminal = Map.get(policy.rules, "accepted_terminal_state")

    case Repo.get_by(OutcomeDecision, decision_receipt_ref: ref) do
      nil ->
        {:error, :outcome_not_found}

      %OutcomeDecision{decision: ^terminal} = decision ->
        {:ok, %{kind: kind, ref: ref, digest: decision.outcome_digest, state: decision.decision}}

      %OutcomeDecision{} ->
        {:error, :outcome_not_accepted}
    end
  end

  defp fetch_signing_key(signer, attested_at) do
    instant = attested_at || DateTime.utc_now()
    private_key = Map.get(signer, :private_key)

    with {:ok, key} <- lookup_key(Map.get(signer, :key_id)),
         :ok <- require_active_key(key, instant),
         :ok <- require_matching_key(key, private_key) do
      {:ok, key}
    end
  end

  defp lookup_key(key_id) when is_binary(key_id) do
    case Repo.get_by(SigningKey, key_id: key_id) do
      nil -> {:error, :signing_key_unknown}
      key -> {:ok, key}
    end
  end

  defp lookup_key(_key_id), do: {:error, :signing_key_required}

  defp require_active_key(key, instant) do
    if SigningKey.active_at?(key, instant), do: :ok, else: {:error, :signing_key_retired}
  end

  defp require_matching_key(key, private_key) when is_binary(private_key) do
    if Claim.public_key_for(private_key) == key.public_key,
      do: :ok,
      else: {:error, :signing_key_mismatch}
  end

  defp require_matching_key(_key, _private_key), do: {:error, :private_key_required}

  defp require_live(%Attestation{revoked_at: nil}), do: :ok
  defp require_live(%Attestation{}), do: {:error, :already_revoked}

  defp validate_operator(%{authenticated: true} = operator) do
    required = [:actor_id, :auth_method, :approval_receipt_ref]

    if Enum.all?(required, &is_binary(Map.get(operator, &1))),
      do: :ok,
      else: {:error, :operator_receipt_incomplete}
  end

  defp validate_operator(_operator), do: {:error, :operator_unauthenticated}

  defp path(%Repository{owner: owner, name: name}), do: "#{owner}/#{name}"
end
