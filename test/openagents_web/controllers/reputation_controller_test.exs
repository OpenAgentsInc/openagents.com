defmodule OpenAgentsWeb.ReputationControllerTest do
  use OpenAgentsWeb.ConnCase

  import OpenAgents.CompensationFixtures
  import OpenAgents.IssuesFixtures

  alias OpenAgents.Reputation
  alias OpenAgents.Reputation.Claim

  setup do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    {:ok, policy} = Reputation.admit_policy(operator())
    keypair = Claim.generate_keypair()
    {:ok, key} = Reputation.admit_key(%{public_key: keypair.public_key, issuer: "verifier"})
    signer = %{key_id: key.key_id, private_key: keypair.private_key}

    %{repository: repository, issue: issue, policy: policy, key: key, signer: signer}
  end

  test "a stranger verifies the published claim without trusting the API", context do
    {:ok, attestation} = attest(context)

    published =
      build_conn()
      |> get(issue_path(context))
      |> json_response(200)
      |> Map.fetch!("attestations")
      |> hd()

    keys = build_conn() |> get("/api/v3/reputation/keys") |> json_response(200)
    key = Enum.find(keys["keys"], &(&1["key_id"] == published["issuer_key_id"]))

    assert published["claim_digest"] == attestation.claim_digest
    assert Claim.valid_signature?(published["claim"], published["signature"], key["public_key"])
    assert published["revocation"]["revoked"] == false

    policy = build_conn() |> get("/api/v3/reputation/policy") |> json_response(200)
    version = hd(policy["versions"])

    assert policy["score"] == nil
    assert version["policy_digest"] == published["claim"]["verifier"]["policy_digest"]

    assert version["policy_digest"] ==
             Reputation.policy_digest(version["policy_id"], version["version"], version["rules"])
  end

  test "the verification endpoint reports a binding the caller did not expect", context do
    {:ok, attestation} = attest(context)
    path = attestation_path(context, attestation) <> "/verification"

    assert %{"verified" => true} = build_conn() |> get(path) |> json_response(200)

    report =
      build_conn()
      |> get(path, %{"subject_id" => "actor:impostor"})
      |> json_response(200)

    refute report["verified"]

    assert [%{"field" => "subject_id", "claimed" => "actor:builder"}] =
             report["binding"]["mismatches"]
  end

  test "a revoked attestation stays readable and fails verification", context do
    {:ok, attestation} = attest(context)

    {:ok, _result} =
      Reputation.revoke(attestation, context.policy, context.signer, %{
        event_type: "reversal",
        reason_code: "outcome_reversed"
      })

    body = build_conn() |> get(attestation_path(context, attestation)) |> json_response(200)

    assert body["revocation"]["revoked"]
    assert body["revocation"]["reason_code"] == "outcome_reversed"

    refute build_conn()
           |> get(attestation_path(context, attestation) <> "/verification")
           |> json_response(200)
           |> Map.fetch!("verified")
  end

  test "scoped evidence never publishes a score", context do
    {:ok, _attestation} = attest(context)
    path = "/api/v3/repos/#{path(context)}/reputation/subjects/actor:builder"

    body = build_conn() |> get(path) |> json_response(200)

    assert body["score"] == nil
    assert body["scope"] == "repository"
    assert body["counts"] == %{"completion" => 1}
  end

  test "a private attestation is disclosed to the repository, not the public", context do
    repository = repository_fixture(%{visibility: "private"})
    issue = issue_fixture(repository)
    decision = outcome_decision_fixture()

    {:ok, attestation} =
      Reputation.issue(context.policy, context.signer, %{
        event_type: "completion",
        subject_id: "actor:builder",
        outcome: %{kind: "compensation_outcome_decision", ref: decision.decision_receipt_ref},
        repository: repository,
        issue_number: issue.number,
        revision: String.duplicate("b", 40),
        artifact_digest: String.duplicate("2", 64),
        confidence_ppm: 900_000,
        transparency_tier: "private",
        evidence: [
          %{
            kind: "outcome",
            ref: decision.decision_receipt_ref,
            digest: decision.outcome_digest,
            observed_at: DateTime.to_iso8601(DateTime.utc_now())
          }
        ]
      })

    path = "/api/v3/repos/#{repository.owner}/#{repository.name}/attestations/#{attestation.id}"

    assert build_conn() |> get(path) |> json_response(404)

    member = put_forge_api_token(build_conn(), "private-attestation", repository)
    body = member |> get(path) |> json_response(200)

    assert body["claim"]["outcome"]["ref"] == nil
    refute Jason.encode!(body) =~ decision.decision_receipt_ref
  end

  test "an unknown attestation is not found", context do
    assert build_conn()
           |> get("/api/v3/repos/#{path(context)}/attestations/#{Ecto.UUID.generate()}")
           |> json_response(404)

    assert build_conn()
           |> get("/api/v3/repos/#{path(context)}/attestations/not-a-uuid")
           |> json_response(404)
  end

  defp attest(context) do
    decision = outcome_decision_fixture()

    Reputation.issue(context.policy, context.signer, %{
      event_type: "completion",
      subject_id: "actor:builder",
      outcome: %{kind: "compensation_outcome_decision", ref: decision.decision_receipt_ref},
      repository: context.repository,
      issue_number: context.issue.number,
      revision: String.duplicate("a", 40),
      artifact_digest: String.duplicate("1", 64),
      confidence_ppm: 900_000,
      transparency_tier: "public",
      evidence: [
        %{
          kind: "outcome",
          ref: decision.decision_receipt_ref,
          digest: decision.outcome_digest,
          observed_at: DateTime.to_iso8601(DateTime.utc_now())
        }
      ]
    })
  end

  defp issue_path(context),
    do: "/api/v3/repos/#{path(context)}/issues/#{context.issue.number}/attestations"

  defp attestation_path(context, attestation),
    do: "/api/v3/repos/#{path(context)}/attestations/#{attestation.id}"

  defp path(context), do: "#{context.repository.owner}/#{context.repository.name}"

  defp operator,
    do: %{
      authenticated: true,
      actor_id: "operator:test",
      auth_method: "test_session",
      approval_receipt_ref: "reputation-api:#{System.unique_integer([:positive])}"
    }
end
