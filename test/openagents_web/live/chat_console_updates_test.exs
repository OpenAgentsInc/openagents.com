defmodule OpenAgentsWeb.ChatConsoleUpdatesTest do
  @moduledoc """
  The Ox Alpha console as a live surface (#159, following #154).

  The console renders `AccountTurns.list_messages/1`, a projection of
  `account_chat_runs`. Those writes never create a `Conversations.Message` and
  never announce on the conversation topic, so the audit's suggested publisher
  would have subscribed this page to a topic that never fires for what it
  draws. `AccountTurns` announces its own turns now, and this file holds the
  console to it: a turn taken through the account API appears here, a turn
  finishing there finishes here, and one account's turns never reach another
  account's console.
  """

  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OpenAgents.Chat.AccountTurns
  alias OpenAgents.Conversations

  setup %{conn: conn} do
    operator = github_user("chat-console-live-operator")
    grant_operator(operator)

    %{
      conn: Plug.Test.init_test_session(conn, %{"user_id" => operator.id}),
      operator: operator
    }
  end

  test "a turn taken through the account API joins the console", context do
    {:ok, view, _html} = live(context.conn, ~p"/chat")

    assert has_element?(view, "#chat-console-empty")

    {:ok, run} = submit_elsewhere(context.operator, "Summarize the fleet.")

    # No reload: the run announced itself and the console re-read through
    # `list_messages/1`, which resolves this account's own conversation.
    assert has_element?(view, "#chat-console-message-#{run["id"]}-user", "Summarize the fleet.")
    assert has_element?(view, "#chat-console-message-#{run["id"]}-assistant", "Answered.")
    refute has_element?(view, "#chat-console-empty")
  end

  test "another account's turn moves nothing", context do
    other = github_user("chat-console-other-account")

    {:ok, view, _html} = live(context.conn, ~p"/chat")

    {:ok, _run} = submit_elsewhere(other, "Not for this console.")

    # Each console subscribes to its own conversation's topic, so another
    # account's turn is not a message this page has to filter out -- it never
    # arrives, and the read behind it would refuse the rows anyway.
    assert has_element?(view, "#chat-console-empty")
    refute render(view) =~ "Not for this console."
  end

  test "a turn announces when it starts, when it finishes, and when it is cancelled",
       context do
    {:ok, conversation} = Conversations.ensure_conversation(context.operator)
    :ok = AccountTurns.subscribe_turns(conversation.id)
    conversation_id = conversation.id

    held = fn _request, callback, _options ->
      callback.({:text_delta, "Working"})

      receive do
        :never -> {:ok, %{}}
      end
    end

    {:ok, _run} = AccountTurns.submit(context.operator, "Hold the line.", streamer: held)

    assert_receive {:account_turns_changed, ^conversation_id}

    {:ok, _cancelled} = AccountTurns.cancel(context.operator)

    assert_receive {:account_turns_changed, ^conversation_id}

    {:ok, _finished} = submit_elsewhere(context.operator, "And now finish one.")

    # Two: the turn starting, then the turn completing.
    assert_receive {:account_turns_changed, ^conversation_id}
    assert_receive {:account_turns_changed, ^conversation_id}

    # Four announcements for two turns, and no more. Streamed deltas stay off
    # the topic: a run in `streaming` contributes only its user message to what
    # the console reads, and the session holding the stream already has the
    # deltas, so announcing each one would cost a read per token for a
    # projection that did not move.
    refute_receive {:account_turns_changed, _other}, 50
  end

  # The turn a second session takes: it runs to completion without the console
  # in the loop, which is the case the console could not see before.
  defp submit_elsewhere(user, content) do
    test_process = self()

    streamer = fn _request, _callback, _options ->
      {:ok, %{"assistant_content" => "Answered.", "assistant_message_id" => "response-1"}}
    end

    result = AccountTurns.submit(user, content, subscriber: test_process, streamer: streamer)

    with {:ok, %{"id" => run_id}} <- result do
      assert_receive {:account_chat_completed, ^run_id, {:ok, _completion}}
    end

    result
  end
end
