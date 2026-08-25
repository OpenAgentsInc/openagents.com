defmodule OpenAgentsWeb.ConversationController do
  @moduledoc """
  Names the account's conversation to a client that holds a `box:control` token.

  Every Box route is addressed by conversation, so a client that does not
  already know its conversation id cannot reach any of them, and nothing told
  it: `GET /api/v1/user` answers the forge identity, and it sits behind
  `forge:write`, which a box token does not carry.

  This is the one route that answers the question, deliberately. The field
  could have been added to `/api/v1/user` instead, but that response is
  GitHub-shaped, and API-001 holds every OpenAgents field there to a namespaced
  `openagents` object. A route of our own carries it at the top level without
  bending that rule, and one canonical answer beats two ways to learn the same
  fact.

  An account has exactly one conversation, and this endpoint creates it when
  it is absent rather than refusing. The alternative dead-ends a headless
  caller: a `box:control` token with no conversation has no route left to try,
  and the only way to get one would be to open a browser. `ensure_conversation/1`
  is the same idempotent call the web chat makes on first visit, so the two
  paths converge on one row instead of racing to make a second.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.Conversations
  alias OpenAgents.Conversations.Conversation

  def show(conn, _params) do
    case conversation(conn.assigns.current_user) do
      {:ok, %Conversation{} = conversation} ->
        json(conn, %{
          "conversation_id" => conversation.id,
          "conversation" => %{
            "id" => conversation.id,
            "created_at" => DateTime.to_iso8601(conversation.inserted_at)
          }
        })

      :error ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{"error" => %{"code" => "conversation_unavailable"}})
    end
  end

  defp conversation(user) do
    case Conversations.get_conversation_for_user(user) do
      %Conversation{} = conversation ->
        {:ok, conversation}

      nil ->
        case Conversations.ensure_conversation(user) do
          {:ok, %Conversation{} = conversation} -> {:ok, conversation}
          _other -> :error
        end
    end
  end
end
