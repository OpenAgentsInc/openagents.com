defmodule OpenAgents.ConversationsTest do
  use OpenAgents.SarahDataCase, async: true
  @moduletag :skip
  alias OpenAgents.Conversations
  alias OpenAgents.Conversations.{Message, Visitor}

  test "one opaque browser key always resolves to one durable conversation" do
    token = "browser-key-one"

    assert {:ok, first} = Conversations.ensure_conversation(token)
    assert {:ok, second} = Conversations.ensure_conversation(token)
    assert first.id == second.id

    visitor = Repo.get_by!(Visitor, id: first.visitor_id)
    refute visitor.browser_key_hash == token
    assert visitor.browser_key_hash == :crypto.hash(:sha256, token)

    {messages, false} = Conversations.list_messages(first)
    assert [%Message{role: "assistant", status: "complete", content: greeting}] = messages
    assert greeting == "Hello. I'm Sarah—an OpenAgent. What are we working on?"
  end

  test "different browser keys receive different canonical conversations" do
    assert {:ok, first} = Conversations.ensure_conversation("browser-key-one")
    assert {:ok, second} = Conversations.ensure_conversation("browser-key-two")
    refute first.id == second.id
  end

  test "turn creation persists both messages and enforces one active turn" do
    assert {:ok, conversation} = Conversations.ensure_conversation("turn-browser")

    assert {:ok, records} = Conversations.create_turn(conversation, "  Think with me.  ")
    assert records.user_message.content == "Think with me."
    assert records.user_message.status == "complete"
    assert records.assistant_message.status == "streaming"
    assert records.turn.status == "queued"

    assert {:error, :turn_in_progress} = Conversations.create_turn(conversation, "Another turn")
    assert {:ok, completed} = Conversations.complete_turn(records.turn, "response-1")
    assert completed.status == "completed"
    assert Conversations.active_turn(conversation) == nil
  end

  test "a failed turn persists the real error code, not just the public message" do
    assert {:ok, conversation} = Conversations.ensure_conversation("failcode-browser")
    assert {:ok, records} = Conversations.create_turn(conversation, "Delegate something big")

    assert {:ok, failed} =
             Conversations.fail_turn(records.turn, {:transport, :provider_task_exited})

    # The user-facing message stays generic; the machine-readable reason is now
    # durable so Sarah and the owner can diagnose it (previously it was dropped).
    assert failed.status == "failed"
    assert failed.error_message =~ "could not finish"
    assert failed.error_code == "transport"
  end

  test "fail_turn types string, exception, and 3-tuple reasons instead of unknown" do
    assert {:ok, conversation} = Conversations.ensure_conversation("failcode-shapes-browser")

    assert {:ok, string_records} = Conversations.create_turn(conversation, "string reason")

    assert {:ok, string_failed} =
             Conversations.fail_turn(string_records.turn, "econnreset from the socket")

    assert string_failed.error_code == "task_exit"
    refute string_failed.error_code == "unknown"

    assert {:ok, conversation} = Conversations.ensure_conversation("failcode-shapes-browser-2")
    assert {:ok, exception_records} = Conversations.create_turn(conversation, "exception reason")

    assert {:ok, exception_failed} =
             Conversations.fail_turn(exception_records.turn, %RuntimeError{message: "boom"})

    assert exception_failed.error_code == "task_exit:RuntimeError"
    refute exception_failed.error_code == "unknown"

    assert {:ok, conversation} = Conversations.ensure_conversation("failcode-shapes-browser-3")
    assert {:ok, triple_records} = Conversations.create_turn(conversation, "triple reason")

    assert {:ok, triple_failed} =
             Conversations.fail_turn(
               triple_records.turn,
               {:transport, :provider_task_exited, :monitor}
             )

    assert triple_failed.error_code == "transport"
    refute triple_failed.error_code == "unknown"
  end

  test "message validation rejects empty and oversized input before persistence" do
    assert {:ok, conversation} = Conversations.ensure_conversation("validation-browser")
    assert {:error, :empty_message} = Conversations.create_turn(conversation, "   ")

    assert {:error, :message_too_long} =
             Conversations.create_turn(conversation, String.duplicate("x", 8_001))
  end

  test "startup recovery makes interrupted turns explicitly failed" do
    assert {:ok, conversation} = Conversations.ensure_conversation("recovery-browser")
    assert {:ok, records} = Conversations.create_turn(conversation, "Do not leave this pending")

    assert :ok = Conversations.recover_interrupted_turns()

    recovered_turn = Repo.get!(OpenAgents.Conversations.Turn, records.turn.id)
    recovered_message = Repo.get!(Message, records.assistant_message.id)

    assert recovered_turn.status == "failed"
    assert recovered_turn.error_message =~ "restarted"
    assert recovered_message.status == "failed"
  end

  test "history is bounded and can be paged backward without duplication" do
    assert {:ok, conversation} = Conversations.ensure_conversation("history-browser")

    for number <- 1..45 do
      %Message{}
      |> Message.changeset(%{
        conversation_id: conversation.id,
        role: "user",
        content: "message #{number}",
        status: "complete"
      })
      |> Repo.insert!()
    end

    {recent, true} = Conversations.list_messages(conversation)
    assert length(recent) == 40

    {older, false} = Conversations.list_messages(conversation, hd(recent).id)
    assert length(older) == 6
    assert MapSet.disjoint?(MapSet.new(recent, & &1.id), MapSet.new(older, & &1.id))
  end
end
