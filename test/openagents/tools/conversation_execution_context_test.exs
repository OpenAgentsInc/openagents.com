defmodule OpenAgents.Tools.ConversationExecutionContextTest do
  use OpenAgents.DataCase, async: false

  alias OpenAgents.AccountsFixtures
  alias OpenAgents.Conversations
  alias OpenAgents.Machines
  alias OpenAgents.Modules.{Router, RoutingPolicy, SurfacePolicy}
  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Tools.{ConversationExecutionContext, Registry, ScvDeploy}

  setup do
    original_admin_ids = Application.get_env(:openagents, :admin_github_ids, [])

    on_exit(fn ->
      Application.put_env(:openagents, :admin_github_ids, original_admin_ids)
    end)

    :ok
  end

  test "text and voice share conversation authorities and operator receipts" do
    user = AccountsFixtures.repository_user_fixture("conversation-context-operator")
    {:ok, conversation} = Conversations.ensure_conversation(user)

    Application.put_env(:openagents, :admin_github_ids, [user.github_id])

    text = build("text", conversation, user)
    voice = build("voice", conversation, user)

    assert text.authorities == voice.authorities
    assert text.approval_receipts == voice.approval_receipts
    assert "scv.deploy" in text.authorities

    assert Enum.any?(text.approval_receipts, fn receipt ->
             receipt["module_id"] == "sarah.tool.scv_deploy.v1" and
               receipt["scope_ref"] == "conversation:#{conversation.id}" and
               receipt["receipt_ref"] == "operator:#{user.id}"
           end)

    assert {:ok, snapshot} = Registry.build([ScvDeploy])
    assert {:ok, artifact} = Registry.module_for_tool(snapshot, "scv_deploy", 1)
    assert :ok = SurfacePolicy.authorize_execution(artifact, voice)

    assert %RoutingPolicy{id: "sarah.routing.policy.operator.v1"} =
             policy = ConversationExecutionContext.routing_policy(user.id)

    proposal = %{
      "module_id" => artifact.module_id,
      "version" => artifact.version,
      "artifact_digest" => artifact.artifact_digest,
      "registry_digest" => snapshot.digest
    }

    route_input = %{
      intent_digest: Canonical.sha256("deploy an SCV"),
      required_capability: "scv.deploy",
      required_side_effect: "external_effect",
      surface: "text",
      data_scope: "browser_conversation",
      authorities: text.authorities,
      proposal: proposal,
      exact_proposal: true
    }

    assert {:ok, decision} = Router.route(snapshot, policy, route_input)
    assert decision.status == "selected"
    assert {:ok, ^artifact} = Router.revalidate(decision, snapshot, policy, route_input)
  end

  test "non-operators receive the shared authorities without an SCV receipt" do
    user = AccountsFixtures.repository_user_fixture("conversation-context-member")
    {:ok, conversation} = Conversations.ensure_conversation(user)

    context = build("voice", conversation, user)

    assert "scv.deploy" in context.authorities

    refute Enum.any?(context.approval_receipts, fn receipt ->
             receipt["module_id"] == "sarah.tool.scv_deploy.v1"
           end)

    assert {:ok, snapshot} = Registry.build([ScvDeploy])
    assert {:ok, artifact} = Registry.module_for_tool(snapshot, "scv_deploy", 1)

    assert {:error, :module_approval_required} =
             SurfacePolicy.authorize_execution(artifact, context)

    assert %RoutingPolicy{id: "sarah.routing.policy.default.v1"} =
             ConversationExecutionContext.routing_policy(user.id)
  end

  test "an active paired machine retains the paired-machine routing policy" do
    user = AccountsFixtures.repository_user_fixture("conversation-context-machine")

    {:ok, %{code: code}} =
      Machines.start_pairing(%{
        "name" => "context-machine",
        "tier" => "probe",
        "platform" => "linux-x64",
        "agent_version" => "0.1.0",
        "roots" => ["/workspace"]
      })

    assert {:ok, _machine} = Machines.approve_pairing(user, code)

    assert %RoutingPolicy{id: "sarah.routing.policy.paired-machine.v1"} =
             ConversationExecutionContext.routing_policy(user.id)
  end

  defp build(surface, conversation, user) do
    ConversationExecutionContext.build(%{
      surface: surface,
      conversation_id: conversation.id,
      current_user_message_id: Ecto.UUID.generate(),
      owner_visitor_id: conversation.visitor_id,
      owner_user_id: user.id,
      memory_snapshot_ref: "memory-snapshot:test",
      profile_memory_snapshot_ref: "profile-memory-snapshot:test",
      module_registry_snapshot: :snapshot
    })
  end
end
