defmodule OpenAgents.CollectivePublicationTest do
  use OpenAgents.SarahDataCase, async: false
  @moduletag :skip
  alias OpenAgents.Collective

  alias OpenAgents.Collective.{
    Generalizer,
    OperatorDecisionReceipt,
    PublicationReceipt,
    Publisher,
    Reviewer,
    ReviewReceipt
  }

  alias OpenAgents.Conversations
  alias OpenAgents.Modules.Artifact

  test "independent evaluation and operator approval publish one staged immutable artifact" do
    source = source("publish", "I prefer concise responses with evidence.")
    candidate = generalized_candidate(source)

    assert {:error, :independent_reviewer_required} =
             Reviewer.review(
               source.owner,
               candidate.id,
               %{evaluator() | actor_id: privacy_reviewer().actor_id},
               passing_evaluation()
             )

    assert {:ok, %{candidate: reviewed, receipt: review}} =
             Reviewer.review(source.owner, candidate.id, evaluator(), passing_evaluation())

    assert reviewed.status == "reviewed"
    assert review.decision == "passed"
    assert review.policy_id == "sarah.collective.independent_review.v1"
    assert review.evaluation_digest =~ ~r/^[0-9a-f]{64}$/

    assert {:error, :independent_operator_required} =
             Publisher.publish(
               source.owner,
               candidate.id,
               operator(review.reviewer_actor_id, "not-independent"),
               %{"reason" => "Attempt self approval."}
             )

    assert {:ok, %{candidate: published, receipt: publication}} =
             Publisher.publish(
               source.owner,
               candidate.id,
               operator("operator:test", "publish"),
               %{
                 "reason" => "All pinned independent gates passed."
               }
             )

    assert published.status == "published"

    assert Repo.get_by!(OperatorDecisionReceipt, candidate_id: candidate.id).decision ==
             "approved"

    assert publication.state == "staged"
    assert publication.artifact_digest =~ ~r/^[0-9a-f]{64}$/
    assert publication.attribution_lineage == candidate.provenance_refs
    assert {:ok, artifact} = Artifact.from_map(publication.artifact)
    assert :ok = Artifact.validate(artifact)
    assert artifact.state == "disabled"
    assert artifact.executor.configuration == candidate.generalized_payload

    assert [projection] = Publisher.catalog()
    assert projection["artifact_digest"] == publication.artifact_digest
    encoded = Jason.encode!(projection)
    refute encoded =~ source.message.content
    refute encoded =~ source.message.id
  end

  test "a blocking evaluation persists bounded rejection and cannot publish" do
    source = source("review-reject", "I prefer concise responses.")
    candidate = generalized_candidate(source)
    evaluation = put_in(passing_evaluation(), ["dimensions", "privacy"], "blocked")

    assert {:ok, %{candidate: rejected, receipt: receipt}} =
             Reviewer.review(source.owner, candidate.id, evaluator(), evaluation)

    assert rejected.status == "review_rejected"
    assert receipt.decision == "rejected"
    assert receipt.reason_codes == ["privacy_blocked"]

    assert {:error, :candidate_not_approved_for_publication} =
             Publisher.publish(
               source.owner,
               candidate.id,
               operator("operator:test", "blocked"),
               %{
                 "reason" => "Must remain blocked."
               }
             )

    assert Repo.aggregate(PublicationReceipt, :count) == 0
  end

  test "an authenticated independent operator can reject without publishing" do
    source = source("operator-reject", "I prefer concise responses.")
    candidate = reviewed_candidate(source)

    assert {:ok, %{candidate: rejected, receipt: decision}} =
             Publisher.reject(source.owner, candidate.id, operator("operator:test", "reject"), %{
               "reason" => "Novelty is insufficient for this catalog."
             })

    assert rejected.status == "operator_rejected"
    assert decision.decision == "rejected"
    assert Publisher.catalog() == []
    assert Repo.aggregate(PublicationReceipt, :count) == 0

    assert {:error, :candidate_not_approved_for_publication} =
             Publisher.publish(
               source.owner,
               candidate.id,
               operator("operator:test", "after-reject"),
               %{"reason" => "Rejected candidates require a new immutable candidate."}
             )
  end

  test "withdrawal requires revocation, excludes discovery, and exposes rebuild work" do
    source = source("withdraw-revoke", "I prefer concise responses.")
    candidate = reviewed_candidate(source)

    assert {:ok, %{receipt: publication}} =
             Publisher.publish(
               source.owner,
               candidate.id,
               operator("operator:test", "publish"),
               %{
                 "reason" => "Publish for revocation test."
               }
             )

    assert Publisher.catalog() != []

    assert {:ok, %{candidate: pending}} =
             Collective.withdraw(source.owner, candidate.id, %{
               "actor_type" => "person",
               "explicit" => true,
               "reason" => "Withdraw this collective contribution."
             })

    assert pending.status == "revocation_pending"

    assert {:error, :privacy_revocation_cannot_rollback} =
             Publisher.rollback(candidate.id, operator("operator:test", "bad-rollback"), %{
               "reason" => "Privacy withdrawal cannot be rolled back."
             })

    assert {:ok, %{candidate: revoked, receipt: revocation}} =
             Publisher.revoke(candidate.id, operator("operator:test", "revoke"), %{
               "reason" => "Propagate consent withdrawal and rebuild derivatives."
             })

    assert revoked.status == "revoked"
    assert revocation.generation == publication.generation + 1
    assert Publisher.catalog() == []
    assert {:ok, plan} = Publisher.rebuild_plan(candidate.id)
    assert plan["status"] == "required"
    assert "delete_rebuildable_search_derivatives" in plan["on_revocation"]
  end

  test "regression rollback removes a staged artifact without rewriting publication" do
    source = source("rollback", "I prefer concise responses.")
    candidate = reviewed_candidate(source)

    assert {:ok, %{receipt: publication}} =
             Publisher.publish(
               source.owner,
               candidate.id,
               operator("operator:test", "publish"),
               %{
                 "reason" => "Stage reviewed artifact."
               }
             )

    assert {:ok, %{receipt: rollback}} =
             Publisher.rollback(candidate.id, operator("operator:test", "rollback"), %{
               "reason" => "A regression was found during staged observation."
             })

    assert rollback.action == "rollback"
    assert rollback.predecessor["artifact_digest"] == publication.artifact_digest
    assert rollback.artifact_digest != publication.artifact_digest
    assert Publisher.catalog() == []
    assert Repo.aggregate(PublicationReceipt, :count) == 2
  end

  test "review receipts reject mutation" do
    source = source("append-only", "I prefer concise responses.")
    candidate = reviewed_candidate(source)
    review = Repo.get_by!(ReviewReceipt, candidate_id: candidate.id)

    assert_raise Postgrex.Error, fn ->
      review |> Ecto.Changeset.change(decision: "rejected") |> Repo.update!()
    end
  end

  test "publication receipts reject mutation" do
    source = source("publication-append-only", "I prefer concise responses.")
    candidate = reviewed_candidate(source)

    assert {:ok, %{receipt: publication}} =
             Publisher.publish(
               source.owner,
               candidate.id,
               operator("operator:test", "immutable"),
               %{
                 "reason" => "Create an immutable publication receipt."
               }
             )

    assert_raise Postgrex.Error, fn ->
      publication |> Ecto.Changeset.change(reason: "rewritten") |> Repo.update!()
    end
  end

  defp reviewed_candidate(source) do
    candidate = generalized_candidate(source)

    assert {:ok, %{candidate: reviewed}} =
             Reviewer.review(source.owner, candidate.id, evaluator(), passing_evaluation())

    reviewed
  end

  defp generalized_candidate(source) do
    assert {:ok, %{candidate: candidate}} =
             Collective.create_candidate(source.owner, %{
               "actor_type" => "person",
               "explicit" => true,
               "confirmation_kind" => "collective_contribution",
               "confirmation_nonce" => "publication:#{source.message.id}",
               "source_scope_ref" => "conversation:#{source.conversation.id}",
               "source_refs" => ["message:#{source.message.id}"],
               "category" => "module_pattern",
               "intended_use" => "Create a reviewed de-identified module pattern.",
               "attribution_disclosure" => "Opaque contribution lineage may be retained.",
               "compensation_disclosure" => "No payment is created by this consent."
             })

    assert {:ok, %{candidate: generalized}} =
             Generalizer.generalize(source.owner, candidate.id, privacy_reviewer())

    generalized
  end

  defp source(key, content) do
    assert {:ok, conversation} = Conversations.ensure_conversation("publication-#{key}")
    owner = Repo.get!(OpenAgents.Conversations.Visitor, conversation.visitor_id)

    message =
      Repo.insert!(%OpenAgents.Conversations.Message{
        conversation_id: conversation.id,
        role: "user",
        content: content,
        status: "complete"
      })

    %{owner: owner, conversation: conversation, message: message}
  end

  defp privacy_reviewer,
    do: %{
      authenticated: true,
      role: "privacy_reviewer",
      actor_id: "privacy-reviewer:test",
      auth_method: "test_session"
    }

  defp evaluator,
    do: %{
      authenticated: true,
      role: "collective_evaluator",
      actor_id: "collective-evaluator:test",
      auth_method: "test_session"
    }

  defp operator(actor_id, suffix),
    do: %{
      authenticated: true,
      role: "operator",
      actor_id: actor_id,
      auth_method: "test_session",
      approval_receipt_ref: "collective-approval:#{suffix}:#{System.unique_integer([:positive])}"
    }

  defp passing_evaluation do
    %{
      "evaluator_artifact_ref" => "module:openagents.eval.collective:1",
      "evaluator_artifact_digest" => String.duplicate("a", 64),
      "dataset_ref" => "dataset:openagents.collective.release:1",
      "dataset_digest" => String.duplicate("b", 64),
      "dimensions" => %{
        "privacy" => "passed",
        "safety" => "passed",
        "regression" => "passed",
        "compatibility" => "passed",
        "authority" => "no_expansion",
        "novelty" => 0.8,
        "utility" => 0.9
      }
    }
  end
end
