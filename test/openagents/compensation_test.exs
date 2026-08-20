defmodule OpenAgents.CompensationTest do
  use OpenAgents.SarahDataCase, async: false
  @moduletag :skip
  alias OpenAgents.{Compensation, Context.Composer, Conversations}
  alias OpenAgents.Compensation.{Event, Statement}
  alias OpenAgents.Providers.Request

  test "accepted attributable usage reconciles once and adjustments never imply payout" do
    policy = policy!()
    artifact = artifact()
    register!(policy, artifact)
    step = completed_step("eligible", 100, "private customer result")

    assert {:error, :outcome_decision_missing} = Compensation.account(step.id, policy)

    assert {:ok, decision} =
             Compensation.decide_outcome(
               step.id,
               reviewer("accept"),
               "accepted",
               "verified_outcome"
             )

    assert decision.outcome_receipt_ref == step.outcome_receipt_ref

    assert {:error, %Ecto.Changeset{}} =
             Compensation.decide_outcome(
               step.id,
               reviewer("duplicate"),
               "accepted",
               "verified_outcome"
             )

    assert {:ok, %{event: event, shares: [share]}} = Compensation.account(step.id, policy)
    assert event.classification == "eligible"
    assert event.technical_units == 100
    assert event.eligible_units == 100
    assert share.contribution_ref == "OpenAgentsInc/sarah"
    assert share.allocated_units == 100

    assert {:ok, %{event: same, shares: [same_share]}} = Compensation.account(step.id, policy)
    assert same.id == event.id
    assert same_share.id == share.id
    assert Repo.aggregate(Event, :count) == 1

    assert {:ok, adjustment} =
             Compensation.adjust(
               event,
               share.contribution_ref,
               operator("refund"),
               "refund",
               -25,
               "customer_refund"
             )

    assert adjustment.delta_units == -25

    assert {:ok, statement} =
             Compensation.reconcile(share.contribution_ref, policy, operator("statement"))

    assert statement.gross_units == 100
    assert statement.adjustment_units == -25
    assert statement.net_units == 75
    assert statement.state == "reconciled"

    projection = Compensation.statement_projection(statement)
    refute Jason.encode!(projection) =~ "private customer result"
    assert projection["payout_authority"] == false
    refute function_exported?(Compensation, :payout, 2)
  end

  test "an invocation or rejected outcome alone cannot become payable" do
    policy = policy!()
    register!(policy, artifact())
    step = completed_step("rejected", 80, "not accepted")

    assert {:ok, _decision} =
             Compensation.decide_outcome(
               step.id,
               reviewer("reject"),
               "rejected",
               "utility_failed"
             )

    assert {:ok, %{event: event, shares: [share]}} = Compensation.account(step.id, policy)
    assert event.classification == "ineligible"
    assert event.reason_code == "outcome_rejected"
    assert event.technical_units == 80
    assert event.eligible_units == 0
    assert share.allocated_units == 0
  end

  test "revocation blocks future eligibility but preserves historical accounting" do
    policy = policy!()
    artifact = artifact()
    register!(policy, artifact)

    before = completed_step("before-revoke", 40, "accepted")

    assert {:ok, _} =
             Compensation.decide_outcome(
               before.id,
               reviewer("before"),
               "accepted",
               "verified_outcome"
             )

    assert {:ok, %{event: historical}} = Compensation.account(before.id, policy)
    assert historical.classification == "eligible"

    assert {:ok, _receipt, _snapshot} =
             OpenAgents.Modules.Lifecycle.transition(
               OpenAgents.Tools.Registry.current!(),
               artifact.module_id,
               artifact.version,
               "revoke",
               operator("module-revoke"),
               %{"reason" => "Revoke before later accounting classification."}
             )

    after_revocation = completed_step("after-revoke", 40, "accepted later")

    assert {:ok, _} =
             Compensation.decide_outcome(
               after_revocation.id,
               reviewer("after"),
               "accepted",
               "verified_outcome"
             )

    assert {:ok, %{event: blocked}} = Compensation.account(after_revocation.id, policy)
    assert blocked.classification == "ineligible"
    assert blocked.reason_code == "module_revoked"
    assert Repo.get!(Event, historical.id).eligible_units == 40
  end

  test "shared allocations are deterministic, exact, and order independent" do
    allocations = [
      %{contribution_ref: "contribution:b", allocation_ppm: 666_667},
      %{contribution_ref: "contribution:a", allocation_ppm: 333_333}
    ]

    first = Compensation.allocate_units(101, allocations)
    second = Compensation.allocate_units(101, Enum.reverse(allocations))
    assert first == second
    assert Enum.sum(Enum.map(first, & &1.allocated_units)) == 101
    assert Enum.map(first, & &1.contribution_ref) == ["contribution:a", "contribution:b"]
  end

  test "fraud holds and dispute resolution reconcile through later receipts" do
    policy = policy!()
    register!(policy, artifact())
    step = completed_step("dispute", 50, "private disputed result")

    assert {:ok, _} =
             Compensation.decide_outcome(
               step.id,
               reviewer("dispute"),
               "accepted",
               "verified_outcome"
             )

    assert {:ok, %{event: event, shares: [share]}} = Compensation.account(step.id, policy)

    assert {:ok, _} =
             Compensation.adjust(
               event,
               share.contribution_ref,
               operator("hold"),
               "fraud_hold",
               -10,
               "fraud_review"
             )

    assert {:ok, disputed} =
             Compensation.reconcile(
               share.contribution_ref,
               policy,
               operator("disputed-statement")
             )

    assert disputed.state == "disputed"
    assert disputed.net_units == 40

    assert {:ok, _} =
             Compensation.adjust(
               event,
               share.contribution_ref,
               operator("resolve"),
               "dispute_resolution",
               10,
               "fraud_cleared"
             )

    assert {:ok, resolved} =
             Compensation.reconcile(
               share.contribution_ref,
               policy,
               operator("resolved-statement")
             )

    assert resolved.state == "reconciled"
    assert resolved.net_units == 50
  end

  test "immutable reconciliation receipts reject rewriting" do
    policy = policy!()
    register!(policy, artifact())

    assert {:ok, statement} =
             Compensation.reconcile("OpenAgentsInc/sarah", policy, operator("empty-statement"))

    assert_raise Postgrex.Error, fn ->
      statement |> Ecto.Changeset.change(net_units: 999) |> Repo.update!()
    end

    assert Repo.aggregate(Statement, :count) == 1
  end

  defp policy! do
    assert {:ok, policy} = Compensation.admit_policy(operator("policy"))
    policy
  end

  defp register!(policy, artifact) do
    assert {:ok, [_allocation]} =
             Compensation.register_module(
               policy,
               artifact,
               [%{"contribution_ref" => "OpenAgentsInc/sarah", "allocation_ppm" => 1_000_000}],
               operator("module-allocation")
             )
  end

  defp completed_step(suffix, cost_units, private_result) do
    %{turn: turn, receipt: receipt} = begin_turn("compensation-#{suffix}")
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
               cost_units: cost_units,
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
      "result" => %{"private" => private_result},
      "error" => nil,
      "target_receipt_refs" => ["message:opaque"],
      "attribution_refs" => ["OpenAgentsInc/sarah"],
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
      model_id: "accounting-test-model",
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

  defp operator(suffix),
    do: %{
      authenticated: true,
      role: "operator",
      actor_id: "operator:test",
      auth_method: "test_session",
      approval_receipt_ref: "accounting-operator:#{suffix}:#{System.unique_integer([:positive])}"
    }

  defp reviewer(suffix),
    do: %{
      authenticated: true,
      role: "outcome_reviewer",
      actor_id: "outcome-reviewer:test",
      auth_method: "test_session",
      decision_receipt_ref: "outcome-decision:#{suffix}:#{System.unique_integer([:positive])}"
    }
end
