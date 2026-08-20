defmodule OpenAgents.ExperienceMemoryTest do
  use OpenAgents.SarahDataCase, async: false
  alias OpenAgents.{Context.Composer, Conversations, ExperienceMemory}
  alias OpenAgents.ExperienceMemory.{Bank, BankItem, DeletionReceipt, EvidenceRef, Pattern}
  alias OpenAgents.Providers.Request

  setup do
    original = Application.fetch_env!(:openagents, :experience_memory)
    Application.put_env(:openagents, :experience_memory, Keyword.put(original, :enabled, true))
    on_exit(fn -> Application.put_env(:openagents, :experience_memory, original) end)
    :ok
  end

  test "requested and running cases are never recalled, and success requires a real target receipt" do
    fixture = conversation_fixture("experience-lifecycle")
    record = create_case!(fixture, "Deploy the service", "Run the bounded deployment module")

    assert {:ok, requested_bank} = capture(fixture, "deploy service")

    assert requested_bank.projections == []
    assert {:ok, running} = ExperienceMemory.start_case(fixture.owner, record.id, 1)

    assert {:ok, running_bank} = capture(fixture, "deploy service")

    assert running_bank.projections == []

    assert {:error, :target_receipt_required} =
             ExperienceMemory.complete_case(fixture.owner, running.id, 2, %{
               "outcome_state" => "succeeded",
               "outcome" => "The service answered its health check.",
               "target_receipt_refs" => []
             })

    target_ref = successful_target!(fixture, "experience-lifecycle-target")

    assert {:ok, succeeded} =
             ExperienceMemory.complete_case(fixture.owner, running.id, 2, %{
               "outcome_state" => "succeeded",
               "outcome" => "The service answered its health check.",
               "target_receipt_refs" => [target_ref]
             })

    assert succeeded.outcome_state == "succeeded"
    assert {:ok, bank} = capture(fixture, "deploy")
    assert [projection] = bank.projections
    assert projection["state"] == "succeeded"
    assert projection["target_receipt_refs"] == [target_ref]
    assert projection["applicability"] == "Only similar work in this conversation"
    assert projection["interpretation"] =~ "not universal"
  end

  test "failed cases remain explicit, private, and scope isolated" do
    fixture = conversation_fixture("experience-private")
    failed = failed_case!(fixture, "Rotate a key", "Attempt provider rotation")
    other = conversation_fixture("experience-other-owner")

    assert failed.outcome_state == "failed"
    assert {:error, :not_found} = ExperienceMemory.get(other.owner, failed.id)
    assert {:error, :scope_refused} = ExperienceMemory.export_scope(other.owner, fixture.scope)

    assert {:ok, bank} = capture(fixture, "rotate key")

    assert [projection] = bank.projections
    assert projection["state"] == "failed"
    assert projection["interpretation"] == "one scoped failure; advisory caution"
  end

  test "pattern evidence requires multiple terminal cases and selection is deterministic and bounded" do
    fixture = conversation_fixture("experience-pattern")
    first = failed_case!(fixture, "Check a release", "Inspect the release receipt")

    assert {:error, :insufficient_pattern_support} =
             ExperienceMemory.create_pattern(fixture.owner, fixture.scope, %{
               "phenomenon" => "Release receipts expose incomplete promotions",
               "applicability" => "Digest-addressed releases",
               "expected_effect" => "Inspecting receipts finds incomplete promotion",
               "confidence_millis" => 700,
               "support_record_ids" => [first.id]
             })

    second = failed_case!(fixture, "Audit another release", "Inspect its release receipt")

    assert {:ok, pattern} =
             ExperienceMemory.create_pattern(fixture.owner, fixture.scope, %{
               "phenomenon" => "Release receipts expose incomplete promotions",
               "applicability" => "Digest-addressed releases",
               "expected_effect" => "Inspecting receipts finds incomplete promotion",
               "confidence_millis" => 700,
               "support_record_ids" => [first.id, second.id]
             })

    assert pattern.status == "active"
    turn = fresh_turn!(fixture, "release receipt")

    assert {:ok, first_bank} =
             ExperienceMemory.capture_for_turn(fixture.owner, turn, "release receipt")

    assert {:ok, second_bank} =
             ExperienceMemory.capture_for_turn(fixture.owner, turn, "changed retry query")

    assert first_bank.ref == second_bank.ref
    assert first_bank.projections == second_bank.projections
    assert first_bank.usage == second_bank.usage
    assert first_bank.usage["pattern_refs"] == ["experience-pattern:#{pattern.id}"]

    bank_id = bank_id!(first_bank.ref)
    persisted = Repo.get!(Bank, bank_id)
    assert persisted.used_bytes <= 4_000
    assert Repo.aggregate(from(i in BankItem, where: i.bank_id == ^bank_id), :count) <= 9
  end

  test "delete removes source-linked derivatives and leaves an immutable bounded receipt" do
    fixture = conversation_fixture("experience-delete")
    first = failed_case!(fixture, "Investigate latency", "Inspect the trace")
    second = failed_case!(fixture, "Investigate another latency event", "Inspect the trace")

    assert {:ok, _pattern} =
             ExperienceMemory.create_pattern(fixture.owner, fixture.scope, %{
               "phenomenon" => "Trace inspection identifies latency failures",
               "applicability" => "Latency investigations",
               "expected_effect" => "Relevant failure evidence is recovered",
               "confidence_millis" => 650,
               "support_record_ids" => [first.id, second.id]
             })

    assert {:ok, captured} = capture(fixture, "latency trace")
    bank_id = bank_id!(captured.ref)

    assert {:ok, receipt} = ExperienceMemory.delete(fixture.owner, first.id, "owner_requested")
    assert receipt.source_ref_count > 0
    assert receipt.pattern_count == 1
    assert receipt.bank_item_count > 0
    assert Repo.get!(Bank, bank_id).status == "invalidated"
    refute Repo.exists?(from(r in EvidenceRef, where: r.record_id == ^first.id))
    refute Repo.exists?(from(p in Pattern, where: p.owner_visitor_id == ^fixture.owner.id))

    assert {:ok, exported} = ExperienceMemory.export_scope(fixture.owner, fixture.scope)
    refute Enum.any?(exported["records"], &(&1["record_ref"] == "experience:#{first.id}"))

    assert_raise Postgrex.Error, fn ->
      receipt |> Ecto.Changeset.change(reason_code: "rewritten") |> Repo.update!()
    end

    assert Repo.aggregate(DeletionReceipt, :count) == 1
  end

  test "correction is atomic and collective candidacy remains a separate explicit-consent path" do
    fixture = conversation_fixture("experience-correction")
    failed = failed_case!(fixture, "Prepare a rollout", "Use the incomplete rollout plan")

    replacement = %{
      "objective" => "Prepare a corrected rollout",
      "approach" => "Use a staged rollout with a health gate",
      "applicability" => "Only staged rollouts in this conversation",
      "confidence_millis" => 700,
      "source_refs" => ["message:#{fixture.source_message.id}"],
      "trace_refs" => []
    }

    assert {:error, :explicit_contribution_consent_required} =
             ExperienceMemory.propose_collective_candidate(fixture.owner, failed.id, %{
               "actor_type" => "person",
               "explicit" => false
             })

    assert {:ok, %{candidate: candidate}} =
             ExperienceMemory.propose_collective_candidate(fixture.owner, failed.id, %{
               "actor_type" => "person",
               "explicit" => true,
               "confirmation_kind" => "collective_contribution",
               "confirmation_nonce" => "experience-correction-consent",
               "category" => "module_pattern",
               "intended_use" => "Evaluate a possible collective rollout pattern.",
               "attribution_disclosure" => "Attribution remains attached to the contribution.",
               "compensation_disclosure" => "Consent does not promise compensation."
             })

    assert candidate.status == "consented"
    assert candidate.publication_refs == []
    assert candidate.generalized_payload == nil

    assert {:ok, result} =
             ExperienceMemory.correct_case(
               fixture.owner,
               failed.id,
               failed.generation,
               "The original approach omitted the health gate.",
               replacement
             )

    assert result.corrected.outcome_state == "corrected"
    assert result.replacement.supersedes_record_id == failed.id
    assert result.replacement.outcome_state == "requested"

    assert Repo.exists?(
             from(r in EvidenceRef,
               where:
                 r.record_id == ^failed.id and r.kind == "correction" and
                   r.reference == ^"experience:#{result.replacement.id}"
             )
           )
  end

  test "experience memory is a measured feature flag and defaults to no capture" do
    fixture = conversation_fixture("experience-disabled")
    original = Application.fetch_env!(:openagents, :experience_memory)
    Application.put_env(:openagents, :experience_memory, Keyword.put(original, :enabled, false))

    assert {:ok, disabled} = capture(fixture, "anything")

    assert disabled == %{
             ref: nil,
             projections: [],
             usage: %{
               "schema" => "sarah.experience_usage.v1",
               "record_refs" => [],
               "pattern_refs" => [],
               "bank_digest" => nil
             }
           }

    fixture_path =
      Path.join(:code.priv_dir(:openagents), "sarah/evals/experiences/benefit-comparison.v1.json")

    evaluation = fixture_path |> File.read!() |> Jason.decode!()
    assert evaluation["activation_gate"]["default_enabled"] == false
    assert evaluation["activation_gate"]["requires_measured_benefit"] == true
  end

  defp conversation_fixture(browser_key) do
    assert {:ok, conversation} = Conversations.ensure_conversation(browser_key)
    owner = Repo.get!(OpenAgents.Conversations.Visitor, conversation.visitor_id)

    assert {:ok, records} =
             Conversations.create_turn(conversation, "Source evidence for this work.")

    %{
      owner: owner,
      conversation: conversation,
      source_message: records.user_message,
      scope: "conversation:#{conversation.id}"
    }
  end

  defp create_case!(fixture, objective, approach) do
    assert {:ok, record} =
             ExperienceMemory.create_case(fixture.owner, fixture.scope, %{
               "objective" => objective,
               "approach" => approach,
               "applicability" => "Only similar work in this conversation",
               "confidence_millis" => 600,
               "source_refs" => ["message:#{fixture.source_message.id}"],
               "trace_refs" => []
             })

    record
  end

  defp failed_case!(fixture, objective, approach) do
    record = create_case!(fixture, objective, approach)

    assert {:ok, running} =
             ExperienceMemory.start_case(fixture.owner, record.id, record.generation)

    assert {:ok, failed} =
             ExperienceMemory.complete_case(fixture.owner, running.id, running.generation, %{
               "outcome_state" => "failed",
               "outcome" => "The scoped objective was not achieved.",
               "target_receipt_refs" => []
             })

    failed
  end

  defp capture(fixture, query) do
    turn = fresh_turn!(fixture, query)
    ExperienceMemory.capture_for_turn(fixture.owner, turn, query)
  end

  defp successful_target!(fixture, suffix) do
    turn = fresh_turn!(fixture, "Produce a target receipt.")
    context = Composer.compose!()

    request = %Request{
      model_id: "experience-test-model",
      instructions: context.instructions,
      input: Conversations.provider_messages(fixture.conversation.id)
    }

    assert {:ok, inference} =
             Conversations.begin_inference(
               turn,
               context,
               request,
               "test.provider",
               tool_catalog_digest: OpenAgents.Tools.Registry.current!().digest
             )

    artifact =
      Map.fetch!(OpenAgents.Tools.Registry.current!().modules, {"sarah.tool.recall_messages", 1})

    call_id = "call-#{suffix}"
    route = route!(inference.receipt, call_id, artifact)
    policy = artifact.attribution_policy

    assert {:ok, step, :created} =
             Conversations.request_tool_step(inference.turn, inference.receipt, %{
               provider_call_id: call_id,
               provider_item_id: "item-#{suffix}",
               provider_response_id: "response-#{suffix}",
               tool_name: "recall_messages",
               tool_version: artifact.version,
               module_id: artifact.module_id,
               module_artifact_digest: artifact.artifact_digest,
               executor_implementation_digest: artifact.implementation_digest,
               routing_receipt_id: route.id,
               side_effect_class: artifact.side_effect_class,
               attribution_policy_id: policy["id"],
               attribution_policy_version: policy["version"],
               attribution_policy_digest: policy["digest"],
               cost_units: artifact.facets["cost_units"],
               raw_arguments: "{}"
             })

    target_ref = "target:verified:#{suffix}"

    outcome = %{
      "schema" => "sarah.tool_outcome.v1",
      "call_id" => step.provider_call_id,
      "module_ref" => %{
        "module_id" => step.module_id,
        "tool_name" => step.tool_name,
        "version" => step.tool_version,
        "artifact_digest" => step.module_artifact_digest
      },
      "executor_ref" => %{
        "id" => "sarah.local",
        "disclosure" => "Sarah local recall",
        "implementation_digest" => step.executor_implementation_digest
      },
      "status" => "succeeded",
      "result" => %{"verified" => true},
      "error" => nil,
      "target_receipt_refs" => [target_ref],
      "attribution_refs" => ["OpenAgentsInc/sarah"],
      "started_at" => "2026-08-16T20:00:00Z",
      "completed_at" => "2026-08-16T20:00:01Z"
    }

    assert {:ok, _completed} = Conversations.complete_tool_step(step, outcome)
    target_ref
  end

  defp route!(receipt, call_id, artifact) do
    snapshot = OpenAgents.Tools.Registry.current!()

    proposal = %{
      "module_id" => artifact.module_id,
      "version" => artifact.version,
      "artifact_digest" => artifact.artifact_digest,
      "registry_digest" => snapshot.digest
    }

    assert {:ok, decision} =
             OpenAgents.Modules.Router.route(
               snapshot,
               OpenAgents.Modules.RoutingPolicy.default(),
               %{
                 intent_digest: receipt.input_digest,
                 required_capability: "conversation.read",
                 required_side_effect: "read_only",
                 surface: "text",
                 data_scope: "browser_conversation",
                 authorities: MapSet.new(["conversation.read"]),
                 proposal: proposal,
                 exact_proposal: true
               }
             )

    assert {:ok, route} =
             OpenAgents.Modules.RoutingReceipts.persist(receipt.id, call_id, decision)

    route
  end

  defp fresh_turn!(fixture, content) do
    active =
      Repo.one(
        from(t in OpenAgents.Conversations.Turn,
          where:
            t.conversation_id == ^fixture.conversation.id and
              t.status in ["queued", "streaming", "cancelling"]
        )
      )

    if active do
      assert {:ok, _cancelled} = Conversations.cancel_turn(active)
    end

    assert {:ok, records} = Conversations.create_turn(fixture.conversation, content)
    records.turn
  end

  defp bank_id!("experience-bank:v1:" <> id), do: id
end
