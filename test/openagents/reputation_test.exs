defmodule OpenAgents.ReputationTest do
  use OpenAgents.DataCase, async: false

  import OpenAgents.CompensationFixtures
  import OpenAgents.IssuesFixtures

  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Reputation
  alias OpenAgents.Reputation.{Attestation, Claim, PolicyReceipt}

  setup do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    assert {:ok, policy} = Reputation.admit_policy(operator("policy"))
    keypair = Claim.generate_keypair()

    assert {:ok, key} =
             Reputation.admit_key(%{public_key: keypair.public_key, issuer: "verifier"})

    %{
      repository: repository,
      issue: issue,
      policy: policy,
      key: key,
      signer: %{key_id: key.key_id, private_key: keypair.private_key}
    }
  end

  test "an accepted outcome yields a signed claim a stranger can verify", context do
    decision = outcome_decision_fixture()

    assert {:ok, attestation} = issue!(context, decision, subject_id: "actor:builder")

    assert attestation.event_type == "completion"
    assert attestation.claim["schema"] == Claim.schema()
    assert attestation.claim["outcome"]["state"] == "accepted"
    assert attestation.claim["verifier"]["policy_digest"] == context.policy.policy_digest
    assert attestation.claim_digest == Canonical.digest!(attestation.claim)

    # The signature check uses only the published claim, the published
    # signature, and the published public key.
    published = Reputation.projection(attestation)
    key = Enum.find(Reputation.keys(), &(&1.key_id == attestation.issuer_key_id))

    assert Claim.valid_signature?(
             published["claim"],
             published["signature"],
             Reputation.key_projection(key)["public_key"]
           )

    report = Reputation.verify(attestation, %{subject_id: "actor:builder"})
    assert report["verified"]
    assert report["signature"]["valid"]
    assert report["policy"]["digest_match"]
    assert report["binding"]["matches"]
    assert report["evidence"]["available"]
    refute report["revocation"]["revoked"]
  end

  test "a rejected or unknown outcome never earns an attestation", context do
    rejected = outcome_decision_fixture("rejected", "utility_failed")

    assert {:error, :outcome_not_accepted} = issue!(context, rejected)

    assert {:error, :outcome_not_found} =
             Reputation.issue(
               context.policy,
               context.signer,
               attributes(context, "outcome-decision:absent", digest())
             )
  end

  test "presence, token volume, and narration are not attestable", context do
    decision = outcome_decision_fixture()

    for kind <- ~w(presence online_time token_volume narration) do
      attributes =
        context
        |> attributes(decision.decision_receipt_ref, decision.outcome_digest)
        |> Map.put(:outcome, %{kind: kind, ref: decision.decision_receipt_ref})

      assert {:error, :outcome_kind_unsupported} =
               Reputation.issue(context.policy, context.signer, attributes)
    end

    assert {:ok, attestation} = issue!(context, decision, subject_id: "actor:builder")
    evidence = Reputation.subject_evidence("actor:builder", context.repository)

    assert evidence["score"] == nil
    assert evidence["scope"] == "repository"
    assert evidence["counts"] == %{"completion" => 1}
    refute Reputation.policy_rules()["global_score"]
    refute function_exported?(Reputation, :rank, 1)
    assert attestation.transparency_tier == "public"
  end

  test "one attestation covers one issue, revision, verifier, and actor", context do
    decision = outcome_decision_fixture()
    assert {:ok, attestation} = issue!(context, decision, subject_id: "actor:builder")

    for {field, wrong} <- [
          {:subject_id, "actor:impostor"},
          {:revision, "0000000000000000000000000000000000000000"},
          {:event_type, "payment"},
          {:policy_id, "other.verifier.v1"}
        ] do
      report = Reputation.verify(attestation, %{field => wrong})
      refute report["verified"]
      assert %{"field" => _, "expected" => ^wrong} = hd(report["binding"]["mismatches"])
    end

    # Re-signing the same event for the same outcome is a duplicate, and a
    # claim moved to another subject no longer matches its own digest.
    assert {:error, %Ecto.Changeset{}} = issue!(context, decision, subject_id: "actor:builder")

    tampered = %{
      attestation
      | claim: put_in(attestation.claim, ["subject", "actor_id"], "actor:x")
    }

    report = Reputation.verify(tampered)
    refute report["digest_match"]
    refute report["signature"]["valid"]
    refute report["verified"]
  end

  test "a reversed outcome yields a linked revocation", context do
    decision = outcome_decision_fixture()
    assert {:ok, attestation} = issue!(context, decision, subject_id: "actor:builder")

    assert {:ok, %{revocation: revocation, attestation: revoked}} =
             Reputation.revoke(attestation, context.policy, context.signer, %{
               event_type: "reversal",
               reason_code: "outcome_reversed"
             })

    assert revocation.event_type == "reversal"
    assert revocation.revokes_id == attestation.id
    assert revocation.supersedes_digest == attestation.claim_digest
    assert revoked.revocation_reason_code == "outcome_reversed"

    report = Reputation.verify(revoked)
    refute report["verified"]
    assert report["signature"]["valid"]
    assert report["revocation"]["revoked"]

    # The revocation itself verifies, and the revoked claim stays readable.
    assert Reputation.verify(revocation)["verified"]
    assert Repo.get!(Attestation, attestation.id).claim == attestation.claim
    assert {:error, :already_revoked} = revoke(context, revoked)

    evidence = Reputation.subject_evidence("actor:builder", context.repository)
    assert evidence["counts"] == %{"reversal" => 1}
    assert evidence["revoked"] == 1
  end

  test "a correction supersedes the claim it replaces", context do
    decision = outcome_decision_fixture()
    assert {:ok, attestation} = issue!(context, decision, subject_id: "actor:builder")

    corrected =
      context
      |> attributes(decision.decision_receipt_ref, decision.outcome_digest)
      |> Map.merge(%{subject_id: "actor:pair", confidence_ppm: 900_000})

    assert {:ok, %{revocation: revocation, correction: correction}} =
             Reputation.correct(attestation, context.policy, context.signer, corrected)

    assert revocation.revokes_id == attestation.id
    assert correction.supersedes_digest == attestation.claim_digest
    assert correction.subject_id == "actor:pair"
    assert Reputation.verify(correction)["verified"]
    refute Reputation.verify(Repo.get!(Attestation, attestation.id))["verified"]
  end

  test "an attestation names the policy version it was issued under", context do
    decision = outcome_decision_fixture()
    assert {:ok, attestation} = issue!(context, decision)

    report = Reputation.verify(attestation)
    assert report["policy"]["version"] == 1
    refute report["policy"]["superseded"]

    # A policy whose rules no longer hash to its digest cannot issue.
    forged = %{context.policy | rules: Map.put(context.policy.rules, "minimum_confidence_ppm", 0)}

    assert {:error, :policy_digest_mismatch} =
             Reputation.issue(
               forged,
               context.signer,
               attributes(context, decision.decision_receipt_ref, decision.outcome_digest)
             )

    # A later version supersedes without invalidating what it verified.
    assert {:ok, _receipt} =
             Repo.insert(
               PolicyReceipt.changeset(
                 %PolicyReceipt{},
                 %{
                   policy_id: Reputation.policy_id(),
                   version: 2,
                   policy_digest:
                     Reputation.policy_digest(
                       Reputation.policy_id(),
                       2,
                       Reputation.policy_rules()
                     ),
                   rules: Reputation.policy_rules(),
                   actor_id: "operator:test",
                   auth_method: "test_session",
                   approval_receipt_ref: "reputation-policy:v2"
                 }
               )
             )

    superseded = Reputation.verify(attestation)
    assert superseded["policy"]["superseded"]
    assert superseded["verified"]
  end

  test "confidence below the policy is not attestable", context do
    decision = outcome_decision_fixture()

    assert {:error, :confidence_below_policy} = issue!(context, decision, confidence_ppm: 10_000)

    assert {:error, :confidence_out_of_range} =
             issue!(context, decision, confidence_ppm: 2_000_000)

    assert {:error, :confidence_required} = issue!(context, decision, confidence_ppm: nil)
  end

  test "key rotation keeps signed history verifiable", context do
    decision = outcome_decision_fixture()
    assert {:ok, attestation} = issue!(context, decision)

    assert {:ok, retired} = Reputation.retire_key(context.key, DateTime.utc_now())

    report = Reputation.verify(attestation)
    assert report["signature"]["valid"]
    assert report["signature"]["key_status"] == "retired"
    assert report["signature"]["key_active_at_attestation"]
    assert report["verified"]

    assert {:error, :signing_key_retired} = issue!(context, outcome_decision_fixture())
    assert retired.retired_at

    rotated = Claim.generate_keypair()

    assert {:ok, key} =
             Reputation.admit_key(%{public_key: rotated.public_key, issuer: "verifier"})

    signer = %{key_id: key.key_id, private_key: rotated.private_key}

    assert {:ok, next} =
             Reputation.issue(
               context.policy,
               signer,
               attributes(context, outcome(), digest())
             )

    assert Reputation.verify(next)["verified"]

    # A private key that does not match the admitted public key cannot sign.
    assert {:error, :signing_key_mismatch} =
             Reputation.issue(
               context.policy,
               %{key_id: key.key_id, private_key: rotated.private_key |> flip()},
               attributes(context, outcome(), digest())
             )

    assert {:error, :signing_key_unknown} =
             Reputation.issue(
               context.policy,
               %{key_id: String.duplicate("a", 64), private_key: rotated.private_key},
               attributes(context, outcome(), digest())
             )
  end

  test "stale evidence is reported instead of quietly trusted", context do
    decision = outcome_decision_fixture()
    stale = DateTime.add(DateTime.utc_now(), -400 * 24 * 3600, :second)

    assert {:ok, attestation} =
             issue!(context, decision,
               evidence: [
                 %{
                   kind: "outcome",
                   ref: decision.decision_receipt_ref,
                   digest: decision.outcome_digest,
                   observed_at: DateTime.to_iso8601(stale)
                 }
               ]
             )

    report = Reputation.verify(attestation)
    assert report["evidence"]["stale"]
    refute report["verified"]
  end

  test "evidence must resolve and stay inside the repository", context do
    decision = outcome_decision_fixture()

    assert {:error, :evidence_required} = issue!(context, decision, evidence: [])

    assert {:error, :evidence_outside_repository_authority} =
             issue!(context, decision,
               evidence: [
                 %{
                   kind: "issue",
                   ref: "OtherOrg/other-repository#1",
                   digest: digest(),
                   observed_at: now()
                 }
               ]
             )

    assert {:error, :evidence_kind_unsupported} =
             issue!(context, decision,
               evidence: [
                 %{kind: "vibes", ref: "anything", digest: digest(), observed_at: now()}
               ]
             )

    assert {:ok, unresolvable} =
             issue!(context, decision,
               evidence: [
                 %{
                   kind: "outcome",
                   ref: "outcome-decision:not-recorded",
                   digest: decision.outcome_digest,
                   observed_at: now()
                 }
               ]
             )

    report = Reputation.verify(unresolvable)
    refute report["evidence"]["available"]
    refute report["verified"]
  end

  test "a private attestation verifies without disclosing the work", context do
    decision = outcome_decision_fixture()
    private = repository_fixture(%{visibility: "private"})
    issue = issue_fixture(private)

    assert {:error, :transparency_tier_exceeds_repository_authority} =
             Reputation.issue(
               context.policy,
               context.signer,
               %{
                 attributes(context, decision.decision_receipt_ref, decision.outcome_digest)
                 | repository: private,
                   issue_number: issue.number
               }
               |> Map.put(:evidence, [
                 %{
                   kind: "outcome",
                   ref: decision.decision_receipt_ref,
                   digest: decision.outcome_digest,
                   observed_at: now()
                 }
               ])
             )

    assert {:ok, attestation} =
             Reputation.issue(context.policy, context.signer, %{
               event_type: "completion",
               subject_id: "actor:builder",
               outcome: %{
                 kind: "compensation_outcome_decision",
                 ref: decision.decision_receipt_ref
               },
               repository: private,
               issue_number: issue.number,
               revision: String.duplicate("c", 40),
               artifact_digest: digest(),
               confidence_ppm: 900_000,
               transparency_tier: "private",
               evidence: [
                 %{
                   kind: "outcome",
                   ref: decision.decision_receipt_ref,
                   digest: decision.outcome_digest,
                   observed_at: now()
                 }
               ]
             })

    published = Jason.encode!(Reputation.projection(attestation))
    refute published =~ decision.decision_receipt_ref
    assert Reputation.verify(attestation)["verified"]
    assert Reputation.list_for_issue(private, issue.number, ~w(public)) == []

    assert [attestation.id] ==
             private
             |> Reputation.list_for_issue(issue.number, ~w(public private))
             |> Enum.map(& &1.id)
  end

  test "an attestation only binds to an issue of its own repository", context do
    decision = outcome_decision_fixture()

    assert {:error, :issue_not_found} = issue!(context, decision, issue_number: 9_999)

    assert {:error, :repository_required} =
             issue!(context, decision, repository: "TestOrg/test-repository")

    assert {:error, :invalidation_requires_prior_attestation} =
             issue!(context, decision, event_type: "revocation")

    assert {:error, :event_type_unsupported} =
             issue!(context, decision, event_type: "vibe_check")
  end

  test "issuance and verification report the distinct outcome events", context do
    assert Attestation.event_types() ==
             ~w(completion verification review payment reversal revocation)

    for event_type <- ~w(completion verification review payment) do
      decision = outcome_decision_fixture()

      assert {:ok, attestation} =
               issue!(context, decision, event_type: event_type, subject_id: "actor:multi")

      assert attestation.event_type == event_type
      assert Reputation.verify(attestation, %{event_type: event_type})["verified"]
    end

    evidence = Reputation.subject_evidence("actor:multi", context.repository)

    assert evidence["counts"] == %{
             "completion" => 1,
             "verification" => 1,
             "review" => 1,
             "payment" => 1
           }
  end

  test "only an authenticated operator admits a verifier policy" do
    assert {:error, :operator_unauthenticated} = Reputation.admit_policy(%{})

    assert {:error, :operator_receipt_incomplete} =
             Reputation.admit_policy(%{authenticated: true, actor_id: "operator:test"})
  end

  defp issue!(context, decision, overrides \\ []) do
    attributes =
      context
      |> attributes(decision.decision_receipt_ref, decision.outcome_digest)
      |> Map.merge(Map.new(overrides))

    Reputation.issue(context.policy, context.signer, attributes)
  end

  defp revoke(context, attestation) do
    Reputation.revoke(attestation, context.policy, context.signer, %{
      event_type: "revocation",
      reason_code: "duplicate"
    })
  end

  defp attributes(context, outcome_ref, outcome_digest) do
    %{
      event_type: "completion",
      subject_id: "actor:builder",
      outcome: %{kind: "compensation_outcome_decision", ref: outcome_ref},
      repository: context.repository,
      issue_number: context.issue.number,
      revision: String.duplicate("a", 40),
      artifact_digest: digest(),
      confidence_ppm: 900_000,
      transparency_tier: "public",
      evidence: [
        %{
          kind: "outcome",
          ref: outcome_ref,
          digest: outcome_digest,
          observed_at: now()
        },
        %{
          kind: "issue",
          ref: "#{context.repository.owner}/#{context.repository.name}##{context.issue.number}",
          digest: digest(),
          observed_at: now()
        }
      ]
    }
  end

  defp outcome, do: outcome_decision_fixture().decision_receipt_ref

  defp digest, do: Canonical.digest!(%{"nonce" => Claim.nonce()})

  defp now, do: DateTime.to_iso8601(DateTime.utc_now())

  defp flip(<<first, rest::binary>>), do: <<Bitwise.bxor(first, 1), rest::binary>>

  defp operator(suffix),
    do: %{
      authenticated: true,
      actor_id: "operator:test",
      auth_method: "test_session",
      approval_receipt_ref: "reputation-#{suffix}:#{System.unique_integer([:positive])}"
    }
end
