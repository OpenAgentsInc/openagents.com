defmodule OpenAgents.Threads.EventBroadcastTest do
  use OpenAgents.DataCase, async: false

  import OpenAgentsWeb.ConnCase, only: [github_user: 1]

  alias OpenAgents.Threads
  alias OpenAgents.Threads.Event

  test "a committed append is broadcast on the thread's topic" do
    user = github_user("thread-broadcast")
    {:ok, thread} = Threads.open(user, "Broadcast the transcript")

    :ok = Threads.subscribe(thread)

    {:ok, _updated} = Threads.record_event(thread, "turn.user", %{"text" => "hello"})

    assert_receive {:thread_event, %Event{event_type: "turn.user", payload: %{"text" => "hello"}}}
  end

  test "a refused append broadcasts nothing" do
    user = github_user("thread-broadcast-terminal")
    {:ok, thread} = Threads.open(user, "Terminal threads stay silent")
    {:ok, cancelled} = Threads.cancel(thread)

    :ok = Threads.subscribe(cancelled)

    assert {:error, :thread_terminal} =
             Threads.record_event(cancelled, "turn.user", %{"text" => "late"})

    refute_receive {:thread_event, _event}
  end

  test "a committed batch broadcasts each event once, in order" do
    user = github_user("thread-broadcast-batch")
    {:ok, thread} = Threads.open(user, "Broadcast the batch")

    :ok = Threads.subscribe(thread)

    {:ok, _updated, events} =
      Threads.record_events(thread, [
        %{event_type: "turn.user", payload: %{"text" => "first"}},
        %{event_type: "tool.ran", payload: %{"tool" => "bash"}},
        %{event_type: "turn.assistant", payload: %{"text" => "third"}}
      ])

    # A subscriber cannot tell a batch from the same events posted one at a
    # time: one message per event, in the order they landed, none repeated.
    for event <- events do
      assert_receive {:thread_event, %Event{} = received}
      assert received.id == event.id
      assert received.event_type == event.event_type
    end

    refute_receive {:thread_event, _event}
  end

  test "a batch that rolls back broadcasts nothing" do
    user = github_user("thread-broadcast-rollback")
    {:ok, thread} = Threads.open(user, "Rolled back batches stay silent")

    :ok = Threads.subscribe(thread)

    assert {:error, {1, %Ecto.Changeset{}}} =
             Threads.record_events(thread, [
               %{event_type: "turn.user", payload: %{"text" => "valid"}},
               %{event_type: String.duplicate("x", 81), payload: %{}}
             ])

    # The first entry was inserted and then rolled back with the second, so a
    # subscriber must never have heard about it.
    refute_receive {:thread_event, _event}
    assert Threads.list_events(thread) |> Enum.map(& &1.event_type) == ["thread.opened"]
  end

  test "another thread's subscriber hears nothing" do
    user = github_user("thread-broadcast-scope")
    {:ok, mine} = Threads.open(user, "Mine")
    {:ok, other} = Threads.open(user, "Other")

    :ok = Threads.subscribe(other)

    {:ok, _updated} = Threads.record_event(mine, "turn.user", %{"text" => "scoped"})

    refute_receive {:thread_event, _event}
  end
end
