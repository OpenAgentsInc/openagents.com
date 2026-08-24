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

  test "another thread's subscriber hears nothing" do
    user = github_user("thread-broadcast-scope")
    {:ok, mine} = Threads.open(user, "Mine")
    {:ok, other} = Threads.open(user, "Other")

    :ok = Threads.subscribe(other)

    {:ok, _updated} = Threads.record_event(mine, "turn.user", %{"text" => "scoped"})

    refute_receive {:thread_event, _event}
  end
end
