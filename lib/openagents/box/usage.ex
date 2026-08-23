defmodule OpenAgents.Box.Usage do
  @moduledoc "Aggregated accumulated Box lifetime and settled cost."

  import Ecto.Query

  alias OpenAgents.Box.ConversationBox
  alias OpenAgents.Conversations.Conversation
  alias OpenAgents.Repo

  @spec for_conversation(String.t()) :: map()
  def for_conversation(conversation_id) when is_binary(conversation_id) do
    aggregate(from box in ConversationBox, where: box.conversation_id == ^conversation_id)
  end

  @spec for_owner(String.t()) :: map()
  def for_owner(owner_id) when is_binary(owner_id) do
    aggregate(
      from box in ConversationBox,
        join: conversation in Conversation,
        on: conversation.id == box.conversation_id,
        join: visitor in assoc(conversation, :visitor),
        where: visitor.user_id == ^owner_id
    )
  end

  defp aggregate(query) do
    {lifetime_seconds, settled_cost_microusd, boxes} =
      Repo.one(
        from box in query,
          select: {
            coalesce(sum(box.lifetime_seconds), 0),
            coalesce(sum(box.settled_cost_microusd), 0),
            count(box.id)
          }
      )

    %{
      lifetime_seconds: integer_value(lifetime_seconds),
      settled_cost_microusd: integer_value(settled_cost_microusd),
      boxes: boxes
    }
  end

  defp integer_value(%Decimal{} = value), do: Decimal.to_integer(value)
  defp integer_value(value), do: value
end
