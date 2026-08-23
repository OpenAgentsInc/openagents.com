defmodule OpenAgents.ThreadsTest do
  use OpenAgents.DataCase, async: false

  import OpenAgentsWeb.ConnCase, only: [github_user: 1]

  alias OpenAgents.Conversations
  alias OpenAgents.Inference
  alias OpenAgents.Inference.Grant
  alias OpenAgents.Repo
  alias OpenAgents.Threads
  alias OpenAgents.Threads.Event
  alias OpenAgents.Threads.Thread

  defp owner(key), do: github_user("thread-#{key}")

  describe "open/3" do
    test "a thread is account-scoped and needs no conversation" do
      user = owner("scoped")

      assert {:ok, thread} = Threads.open(user, "Land the thread substrate")

      assert thread.status == "open"
      assert thread.generation == 0
      assert thread.event_count == 1
      assert thread.completed_at == nil
      assert is_binary(thread.owner_visitor_id)

      # The visitor root exists; the account's one conversation does not, and
      # nothing about the thread asked for it (DATA-002 is untouched).
      assert Conversations.get_conversation_for_user(user) == nil

      assert [%Event{event_type: "thread.opened", schema: "openagents.thread.event.v1"}] =
               Threads.list_events(thread)
    end

    test "two threads live side by side for one account" do
      user = owner("plural")

      assert {:ok, first} = Threads.open(user, "First objective")
      assert {:ok, second} = Threads.open(user, "Second objective")

      refute first.id == second.id
      assert length(Threads.list_for_user(user)) == 2
    end

    test "another account's thread is not reachable" do
      mine = owner("mine")
      theirs = owner("theirs")

      {:ok, thread} = Threads.open(mine, "Private objective")

      assert %Thread{} = Threads.get_for_user(mine, thread.id)
      assert Threads.get_for_user(theirs, thread.id) == nil
      assert Threads.get_for_user(mine, "not-a-uuid") == nil
    end

    test "the objective is bounded and the execution shape is admitted vocabulary" do
      user = owner("bounds")

      assert {:error, changeset} = Threads.open(user, "")
      assert %{objective: _} = errors_on(changeset)

      assert {:error, changeset} = Threads.open(user, String.duplicate("a", 32_769))
      assert %{objective: _} = errors_on(changeset)

      assert {:error, changeset} =
               Threads.open(user, "Objective", permission_profile: "danger_full_access")

      assert %{permission_profile: _} = errors_on(changeset)

      assert {:ok, narrowed} = Threads.open(user, "Objective", reasoning: "low")
      assert narrowed.reasoning_effort == "low"
      assert narrowed.permission_profile == "read_only"
    end
  end

  describe "record_event/3" do
    test "appends bounded transcript entries and advances the counter" do
      user = owner("events")
      {:ok, thread} = Threads.open(user, "Record something")

      assert {:ok, thread} = Threads.record_event(thread, "thread.turn.started", %{"turn" => 1})
      assert thread.event_count == 2

      assert ["thread.opened", "thread.turn.started"] =
               thread |> Threads.list_events() |> Enum.map(& &1.event_type)
    end

    test "a payload past the ceiling is refused by the database" do
      user = owner("event-bound")
      {:ok, thread} = Threads.open(user, "Record something large")

      assert {:error, changeset} =
               Threads.record_event(thread, "thread.turn.started", %{
                 "blob" => String.duplicate("a", 16_400)
               })

      assert %{payload: _} = errors_on(changeset)
    end

    test "a terminal thread accepts no further transcript" do
      user = owner("event-terminal")
      {:ok, thread} = Threads.open(user, "Finish then append")
      {:ok, thread} = Threads.finish(thread, %{report: "Done."})

      assert {:error, :thread_terminal} = Threads.record_event(thread, "late", %{"a" => 1})
    end
  end

  describe "finish/2 and cancel/2" do
    test "a terminal thread carries its report and its digest" do
      user = owner("finish")
      {:ok, thread} = Threads.open(user, "Report at the end")

      assert {:ok, finished} = Threads.finish(thread, %{report: "It worked."})
      assert finished.status == "succeeded"
      assert finished.completed_at != nil

      assert finished.report_digest ==
               "sha256:" <> Base.encode16(:crypto.hash(:sha256, "It worked."), case: :lower)

      assert {:error, :thread_terminal} = Threads.finish(finished, %{report: "Again."})
    end

    test "a cancelled thread is terminal with a reason" do
      user = owner("cancel")
      {:ok, thread} = Threads.open(user, "Cancel me")

      assert {:ok, cancelled} = Threads.cancel(thread)
      assert cancelled.status == "cancelled"
      assert cancelled.error_code == "cancelled"
    end
  end

  describe "mint_grant/1 — the thread fence" do
    test "model authority names the thread and no conversation" do
      user = owner("mint")
      {:ok, thread} = Threads.open(user, "Reach a model")

      assert {:ok, fenced, grant, token} = Threads.mint_grant(thread)

      assert grant.thread_id == thread.id
      assert grant.conversation_id == nil
      assert grant.machine_id == nil
      assert grant.status == "active"
      assert String.starts_with?(token, "sig_")
      assert fenced.generation == 1

      assert {:ok, %Grant{status: "active"}} = Inference.resolve(token)
      assert Conversations.get_conversation_for_user(user) == nil
    end

    test "a new mint revokes the last one and bumps the generation" do
      user = owner("fence")
      {:ok, thread} = Threads.open(user, "Fence the authority")

      {:ok, _thread, _first, first_token} = Threads.mint_grant(thread)
      {:ok, thread, _second, second_token} = Threads.mint_grant(thread)

      assert thread.generation == 2
      assert {:error, :grant_revoked} = Inference.resolve(first_token)
      assert {:ok, %Grant{}} = Inference.resolve(second_token)
      assert length(Threads.active_grants(thread)) == 1
    end

    test "authority does not outlive the thread" do
      user = owner("outlive")
      {:ok, thread} = Threads.open(user, "End with authority live")
      {:ok, thread, _grant, token} = Threads.mint_grant(thread)

      {:ok, finished} = Threads.finish(thread, %{report: "Done."})

      assert Threads.active_grants(finished) == []
      assert {:error, :grant_revoked} = Inference.resolve(token)
      assert {:error, :thread_terminal} = Threads.mint_grant(finished)
    end

    test "deleting a thread deletes its authority" do
      user = owner("cascade")
      {:ok, thread} = Threads.open(user, "Delete me")
      {:ok, thread, grant, _token} = Threads.mint_grant(thread)

      Repo.delete!(thread)

      assert Repo.get(Grant, grant.id) == nil
    end
  end
end
