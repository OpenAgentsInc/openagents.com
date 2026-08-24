defmodule OpenAgents.ThreadsTest do
  use OpenAgents.DataCase, async: false

  import OpenAgentsWeb.ConnCase, only: [github_user: 1]

  alias OpenAgents.Conversations
  alias OpenAgents.Inference
  alias OpenAgents.Inference.Credit
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

  describe "the admission cap" do
    test "an account cannot hold more open threads than the configured maximum" do
      cap(2)
      user = owner("capped")

      assert {:ok, _first} = Threads.open(user, "First")
      assert {:ok, second} = Threads.open(user, "Second")
      assert {:error, :thread_quota_reached} = Threads.open(user, "Third")

      # The cap counts what is open, so ending one admits the next.
      {:ok, _finished} = Threads.finish(second, %{report: "Done."})
      assert {:ok, _third} = Threads.open(user, "Third")
    end

    test "the cap counts one account's threads, never another's" do
      cap(1)

      assert {:ok, _mine} = Threads.open(owner("cap-mine"), "Mine")
      assert {:ok, _yours} = Threads.open(owner("cap-yours"), "Yours")
    end

    test "a refused open writes nothing" do
      cap(1)
      user = owner("cap-clean")

      {:ok, _first} = Threads.open(user, "First")
      assert {:error, :thread_quota_reached} = Threads.open(user, "Second")
      assert Threads.open_count(user) == 1
      assert length(Threads.list_for_user(user)) == 1
    end
  end

  describe "reap_expired/1" do
    test "elapsed authority is expired and the thread it fenced is closed" do
      user = owner("reaped")
      {:ok, live} = Threads.open(user, "Still working")
      {:ok, live, _live_grant, _live_token} = Threads.mint_grant(live)

      elapsed_ttl()
      {:ok, lapsed} = Threads.open(user, "Abandoned")
      {:ok, lapsed, lapsed_grant, lapsed_token} = Threads.mint_grant(lapsed)

      assert {1, 1} = Threads.reap_expired(user)

      assert Repo.get!(Grant, lapsed_grant.id).status == "expired"
      assert {:error, :grant_expired} = Inference.resolve(lapsed_token)

      reaped = Repo.get!(Thread, lapsed.id)
      assert reaped.status == "failed"
      assert reaped.error_code == "authority_expired"
      assert reaped.report_digest =~ ~r/\Asha256:[0-9a-f]{64}\z/

      # A thread whose clock has not run out is untouched.
      assert Repo.get!(Thread, live.id).status == "open"
    end

    test "a thread that has never minted authority is not reaped" do
      user = owner("never-minted")
      {:ok, thread} = Threads.open(user, "No authority yet")

      assert {0, 0} = Threads.reap_expired(user)
      assert Repo.get!(Thread, thread.id).status == "open"
    end

    test "reaping is idempotent" do
      user = owner("reap-twice")
      elapsed_ttl()
      {:ok, thread} = Threads.open(user, "Abandoned")
      {:ok, _thread, _grant, _token} = Threads.mint_grant(thread)

      assert {1, 1} = Threads.reap_expired(user)
      assert {0, 0} = Threads.reap_expired(user)
    end
  end

  describe "ceilings/0" do
    test "a thread's grant carries the thread ceilings, not the delegation ceilings" do
      user = owner("ceilings")
      {:ok, thread} = Threads.open(user, "Measure me")
      {:ok, _thread, grant, _token} = Threads.mint_grant(thread)

      ceilings = Threads.ceilings()

      assert grant.max_total_tokens == ceilings.max_total_tokens
      assert grant.max_calls == ceilings.max_calls

      # Money is the account's, not the thread's: the cost ceiling is what the
      # account has left of its credit, so a second thread cannot mint itself a
      # fresh allowance (`OpenAgents.Inference.Credit`).
      assert grant.max_cost_microusd == Credit.remaining(grant.owner_visitor_id)

      delegation = Inference.delegation_ceilings()

      refute {grant.max_total_tokens, grant.max_calls, grant.max_cost_microusd} ==
               {delegation.max_total_tokens, delegation.max_calls, delegation.max_cost_microusd}
    end

    test "a delegation grant is unchanged by the thread ceilings" do
      user = owner("delegation-untouched")
      {:ok, conversation} = Conversations.ensure_conversation(user)

      {:ok, grant, _token} =
        Inference.mint(%{
          owner_visitor_id: conversation.visitor_id,
          conversation_id: conversation.id
        })

      delegation = Inference.delegation_ceilings()

      assert grant.max_total_tokens == delegation.max_total_tokens
      assert grant.max_calls == delegation.max_calls
      assert grant.max_cost_microusd == delegation.max_cost_microusd
    end
  end

  defp cap(limit) do
    previous = Application.get_env(:openagents, :maximum_open_threads_per_account)
    Application.put_env(:openagents, :maximum_open_threads_per_account, limit)

    on_exit(fn ->
      Application.put_env(:openagents, :maximum_open_threads_per_account, previous)
    end)
  end

  # A grant's expiry is immutable once minted, so the TTL is set before the
  # mint rather than the row edited after it.
  defp elapsed_ttl do
    previous = Application.get_env(:openagents, :thread_grant_ttl_seconds)
    Application.put_env(:openagents, :thread_grant_ttl_seconds, -1)
    on_exit(fn -> Application.put_env(:openagents, :thread_grant_ttl_seconds, previous) end)
  end
end
