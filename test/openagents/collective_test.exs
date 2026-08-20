defmodule OpenAgents.CollectiveTest do
  use OpenAgents.DataCase, async: true
  alias OpenAgents.Collective
  alias OpenAgents.Collective.{Candidate, ConsentReceipt}
  alias OpenAgents.Conversations

  test "a candidate requires exact informed person contribution consent" do
    %{owner: owner, conversation: conversation, message: message} =
      private_source("consent-required")

    model_suggestion =
      confirmation(conversation, message)
      |> Map.put("actor_type", "model")

    assert {:error, :person_confirmation_required} =
             Collective.create_candidate(owner, model_suggestion)

    reused_memory_consent =
      confirmation(conversation, message)
      |> Map.put("confirmation_kind", "profile_memory")

    assert {:error, :contribution_confirmation_kind_invalid} =
             Collective.create_candidate(owner, reused_memory_consent)

    terms_only =
      confirmation(conversation, message)
      |> Map.put("explicit", false)

    assert {:error, :explicit_contribution_consent_required} =
             Collective.create_candidate(owner, terms_only)

    assert Repo.aggregate(ConsentReceipt, :count) == 0
    assert Repo.aggregate(Candidate, :count) == 0
  end

  test "consent is inspectable while the private candidate contains no raw quote" do
    %{owner: owner, conversation: conversation, message: message} = private_source("inspectable")
    confirmation = confirmation(conversation, message)

    assert {:ok, %{consent: consent, candidate: candidate}} =
             Collective.create_candidate(owner, confirmation)

    assert consent.status == "active"
    assert consent.source_refs == ["message:#{message.id}"]
    assert consent.category == confirmation["category"]
    assert consent.intended_use == confirmation["intended_use"]
    assert consent.attribution_disclosure == confirmation["attribution_disclosure"]
    assert consent.compensation_disclosure == confirmation["compensation_disclosure"]
    assert consent.policy_id == "sarah.collective.contribution_consent.v1"

    assert candidate.status == "consented"
    assert candidate.generalized_payload == nil
    assert candidate.evaluator_ref == nil
    assert candidate.review_refs == []
    assert candidate.publication_refs == []
    assert Enum.all?(candidate.provenance_refs, &String.starts_with?(&1, "collective-source:v1:"))

    private_quote = message.content

    refute Jason.encode!(
             Map.take(Map.from_struct(candidate), [
               :source_scope_digest,
               :provenance_refs,
               :generalized_kind,
               :generalized_payload,
               :review_refs,
               :publication_refs
             ])
           ) =~ private_quote

    refute Enum.any?(candidate.provenance_refs, &String.contains?(&1, message.id))

    assert {:ok, inspected} = Collective.get_private_candidate(owner, candidate.id)
    assert inspected.consent.source_refs == consent.source_refs
    assert inspected.candidate.id == candidate.id
  end

  test "candidate queries and source admission are owner-scoped" do
    first = private_source("owner-first")
    second = private_source("owner-second")

    assert {:ok, %{candidate: candidate}} =
             Collective.create_candidate(
               first.owner,
               confirmation(first.conversation, first.message)
             )

    assert [owned] = Collective.list_private_candidates(first.owner)
    assert owned.id == candidate.id
    assert Collective.list_private_candidates(second.owner) == []
    assert {:error, :not_found} = Collective.get_private_candidate(second.owner, candidate.id)

    foreign_source =
      confirmation(first.conversation, second.message)
      |> Map.put("source_refs", ["message:#{second.message.id}"])

    assert {:error, :source_not_found} =
             Collective.create_candidate(first.owner, foreign_source)
  end

  test "withdrawal is owner-only, atomic, inspectable, and idempotent" do
    first = private_source("withdraw-owner")
    second = private_source("withdraw-foreign")

    assert {:ok, %{candidate: candidate}} =
             Collective.create_candidate(
               first.owner,
               confirmation(first.conversation, first.message)
             )

    withdrawal = %{
      "actor_type" => "person",
      "explicit" => true,
      "reason" => "I no longer want this private source contributed."
    }

    assert {:error, :candidate_not_found} =
             Collective.withdraw(second.owner, candidate.id, withdrawal)

    assert {:ok, %{consent: consent, candidate: withdrawn}} =
             Collective.withdraw(first.owner, candidate.id, withdrawal)

    assert consent.status == "withdrawn"
    assert consent.withdrawn_at
    assert consent.withdrawal_reason == withdrawal["reason"]
    assert withdrawn.status == "withdrawn"

    assert {:ok, %{consent: same_consent, candidate: same_candidate}} =
             Collective.withdraw(first.owner, candidate.id, withdrawal)

    assert same_consent.id == consent.id
    assert same_candidate.id == withdrawn.id
    assert same_consent.withdrawn_at == consent.withdrawn_at
  end

  test "post-publication withdrawal becomes explicit revocation propagation" do
    source = private_source("revocation-propagation")

    assert {:ok, %{candidate: candidate}} =
             Collective.create_candidate(
               source.owner,
               confirmation(source.conversation, source.message)
             )

    {1, _rows} =
      Repo.update_all(
        from(stored in Candidate, where: stored.id == ^candidate.id),
        set: [publication_refs: ["published-module:openagents.example:1"]]
      )

    assert {:ok, %{candidate: withdrawn}} =
             Collective.withdraw(source.owner, candidate.id, %{
               "actor_type" => "person",
               "explicit" => true,
               "reason" => "Withdraw and propagate revocation."
             })

    assert withdrawn.status == "revocation_pending"
    assert withdrawn.publication_refs == ["published-module:openagents.example:1"]
  end

  defp private_source(browser_key) do
    assert {:ok, conversation} = Conversations.ensure_conversation(browser_key)
    owner = Repo.get!(OpenAgents.Conversations.Visitor, conversation.visitor_id)

    message =
      Repo.insert!(%OpenAgents.Conversations.Message{
        conversation_id: conversation.id,
        role: "user",
        content:
          "Private identifying quote for #{browser_key} that must never enter shared fields.",
        status: "complete"
      })

    %{owner: owner, conversation: conversation, message: message}
  end

  defp confirmation(conversation, message) do
    %{
      "actor_type" => "person",
      "explicit" => true,
      "confirmation_kind" => "collective_contribution",
      "confirmation_nonce" => "confirm:#{conversation.id}:#{message.id}",
      "source_scope_ref" => "conversation:#{conversation.id}",
      "source_refs" => ["message:#{message.id}"],
      "category" => "evaluation_case",
      "intended_use" => "Create a de-identified evaluation candidate for independent review.",
      "attribution_disclosure" => "Usage may retain opaque contribution attribution.",
      "compensation_disclosure" =>
        "Consent creates no payment; any compensation needs a later policy."
    }
  end
end
