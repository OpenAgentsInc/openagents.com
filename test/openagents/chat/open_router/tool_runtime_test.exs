defmodule OpenAgents.Chat.OpenRouter.ToolRuntimeTest do
  use OpenAgents.DataCase, async: false

  alias OpenAgents.Chat.OpenRouter.ToolRuntime
  alias OpenAgents.Conversations
  alias OpenAgents.Tools.OwnerContext

  test "a context that cannot name its visitor builds the unbound context" do
    # The fallback this replaces was `owner_visitor_id || owner_user_id`. It
    # turned a missing visitor id into an account id that no `visitors` row
    # answers to, and the resulting refusal read as a sign-in problem. An
    # unbound context says the true thing: there is no owner here.
    user = repository_user_fixture("tool-runtime-unbound")
    {:ok, conversation} = Conversations.ensure_conversation(user)

    assert {:ok, runtime} =
             ToolRuntime.capture(
               tool_context: %{
                 surface: "text",
                 conversation_id: conversation.id,
                 owner_user_id: user.id
               }
             )

    context = runtime.execution_context
    assert context.scope_ref == "conversation:unbound"
    assert context.owner_visitor_id == nil
    assert MapSet.size(context.authorities) == 0
    assert {:error, :owner_not_signed_in} = OwnerContext.resolve(context)
  end

  test "a context naming its visitor resolves the owner every tool asks for" do
    user = repository_user_fixture("tool-runtime-bound")
    {:ok, conversation} = Conversations.ensure_conversation(user)
    owner = Conversations.get_conversation_owner!(conversation)

    assert {:ok, runtime} =
             ToolRuntime.capture(
               tool_context: %{
                 surface: "text",
                 conversation_id: conversation.id,
                 owner_visitor_id: owner.id,
                 owner_user_id: owner.user_id
               }
             )

    assert runtime.execution_context.scope_ref == "conversation:#{conversation.id}"
    assert {:ok, resolved} = OwnerContext.resolve(runtime.execution_context)
    assert resolved.id == user.id
  end
end
