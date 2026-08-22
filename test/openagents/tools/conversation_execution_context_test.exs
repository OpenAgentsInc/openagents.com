defmodule OpenAgents.Tools.ConversationExecutionContextTest do
  use OpenAgents.DataCase, async: false

  alias OpenAgents.AccountsFixtures
  alias OpenAgents.Conversations
  alias OpenAgents.Modules.SurfacePolicy
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
