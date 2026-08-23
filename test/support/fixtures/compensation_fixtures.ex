defmodule OpenAgents.CompensationFixtures do
  @moduledoc """
  Test helpers for accepted-outcome decisions.

  An outcome decision is the accepted-outcome receipt other contexts bind to,
  and it exists only at the end of the real path: a routed tool step, an
  immutable outcome, and an independent review. The helper walks that path so
  callers get a decision no shortcut could have produced.
  """

  import ExUnit.Assertions

  alias OpenAgents.{Compensation, Context.Composer, Conversations}
  alias OpenAgents.Providers.Request

  @doc "An independently reviewed outcome decision, accepted or rejected."
  def outcome_decision_fixture(decision \\ "accepted", reason_code \\ "verified_outcome") do
    suffix = System.unique_integer([:positive, :monotonic])
    step = completed_step("reputation-#{suffix}")

    assert {:ok, record} =
             Compensation.decide_outcome(
               step.id,
               reviewer("reputation-#{suffix}"),
               decision,
               reason_code
             )

    record
  end

  defp completed_step(suffix) do
    %{turn: turn, receipt: receipt} = begin_turn(suffix)
    artifact = artifact()
    route = route!(receipt, "call-#{suffix}", artifact)
    policy = artifact.attribution_policy

    assert {:ok, step, :created} =
             Conversations.request_tool_step(turn, receipt, %{
               provider_call_id: "call-#{suffix}",
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
               cost_units: 100,
               raw_arguments: "{}"
             })

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
      "result" => %{"private" => "private customer result"},
      "error" => nil,
      "target_receipt_refs" => ["message:opaque"],
      "attribution_refs" => ["OpenAgentsInc/openagents.com"],
      "started_at" => "2026-08-16T20:00:00Z",
      "completed_at" => "2026-08-16T20:00:01Z"
    }

    assert {:ok, completed} = Conversations.complete_tool_step(step, outcome)
    completed
  end

  defp begin_turn(browser_key) do
    assert {:ok, conversation} = Conversations.ensure_conversation(browser_key)
    assert {:ok, records} = Conversations.create_turn(conversation, "Use a module.")
    context = Composer.compose!()

    request = %Request{
      model_id: "reputation-test-model",
      instructions: context.instructions,
      input: Conversations.provider_messages(conversation.id)
    }

    assert {:ok, inference} =
             Conversations.begin_inference(records.turn, context, request, "test.provider",
               tool_catalog_digest: OpenAgents.Tools.Registry.current!().digest
             )

    inference
  end

  defp artifact,
    do:
      Map.fetch!(
        OpenAgents.Tools.Registry.current!().modules,
        {"sarah.tool.recall_messages", 1}
      )

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

  defp reviewer(suffix),
    do: %{
      authenticated: true,
      role: "outcome_reviewer",
      actor_id: "outcome-reviewer:test",
      auth_method: "test_session",
      decision_receipt_ref: "outcome-decision:#{suffix}"
    }
end
