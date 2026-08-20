defmodule OpenAgents.ToolStepPersistenceTest do
  use OpenAgents.SarahDataCase
  @moduletag :skip
  import Ecto.Query

  alias OpenAgents.{Context.Composer, Conversations}
  alias OpenAgents.Conversations.ToolStep
  alias OpenAgents.Providers.Request

  test "provider call IDs create exactly one ordered durable step" do
    %{turn: turn, receipt: receipt} = begin_turn("ordered-tool-steps")

    assert {:ok, first, :created} =
             request_step(turn, receipt, "call-1", "item-1", ~s({"q":"one"}))

    assert {:ok, duplicate, :existing} =
             request_step(turn, receipt, "call-1", "item-1", ~s({"q":"one"}))

    assert duplicate.id == first.id
    assert first.sequence == 1
    assert first.invocation_key =~ ~r/^[0-9a-f]{64}$/
    assert first.routing_receipt_id
    assert first.attribution_policy_id == "sarah.attribution.deterministic_receipts.v1"
    assert first.attribution_policy_version == 1
    assert first.attribution_policy_digest =~ ~r/^[0-9a-f]{64}$/
    refute first.billable
    assert first.cost_units == 0

    assert {:ok, second, :created} =
             request_step(turn, receipt, "call-2", "item-2", ~s({"q":"two"}))

    assert second.sequence == 2

    assert OpenAgents.Repo.aggregate(
             from(step in ToolStep, where: step.turn_id == ^turn.id),
             :count
           ) == 2

    assert OpenAgents.Repo.aggregate(
             from(route in OpenAgents.Modules.RouteReceipt,
               where: route.turn_receipt_id == ^receipt.id
             ),
             :count
           ) == 2

    assert {:error, :provider_call_id_conflict} =
             request_step(turn, receipt, "call-1", "changed-item", ~s({"q":"changed"}))
  end

  test "raw arguments persist durably beside their digest and refuse the byte ceiling" do
    %{turn: turn, receipt: receipt} = begin_turn("raw-argument-tool-steps")

    assert {:ok, step, :created} =
             request_step(turn, receipt, "call-raw", "item-raw", ~s({"q":"needle"}))

    stored = OpenAgents.Repo.get!(ToolStep, step.id)
    assert stored.raw_arguments == ~s({"q":"needle"})
    assert stored.argument_digest == OpenAgents.Provenance.Canonical.digest!(%{"q" => "needle"})

    oversized = ~s({"q":") <> String.duplicate("a", 262_144) <> ~s("})

    assert {:error, :invalid_tool_arguments} =
             request_step(turn, receipt, "call-oversized", "item-oversized", oversized)
  end

  test "account export carries tool-step raw arguments and complete deletion removes the rows" do
    {:ok, user} =
      OpenAgents.Accounts.upsert_github_user(%{
        github_id: 991_101,
        github_login: "tool-step-rights-owner",
        github_avatar_url: "https://avatars.githubusercontent.com/u/991101?v=4"
      })

    {:ok, conversation} = Conversations.ensure_conversation(user)
    %{turn: turn, receipt: receipt} = begin_turn(user)

    assert {:ok, step, :created} =
             request_step(turn, receipt, "call-rights", "item-rights", ~s({"q":"rights"}))

    assert {:ok, _cancelled} = Conversations.cancel_turn(turn)

    owner = Conversations.get_conversation_owner!(conversation)
    assert {:ok, export} = OpenAgents.DataRights.export(user, owner, conversation)

    assert [entry] = export["tool_steps"]
    assert entry["surface"] == "text"
    assert entry["tool_name"] == "recall_messages"
    assert entry["raw_arguments"] == ~s({"q":"rights"})
    assert entry["argument_digest"] == step.argument_digest
    refute export["tool_steps_truncated"]

    assert {:ok, :deleted} = OpenAgents.DataRights.delete(user, owner, conversation)
    assert OpenAgents.Repo.get(ToolStep, step.id) == nil
  end

  test "requested, running, and terminal transitions are idempotent" do
    %{turn: turn, receipt: receipt} = begin_turn("transition-tool-steps")
    assert {:ok, step, :created} = request_step(turn, receipt, "call-transition", "item-1", "{}")
    assert {:error, :tool_step_not_terminal} = Conversations.tool_continuation_output(step)

    assert {:ok, running, :started} = Conversations.start_tool_step(step)
    assert running.status == "running"
    assert {:ok, same_running, :already_running} = Conversations.start_tool_step(running)
    assert same_running.id == running.id

    outcome = outcome(step, "succeeded", %{"matches" => ["message:1"]})
    assert {:ok, completed} = Conversations.complete_tool_step(running, outcome)
    assert completed.status == "succeeded"
    assert completed.outcome_digest
    assert completed.outcome_receipt_ref == "module-outcome:v1:#{completed.outcome_digest}"
    assert completed.usage == %{"invocations" => 1}

    assert {:ok, same_completed} = Conversations.complete_tool_step(completed, outcome)
    assert same_completed.id == completed.id

    assert {:error, :tool_outcome_conflict} =
             Conversations.complete_tool_step(
               completed,
               outcome(step, "succeeded", %{"changed" => true})
             )

    assert {:ok, continuation} = Conversations.tool_continuation_output(completed)
    assert continuation["call_id"] == "call-transition"
    assert continuation["outcome_digest"] == completed.outcome_digest
    assert continuation["output"]["result"] == %{"matches" => ["message:1"]}
    assert continuation["output"]["outcome_receipt_ref"] == completed.outcome_receipt_ref
    assert continuation["output"]["executor"]["disclosure"] == "Sarah local recall"

    assert continuation["output"]["attribution_policy"]["digest"] ==
             completed.attribution_policy_digest

    assert continuation["output"]["cost"] == %{"units" => 0, "billable" => false}
  end

  test "completion is blocked until every tool outcome is committed" do
    %{turn: turn, receipt: receipt} = begin_turn("continuation-ordering")
    assert {:ok, step, :created} = request_step(turn, receipt, "call-active", "item-1", "{}")
    assert {:ok, _running, :started} = Conversations.start_tool_step(step)

    assert {:error, :active_tool_step_exists} =
             Conversations.complete_turn(turn, "response-too-early")

    assert Conversations.get_turn!(turn.id).status == "streaming"

    assert {:ok, cancelled_turn} = Conversations.cancel_turn(turn)
    assert cancelled_turn.status == "cancelled"
    assert OpenAgents.Repo.get!(ToolStep, step.id).status == "cancelled"
  end

  test "restart recovery interrupts requested and running steps" do
    requested = begin_turn("recovery-requested")

    assert {:ok, requested_step, :created} =
             request_step(requested.turn, requested.receipt, "call-r", "item-r", "{}")

    running = begin_turn("recovery-running")

    assert {:ok, running_step, :created} =
             request_step(running.turn, running.receipt, "call-x", "item-x", "{}")

    assert {:ok, _running_step, :started} = Conversations.start_tool_step(running_step)

    assert :ok = Conversations.recover_interrupted_turns()

    for step <- [requested_step, running_step] do
      recovered = OpenAgents.Repo.get!(ToolStep, step.id)
      assert recovered.status == "interrupted"
      assert recovered.outcome_digest

      assert recovered.error == %{
               "code" => "runtime_restarted",
               "message" => "The tool call ended with the containing turn."
             }
    end
  end

  test "activity projections carry durable outcome truth without provider identifiers" do
    %{turn: turn, receipt: receipt} = begin_turn("tool-activity")
    assert {:ok, step, :created} = request_step(turn, receipt, "call-private", "item-p", "{}")

    assert {:ok, completed} =
             Conversations.complete_tool_step(
               step,
               outcome(step, "succeeded", %{"private" => "server-side"})
             )

    assert [activity] = Conversations.list_tool_step_activity(turn)
    assert activity.status == "succeeded"
    assert activity.executor_disclosure == "Sarah local recall"
    assert activity.executor_id == "sarah.local"
    assert activity.module_id == completed.module_id
    assert activity.module_artifact_digest == completed.module_artifact_digest
    assert activity.outcome_receipt_ref == completed.outcome_receipt_ref
    assert activity.attribution_policy_id == completed.attribution_policy_id

    # The projection carries the durable scrubbed outcome for the event-header
    # expansion (issue #79); the view byte-caps it. Provider identifiers never
    # enter the projection.
    assert activity.result == %{"private" => "server-side"}
    refute Map.has_key?(activity, :provider_call_id)
    refute Map.has_key?(activity, :provider_item_id)
    refute Map.has_key?(activity, :provider_response_id)
    assert OpenAgents.Repo.get!(ToolStep, completed.id).result == %{"private" => "server-side"}
  end

  test "historical invocation provenance survives module revocation" do
    %{turn: turn, receipt: receipt} = begin_turn("historical-module-invocation")
    assert {:ok, step, :created} = request_step(turn, receipt, "call-history", "item-h", "{}")

    assert {:ok, completed} =
             Conversations.complete_tool_step(step, outcome(step, "succeeded", %{}))

    operator = %{
      authenticated: true,
      role: "operator",
      actor_id: "operator:test",
      auth_method: "test_session",
      approval_receipt_ref: "operator-approval:historical-revoke"
    }

    assert {:ok, _lifecycle_receipt, revoked} =
             OpenAgents.Modules.Lifecycle.transition(
               OpenAgents.Tools.Registry.current!(),
               completed.module_id,
               completed.tool_version,
               "revoke",
               operator,
               %{"reason" => "Verify historical invocation retention."}
             )

    assert {:error, :module_ineligible} =
             OpenAgents.Modules.Registry.fetch(
               revoked,
               completed.module_id,
               completed.tool_version
             )

    assert [activity] = Conversations.list_tool_step_activity(turn)
    assert activity.module_artifact_digest == completed.module_artifact_digest
    assert activity.executor_disclosure == "Sarah local recall"
    assert activity.outcome_receipt_ref == completed.outcome_receipt_ref
  end

  test "the database rejects terminal outcome rewriting" do
    %{turn: turn, receipt: receipt} = begin_turn("terminal-tool-step")
    assert {:ok, step, :created} = request_step(turn, receipt, "call-terminal", "item-t", "{}")

    assert {:ok, completed} =
             Conversations.complete_tool_step(step, outcome(step, "succeeded", %{}))

    assert_raise Postgrex.Error, fn ->
      OpenAgents.Repo.update_all(
        from(stored_step in ToolStep, where: stored_step.id == ^completed.id),
        set: [status: "failed"]
      )
    end
  end

  defp begin_turn(browser_key) do
    assert {:ok, conversation} = Conversations.ensure_conversation(browser_key)
    assert {:ok, records} = Conversations.create_turn(conversation, "Use durable tools.")
    context = Composer.compose!()
    messages = Conversations.provider_messages(conversation.id)

    request = %Request{
      model_id: "tool-model",
      instructions: context.instructions,
      input: messages
    }

    assert {:ok, inference} =
             Conversations.begin_inference(records.turn, context, request, "test.provider",
               tool_catalog_digest: OpenAgents.Tools.Registry.current!().digest
             )

    inference
  end

  defp request_step(turn, receipt, call_id, item_id, raw_arguments) do
    artifact = module_artifact()
    routing_receipt = routing_receipt!(receipt, call_id, artifact)
    policy = artifact.attribution_policy

    Conversations.request_tool_step(turn, receipt, %{
      provider_call_id: call_id,
      provider_item_id: item_id,
      provider_response_id: "response-1",
      tool_name: "recall_messages",
      tool_version: 1,
      module_id: "sarah.tool.recall_messages",
      module_artifact_digest: artifact.artifact_digest,
      executor_implementation_digest: artifact.implementation_digest,
      routing_receipt_id: routing_receipt.id,
      side_effect_class: artifact.side_effect_class,
      attribution_policy_id: policy["id"],
      attribution_policy_version: policy["version"],
      attribution_policy_digest: policy["digest"],
      cost_units: artifact.facets["cost_units"],
      raw_arguments: raw_arguments
    })
  end

  defp outcome(step, status, result) do
    %{
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
      "status" => status,
      "result" => result,
      "error" => nil,
      "target_receipt_refs" => ["message:1"],
      "attribution_refs" => ["OpenAgentsInc/sarah"],
      "started_at" => "2026-08-16T20:00:00Z",
      "completed_at" => "2026-08-16T20:00:01Z"
    }
  end

  defp module_artifact do
    Map.fetch!(OpenAgents.Tools.Registry.current!().modules, {"sarah.tool.recall_messages", 1})
  end

  defp routing_receipt!(receipt, call_id, artifact) do
    snapshot = OpenAgents.Tools.Registry.current!()
    policy = OpenAgents.Modules.RoutingPolicy.default()

    proposal = %{
      "module_id" => artifact.module_id,
      "version" => artifact.version,
      "artifact_digest" => artifact.artifact_digest,
      "registry_digest" => snapshot.digest
    }

    assert {:ok, decision} =
             OpenAgents.Modules.Router.route(snapshot, policy, %{
               intent_digest: receipt.input_digest,
               required_capability: "conversation.read",
               required_side_effect: "read_only",
               surface: "text",
               data_scope: "browser_conversation",
               authorities: MapSet.new(["conversation.read"]),
               proposal: proposal,
               exact_proposal: true
             })

    assert {:ok, route} =
             OpenAgents.Modules.RoutingReceipts.persist(receipt.id, call_id, decision)

    assert route.surface == "text"
    route
  end
end
