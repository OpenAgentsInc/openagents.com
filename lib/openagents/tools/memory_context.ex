defmodule OpenAgents.Tools.MemoryContext do
  @moduledoc false

  import Ecto.Query

  alias OpenAgents.Conversations.{Conversation, Message, Visitor}
  alias OpenAgents.ProfileMemory
  alias OpenAgents.Tools.ExecutionContext
  alias OpenAgents.Repo

  def resolve(%ExecutionContext{} = context) do
    with true <- valid_id?(context.owner_visitor_id),
         true <- valid_id?(context.conversation_id),
         true <- valid_id?(context.current_user_message_id),
         %Visitor{} = owner <- Repo.get(Visitor, context.owner_visitor_id),
         %Message{} = message <- current_message(context),
         {:ok, snapshot} <-
           ProfileMemory.load_snapshot(owner, context.profile_memory_snapshot_ref) do
      {:ok, owner, message, snapshot}
    else
      _invalid -> {:error, :scope_refused}
    end
  end

  def resolve(_context), do: {:error, :scope_refused}

  defp current_message(context) do
    Repo.one(
      from(message in Message,
        join: conversation in Conversation,
        on: conversation.id == message.conversation_id,
        where:
          message.id == ^context.current_user_message_id and
            message.conversation_id == ^context.conversation_id and
            conversation.visitor_id == ^context.owner_visitor_id and message.role == "user" and
            message.status == "complete"
      )
    )
  end

  defp valid_id?(value), do: match?({:ok, _id}, Ecto.UUID.cast(value))
end
