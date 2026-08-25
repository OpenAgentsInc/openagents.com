defmodule OpenAgents.TimelineTest do
  @moduledoc """
  Issue #228: an owner-scoped, ordered timeline across coder/threads,
  voice, and web chat.
  """

  use OpenAgents.DataCase, async: false

  import OpenAgentsWeb.ConnCase, only: [github_user: 1]

  alias OpenAgents.{Conversations, Threads, Timeline}

  defp owner(key), do: github_user("timeline-#{key}")

  describe "for_user/1" do
    test "merges thread events and web chat turns in timestamp order" do
      user = owner("merge")
      {:ok, thread} = Threads.open(user, "Build the timeline")

      {:ok, _thread} =
        Threads.record_event(thread, "thread.turn.started", %{"turn" => 1})

      {:ok, conversation} = Conversations.ensure_conversation(user)

      {:ok, %{turn: turn}} =
        Conversations.create_turn(conversation, "Hello from web chat")

      entries = Timeline.for_user(user)

      assert length(entries) == 3

      coder = Enum.filter(entries, &(&1.modality == :coder))
      chat = Enum.filter(entries, &(&1.modality == :chat))

      assert length(coder) == 2
      assert length(chat) == 1

      opened = Enum.find(coder, &(&1.summary == "Thread opened"))
      started = Enum.find(coder, &(&1.summary == "Thread turn started"))

      assert opened.modality == :coder
      assert opened.kind == :system
      assert opened.record_id == Threads.list_events(thread) |> hd() |> Map.fetch!(:id)

      assert started.modality == :coder
      assert started.kind == :turn

      [chat_turn] = chat
      assert chat_turn.modality == :chat
      assert chat_turn.kind == :turn
      assert chat_turn.record_id == turn.id
      assert chat_turn.summary =~ "Hello from web chat"

      timestamps = Enum.map(entries, & &1.timestamp)
      assert timestamps == Enum.sort(timestamps)
    end

    test "excludes records owned by another account" do
      me = owner("me")
      other = owner("other")

      {:ok, _my_thread} = Threads.open(me, "My private work")
      {:ok, _other_thread} = Threads.open(other, "Their private work")

      my_entries = Timeline.for_user(me)
      other_entries = Timeline.for_user(other)

      assert length(my_entries) == 1
      assert length(other_entries) == 1
      refute List.first(my_entries).record_id == List.first(other_entries).record_id
    end

    test "returns an empty list for an account with no visitor" do
      user = owner("no-visitor")

      # The account has never opened a thread, chat, or voice session,
      # so no visitor row exists yet and there is nothing to merge.
      entries = Timeline.for_user(user)

      assert entries == []
    end
  end
end
