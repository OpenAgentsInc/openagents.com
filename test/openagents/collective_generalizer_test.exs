defmodule OpenAgents.CollectiveGeneralizerTest do
  use OpenAgents.SarahDataCase, async: true
  @moduletag :skip
  alias OpenAgents.Collective
  alias OpenAgents.Collective.Generalizer
  alias OpenAgents.Conversations

  @private_values [
    "alice.private@example.com",
    "sk-proj-UNIQUEPRIVATEVALUE12345678901234567890",
    "/Users/alice/work/acme-secret-plan.txt",
    "AcmeStealthCustomer-9472",
    "+1 (312) 555-0199"
  ]

  test "PII, secrets, paths, exact quotes, and business context never enter outputs or receipts" do
    source =
      private_source(
        "generalizer-adversarial",
        "I prefer concise answers for #{Enum.join(@private_values, " ")}"
      )

    assert {:ok, %{candidate: candidate}} = create_candidate(source, "evaluation_case")

    assert {:ok, %{candidate: generalized, receipt: receipt}} =
             Generalizer.generalize(source.owner, candidate.id, reviewer())

    assert generalized.status == "generalized"
    assert receipt.status == "generalized"
    assert receipt.policy_id == "sarah.collective.privacy_generalization.v1"
    assert receipt.generalizer_id == "sarah.collective.fixed_vocabulary.v1"
    assert receipt.output_digest =~ ~r/^[0-9a-f]{64}$/
    assert receipt.candidate_digest =~ ~r/^[0-9a-f]{64}$/
    assert receipt.reason_codes != []

    assert {:ok, projection} =
             Generalizer.review_projection(source.owner, candidate.id, reviewer())

    leak_surfaces =
      Jason.encode!(%{
        "payload" => generalized.generalized_payload,
        "receipt" => receipt_projection(receipt),
        "review" => projection
      })

    Enum.each(@private_values, fn private -> refute leak_surfaces =~ private end)
    refute leak_surfaces =~ source.message.content
    refute leak_surfaces =~ source.message.id
    refute inspect(receipt) =~ Enum.at(@private_values, 1)
  end

  test "admitted kinds have bounded fixed schemas and cannot add authority" do
    kinds = ~w(evaluation_case prompt_example module_pattern reusable_work_pattern)

    Enum.each(kinds, fn kind ->
      source =
        private_source("kind-#{kind}", "I actually prefer a corrected concise workflow result.")

      assert {:ok, %{candidate: candidate}} = create_candidate(source, kind)

      assert {:ok, %{candidate: generalized}} =
               Generalizer.generalize(source.owner, candidate.id, reviewer())

      payload = generalized.generalized_payload
      assert payload["schema"] == "sarah.collective.#{kind}.v1"
      assert byte_size(Jason.encode!(payload)) <= 8_192

      forbidden = ~w(authority authorities credential token executable)
      keys = nested_keys(payload)
      assert Enum.all?(forbidden, &(&1 not in keys))
    end)
  end

  test "low-utility or high-reidentification-only source is rejected with bounded codes" do
    source =
      private_source(
        "low-utility",
        "alice.private@example.com AcmeStealthCustomer-9472 /Users/alice/private.txt"
      )

    assert {:ok, %{candidate: candidate}} = create_candidate(source, "evaluation_case")

    assert {:ok, %{candidate: rejected, receipt: receipt}} =
             Generalizer.generalize(source.owner, candidate.id, reviewer())

    assert rejected.status == "rejected"
    assert rejected.generalized_payload == nil
    assert receipt.status == "rejected"
    assert receipt.risk == "high"
    assert receipt.utility == "insufficient"
    assert receipt.reason_codes == ["insufficient_generalizable_signal"]
    assert receipt.output_digest == nil
    refute inspect(receipt) =~ source.message.content
  end

  test "same policy, kind, and supported signal produce the same output digest" do
    first = private_source("reproducible-first", "I prefer short direct answers.")
    second = private_source("reproducible-second", "My preference is brief responses.")
    assert {:ok, %{candidate: first_candidate}} = create_candidate(first, "prompt_example")
    assert {:ok, %{candidate: second_candidate}} = create_candidate(second, "prompt_example")

    assert {:ok, %{receipt: first_receipt}} =
             Generalizer.generalize(first.owner, first_candidate.id, reviewer())

    assert {:ok, %{receipt: second_receipt}} =
             Generalizer.generalize(second.owner, second_candidate.id, reviewer())

    assert first_receipt.output_digest == second_receipt.output_digest
    assert first_receipt.policy_digest == second_receipt.policy_digest
    assert first_receipt.generalizer_digest == second_receipt.generalizer_digest
    refute first_receipt.candidate_digest == second_receipt.candidate_digest
  end

  test "lineage projection requires both owner scope and privacy reviewer authority" do
    source =
      private_source("lineage-owner", "Please remember this preference for concise replies.")

    foreign = private_source("lineage-foreign", "I prefer detailed replies.")
    assert {:ok, %{candidate: candidate}} = create_candidate(source, "evaluation_case")

    assert {:error, :privacy_reviewer_required} =
             Generalizer.generalize(source.owner, candidate.id, %{role: "model"})

    assert {:ok, _result} = Generalizer.generalize(source.owner, candidate.id, reviewer())

    assert {:error, :not_found} =
             Generalizer.review_projection(foreign.owner, candidate.id, reviewer())

    assert {:error, :privacy_reviewer_required} =
             Generalizer.review_projection(source.owner, candidate.id, %{
               authenticated: true,
               role: "catalog_reader",
               actor_id: "reader"
             })

    assert {:ok, projection} =
             Generalizer.review_projection(source.owner, candidate.id, reviewer())

    assert projection["lineage"] != []
    assert Enum.all?(projection["lineage"], &String.starts_with?(&1, "collective-source:v1:"))
  end

  defp create_candidate(source, kind) do
    Collective.create_candidate(source.owner, %{
      "actor_type" => "person",
      "explicit" => true,
      "confirmation_kind" => "collective_contribution",
      "confirmation_nonce" => "generalize:#{source.message.id}:#{kind}",
      "source_scope_ref" => "conversation:#{source.conversation.id}",
      "source_refs" => ["message:#{source.message.id}"],
      "category" => kind,
      "intended_use" => "Create a bounded de-identified #{kind} candidate.",
      "attribution_disclosure" => "Opaque contribution lineage may be retained.",
      "compensation_disclosure" => "No payment is created by this consent."
    })
  end

  defp private_source(browser_key, content) do
    assert {:ok, conversation} = Conversations.ensure_conversation(browser_key)
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

  defp reviewer,
    do: %{
      authenticated: true,
      role: "privacy_reviewer",
      actor_id: "privacy-reviewer:test",
      auth_method: "test_session"
    }

  defp receipt_projection(receipt) do
    Map.take(Map.from_struct(receipt), [
      :candidate_digest,
      :source_digest,
      :policy_id,
      :policy_version,
      :policy_digest,
      :generalizer_id,
      :generalizer_version,
      :generalizer_digest,
      :status,
      :reason_codes,
      :risk,
      :utility,
      :support_signal,
      :source_count,
      :output_digest
    ])
  end

  defp nested_keys(value) when is_map(value),
    do:
      Enum.flat_map(value, fn {key, nested} ->
        [String.downcase(to_string(key)) | nested_keys(nested)]
      end)

  defp nested_keys(value) when is_list(value), do: Enum.flat_map(value, &nested_keys/1)
  defp nested_keys(_value), do: []
end
