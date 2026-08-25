defmodule OpenAgents.Threads.LocalLaneTest do
  @moduledoc """
  The transcript-only local lane (THREAD-001, issue #243).

  A local-lane thread records a run whose model calls never touch this server:
  its model is the vendor string a local runtime serves, and it holds no
  authority, ever — `mint_grant/1` refuses it the way it refuses a terminal
  thread. Everything else about it is an ordinary thread: the transcript
  appends and broadcasts, the open-thread cap counts it, and cancelling ends
  it. Both halves are proved here, because the lane's contract is exactly that
  pair.
  """
  use OpenAgents.DataCase, async: false

  import OpenAgentsWeb.ConnCase, only: [github_user: 1]

  alias OpenAgents.Threads
  alias OpenAgents.Threads.Event
  alias OpenAgents.Threads.Thread

  @vendor_model "ollama:qwen3.8:27b-mtp-q8_0"

  defp owner(key), do: github_user("local-lane-#{key}")

  defp open_local(user, objective) do
    Threads.open(user, objective, lane: "local", model: @vendor_model)
  end

  describe "open/3 on the local lane" do
    test "records the vendor model string and mints nothing" do
      user = owner("open")

      assert {:ok, thread} = open_local(user, "Record a local run")

      assert thread.lane == "local"
      assert thread.status == "open"
      assert thread.model == @vendor_model
      # No mint means no fence bump and no grant row: the thread has never
      # held authority, not merely lost it.
      assert thread.generation == 0
      assert Threads.active_grants(thread) == []
      assert Threads.latest_grant(thread) == nil
    end

    test "the opened event names the lane" do
      user = owner("opened-event")

      {:ok, thread} = open_local(user, "Name the lane up front")

      assert [%Event{event_type: "thread.opened", payload: payload}] = Threads.list_events(thread)
      assert payload["lane"] == "local"
    end

    test "a thread-lane open records no lane in its opened event" do
      user = owner("granted-event")

      {:ok, thread} = Threads.open(user, "The granted lane is unmarked")

      assert thread.lane == Thread.default_lane()
      assert [%Event{event_type: "thread.opened", payload: payload}] = Threads.list_events(thread)
      refute Map.has_key?(payload, "lane")
    end

    test "a lane outside the admitted pair is refused" do
      user = owner("unknown")

      assert {:error, changeset} = Threads.open(user, "Objective", lane: "gym")
      assert %{lane: _} = errors_on(changeset)
    end

    test "the model string is bounded like every thread's model column" do
      user = owner("bound")

      assert {:error, changeset} =
               Threads.open(user, "Objective",
                 lane: "local",
                 model: String.duplicate("a", 201)
               )

      assert %{model: _} = errors_on(changeset)
    end
  end

  describe "mint_grant/1" do
    test "refuses a local-lane thread with :thread_local_lane" do
      user = owner("mint")
      {:ok, thread} = open_local(user, "Ask for authority the lane forbids")

      assert {:error, :thread_local_lane} = Threads.mint_grant(thread)

      # The refusal leaves no trace of an attempt: no fence bump, no grant.
      refused = Threads.get_for_user(user, thread.id)
      assert refused.generation == 0
      assert Threads.active_grants(refused) == []
    end
  end

  describe "the transcript" do
    test "events record and broadcast exactly as thread-lane events do" do
      user = owner("transcript")
      {:ok, thread} = open_local(user, "Stream the local run")

      :ok = Threads.subscribe(thread)

      assert {:ok, updated} =
               Threads.record_event(thread, "turn.user", %{"text" => "Fix the bug"})

      assert updated.event_count == 2

      assert_receive {:thread_event,
                      %Event{event_type: "turn.user", payload: %{"text" => "Fix the bug"}}}
    end
  end

  describe "admission and the reaper" do
    test "a local-lane thread counts against the open-thread cap" do
      user = owner("cap")
      previous = Application.get_env(:openagents, :maximum_open_threads_per_account)
      Application.put_env(:openagents, :maximum_open_threads_per_account, 1)

      on_exit(fn ->
        Application.put_env(:openagents, :maximum_open_threads_per_account, previous)
      end)

      {:ok, _local} = open_local(user, "Hold the one slot")

      assert {:error, :thread_quota_reached} = Threads.open(user, "One too many")
    end

    test "the reaper leaves an open local-lane thread open" do
      user = owner("reap")
      {:ok, thread} = open_local(user, "Nothing to spend, nothing to reap")

      # The authority-spent sweep closes threads that minted and hold nothing.
      # A local thread never minted, so it is not abandoned authority — it is
      # a transcript still being written.
      _reaped = Threads.reap_expired(user)

      assert Threads.get_for_user(user, thread.id).status == "open"
    end
  end

  test "cancelling ends a local-lane thread like any other" do
    user = owner("cancel")
    {:ok, thread} = open_local(user, "End the record")

    assert {:ok, cancelled} = Threads.cancel(thread)
    assert cancelled.status == "cancelled"

    assert {:error, :thread_terminal} =
             Threads.record_event(cancelled, "turn.user", %{"text" => "late"})
  end
end
