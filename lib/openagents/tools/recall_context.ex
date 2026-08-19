defmodule OpenAgents.Tools.RecallContext do
  @moduledoc false

  alias OpenAgents.Conversations.Conversation
  alias OpenAgents.Memory.LexicalRecall
  alias OpenAgents.Repo
  alias OpenAgents.Tools.ExecutionContext

  def resolve(%ExecutionContext{
        scope: "browser_conversation",
        scope_ref: scope_ref,
        conversation_id: conversation_id,
        memory_snapshot_ref: snapshot_ref
      })
      when is_binary(conversation_id) and is_binary(snapshot_ref) do
    if scope_ref == "conversation:#{conversation_id}" do
      with %Conversation{} = conversation <- Repo.get(Conversation, conversation_id),
           {:ok, snapshot} <- LexicalRecall.load_snapshot(conversation, snapshot_ref) do
        {:ok, conversation, snapshot}
      else
        _invalid_host_context -> {:error, :scope_refused}
      end
    else
      {:error, :scope_refused}
    end
  end

  def resolve(%ExecutionContext{}), do: {:error, :scope_refused}
end
