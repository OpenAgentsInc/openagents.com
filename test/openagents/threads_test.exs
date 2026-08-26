defmodule OpenAgents.ThreadsTest do
  use OpenAgents.DataCase, async: false

  import OpenAgentsWeb.ConnCase, only: [github_user: 1]

  alias OpenAgents.Conversations
  alias OpenAgents.Inference
  alias OpenAgents.Inference.Credit
  alias OpenAgents.Inference.Grant
  alias OpenAgents.Inference.Models
  alias OpenAgents.Repo
  alias OpenAgents.Threads
  alias OpenAgents.Threads.Event
  alias OpenAgents.Threads.Thread
  alias OpenAgents.UnpricedLane

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

    test "a payload larger than a projection would allow is recorded whole" do
      user = owner("event-bound")
      {:ok, thread} = Threads.open(user, "Record something large")

      # Past the 16 KB ceiling this table inherited from `scv_run_events`, whose
      # payloads are a minimal projection of work stored elsewhere. This table
      # is the work: a single reasoning block observed in a live session is
      # 38,791 characters, and a transcript that cannot hold it cannot
      # reproduce the session.
      blob = String.duplicate("a", 40_000)

      assert {:ok, _updated} =
               Threads.record_event(thread, "thread.turn.started", %{"blob" => blob})

      stored =
        thread
        |> Threads.list_events()
        |> Enum.find(&(&1.payload["blob"] != nil))

      assert stored.payload["blob"] == blob
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

    test "a report that names an outcome carries it, error code and all" do
      user = owner("finish-failed")
      {:ok, thread} = Threads.open(user, "Run out of steps")

      assert {:ok, failed} =
               Threads.finish(thread, %{
                 status: "failed",
                 report: "The turn budget ran out before an answer.",
                 report_type: "failure",
                 error_code: "max_steps"
               })

      assert failed.status == "failed"
      assert failed.error_code == "max_steps"
    end

    test "a success cannot carry an error code" do
      user = owner("finish-incoherent-success")
      {:ok, thread} = Threads.open(user, "Claim both")

      assert {:error, %Ecto.Changeset{} = changeset} =
               Threads.finish(thread, %{
                 status: "succeeded",
                 report: "It worked.",
                 error_code: "max_steps"
               })

      assert %{error_code: [_ | _]} = errors_on(changeset)
      assert Threads.get_for_user(user, thread.id).status == "open"
    end

    test "a failure has to name why, so nothing ends unexplained" do
      user = owner("finish-incoherent-failure")
      {:ok, thread} = Threads.open(user, "Fail silently")

      assert {:error, %Ecto.Changeset{} = changeset} =
               Threads.finish(thread, %{status: "failed", report: "It did not work."})

      assert %{error_code: [_ | _]} = errors_on(changeset)
      assert Threads.get_for_user(user, thread.id).status == "open"
    end

    test "the coherence rule is the database's too, not only the changeset's" do
      user = owner("finish-coherence-db")
      {:ok, thread} = Threads.open(user, "Write around the changeset")

      assert_raise Postgrex.Error, fn ->
        Repo.update_all(
          from(t in Thread, where: t.id == ^thread.id),
          set: [
            status: "succeeded",
            report: "It worked.",
            report_digest: "sha256:" <> String.duplicate("0", 64),
            report_type: "outcome",
            error_code: "max_steps",
            completed_at: DateTime.utc_now()
          ]
        )
      end
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
    end

    test "a cancelled thread is refused: cancelling is the end that means it" do
      user = owner("cancelled-no-remint")
      {:ok, thread} = Threads.open(user, "Cancel then resume")
      {:ok, thread, _grant, _token} = Threads.mint_grant(thread)
      {:ok, cancelled} = Threads.cancel(thread)

      assert {:error, :thread_terminal} = Threads.mint_grant(cancelled)
      assert Threads.get_for_user(user, thread.id).status == "cancelled"
    end

    test "a thread that reported is re-granted by reopening it, and keeps its report" do
      user = owner("remint-reported")
      {:ok, thread} = Threads.open(user, "Report then resume")
      {:ok, thread, _grant, first_token} = Threads.mint_grant(thread)
      {:ok, finished} = Threads.finish(thread, %{report: "It worked.", report_type: "outcome"})

      assert {:ok, resumed, grant, token} = Threads.mint_grant(finished)

      assert resumed.status == "open"
      assert resumed.report == nil
      assert resumed.report_digest == nil
      assert resumed.report_type == nil
      assert resumed.error_code == nil
      assert resumed.completed_at == nil
      assert resumed.generation == 2

      assert grant.thread_id == thread.id
      assert {:ok, %Grant{status: "active"}} = Inference.resolve(token)
      assert {:error, :grant_revoked} = Inference.resolve(first_token)

      # Nothing is lost by reopening: the report the thread carried moves into
      # the transcript, which is the durable record either way.
      reopened =
        resumed |> Threads.list_events() |> Enum.find(&(&1.event_type == "thread.reopened"))

      assert reopened.payload["status"] == "succeeded"
      assert reopened.payload["report"] == "It worked."
      assert reopened.payload["error_code"] == nil

      # And the transcript accepts the resumed session's turns.
      assert {:ok, _appended} = Threads.record_event(resumed, "turn.user", %{"text" => "again"})
    end

    test "a failed thread resumes too: failing is a state of the work, not a disposal" do
      user = owner("remint-failed")
      {:ok, thread} = Threads.open(user, "Fail then resume")
      {:ok, thread, _grant, _token} = Threads.mint_grant(thread)

      {:ok, failed} =
        Threads.finish(thread, %{
          status: "failed",
          report: "The turn budget ran out.",
          error_code: "max_steps"
        })

      assert {:ok, resumed, _grant, _token} = Threads.mint_grant(failed)
      assert resumed.status == "open"
      assert resumed.error_code == nil
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
    test "a thread's authority has no clock, so waiting does not end it" do
      # The behaviour this replaces: an hour passed, the grant expired, the
      # open thread it fenced was closed as `authority_expired`, and a coding
      # session that was mid-sentence was told to start a new one.
      user = owner("no-clock")
      {:ok, thread} = Threads.open(user, "Still working")
      {:ok, thread, grant, token} = Threads.mint_grant(thread)

      assert is_nil(Repo.get!(Grant, grant.id).expires_at)

      # However long the reaper is run, and whenever.
      assert {0, 0} = Threads.reap_expired(user)
      assert {0, 0} = Threads.reap_expired(user)

      assert Repo.get!(Grant, grant.id).status == "active"
      assert Repo.get!(Thread, thread.id).status == "open"
      assert {:ok, _resolved} = Inference.resolve(token)
    end

    test "a grant that does carry a deadline is still retired when it passes" do
      # Not every grant is a thread's. A computer-bound delegation keeps its
      # clock, where the deadline is a security bound rather than a
      # convenience, and this is the reader that enforces it.
      user = owner("reaped")
      elapsed_ttl()
      {:ok, thread} = Threads.open(user, "Deadline")
      {:ok, _thread, grant, token} = Threads.mint_grant(thread)

      assert {1, 1} = Threads.reap_expired(user)
      assert Repo.get!(Grant, grant.id).status == "expired"
      assert {:error, :grant_expired} = Inference.resolve(token)
    end

    test "a thread left holding no authority is closed as spent, never as expired" do
      # The slot has to come back: nothing is coming to renew a grant, and an
      # open thread that can never work again would hold the ceiling forever.
      # What changed is the reason it is closed for — the budget ran out, which
      # is true, rather than a clock, which no longer exists.
      user = owner("left-open")
      elapsed_ttl()
      {:ok, thread} = Threads.open(user, "Deadline")
      {:ok, thread, _grant, _token} = Threads.mint_grant(thread)

      assert {1, 1} = Threads.reap_expired(user)

      reaped = Repo.get!(Thread, thread.id)
      assert reaped.status == "failed"
      assert reaped.error_code == "authority_spent"
      refute reaped.report =~ "expired"
    end

    test "reaping is idempotent" do
      user = owner("reap-twice")
      elapsed_ttl()
      {:ok, thread} = Threads.open(user, "Deadline")
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

  defp set_config(key, value) do
    previous = Application.get_env(:openagents, key)
    Application.put_env(:openagents, key, value)

    on_exit(fn ->
      Application.put_env(:openagents, key, previous)
    end)
  end

  describe "delegated child threads" do
    test "a child thread names its parent and stays on the same account" do
      user = owner("child-parent")
      {:ok, parent, _grant, _token} = Threads.open_and_mint(user, "Parent")
      {:ok, child} = Threads.open(user, "Child", parent_thread_id: parent.id)

      assert child.parent_thread_id == parent.id
      assert child.owner_visitor_id == parent.owner_visitor_id
    end

    test "a child cannot name another account's parent" do
      mine = owner("child-owner-mine")
      theirs = owner("child-owner-theirs")
      {:ok, parent, _grant, _token} = Threads.open_and_mint(mine, "Parent")

      assert {:error, changeset} =
               Threads.open(theirs, "Child", parent_thread_id: parent.id)

      assert %{parent_thread_id: _} = errors_on(changeset)
    end

    test "a child cannot name a terminal parent" do
      user = owner("child-terminal-parent")
      {:ok, parent, _grant, _token} = Threads.open_and_mint(user, "Parent")
      {:ok, parent} = Threads.finish(parent, %{report: "Done."})

      assert {:error, changeset} =
               Threads.open(user, "Child", parent_thread_id: parent.id)

      assert %{parent_thread_id: _} = errors_on(changeset)
    end

    test "a child is refused when the parent holds no active grant" do
      user = owner("child-no-grant")
      {:ok, parent} = Threads.open(user, "Parent")

      assert {:error, :parent_authority_exhausted} =
               Threads.open_and_mint(user, "Child", parent_thread_id: parent.id)
    end

    test "a child inherits its parent's visibility" do
      user = owner("child-visibility-inherit")
      {:ok, parent} = Threads.open(user, "Parent", visibility: "ledger")
      {:ok, child} = Threads.open(user, "Child", parent_thread_id: parent.id)

      assert child.visibility == "ledger"
    end

    test "a child cannot be opened wider than its parent" do
      user = owner("child-visibility-wide")
      {:ok, parent} = Threads.open(user, "Parent", visibility: "dark")

      assert {:error, changeset} =
               Threads.open(user, "Child",
                 parent_thread_id: parent.id,
                 visibility: "ledger"
               )

      assert %{visibility: _} = errors_on(changeset)
    end

    test "a child counts toward the admission cap" do
      cap(2)
      user = owner("child-cap")
      {:ok, parent} = Threads.open(user, "Parent")
      assert {:ok, _child} = Threads.open(user, "Child", parent_thread_id: parent.id)
      assert {:error, :thread_quota_reached} = Threads.open(user, "Third")
    end

    test "spawning a child appends a thread.spawn event to the parent transcript" do
      user = owner("child-spawn")
      {:ok, parent, _grant, _token} = Threads.open_and_mint(user, "Parent")
      {:ok, child} = Threads.open(user, "Child", parent_thread_id: parent.id)

      parent = Threads.get_for_user(user, parent.id)
      events = Threads.list_events(parent)

      assert [%Event{event_type: "thread.opened"}, %Event{event_type: "thread.spawn"}] = events
      spawn = List.last(events)
      assert spawn.payload["child_thread_id"] == child.id
      assert parent.event_count == 2
    end
  end

  describe "child thread ceilings" do
    test "a child grant is ceiled at the parent's remaining calls" do
      set_config(:thread_grant_max_calls, 5)
      set_config(:thread_grant_max_total_tokens, nil)
      user = owner("child-calls")
      {:ok, parent, grant, _token} = Threads.open_and_mint(user, "Parent")
      {:ok, spent} = Inference.record_usage(grant, %{"output_tokens" => 1})
      {:ok, spent} = Inference.record_usage(spent, %{"output_tokens" => 1})
      assert spent.call_count == 2

      {:ok, _child, child_grant, _token} =
        Threads.open_and_mint(user, "Child", parent_thread_id: parent.id)

      assert child_grant.max_calls == 3
    end

    test "a child grant is ceiled at the parent's remaining tokens" do
      set_config(:thread_grant_max_total_tokens, 100)
      set_config(:thread_grant_max_calls, nil)
      user = owner("child-tokens")
      {:ok, parent, grant, _token} = Threads.open_and_mint(user, "Parent")
      {:ok, spent} = Inference.record_usage(grant, %{"output_tokens" => 30})
      assert spent.usage["total_tokens"] == 30

      {:ok, _child, child_grant, _token} =
        Threads.open_and_mint(user, "Child", parent_thread_id: parent.id)

      assert child_grant.max_total_tokens == 70
    end

    test "a child grant is ceiled at the parent's remaining cost" do
      set_config(:account_credit_microusd, 100_000)
      set_config(:visitor_credit_microusd, 100_000)
      set_config(:thread_grant_max_calls, nil)
      set_config(:thread_grant_max_total_tokens, nil)
      user = owner("child-cost")
      {:ok, parent, grant, _token} = Threads.open_and_mint(user, "Parent")

      # Output tokens priced at the default lane's own output rate, so the
      # arithmetic below follows the catalog rather than restating it.
      rate = Models.default().pricing.output_per_million_tokens
      output = 20_000
      cost = div(output * rate, 1_000_000)

      {:ok, spent} = Inference.record_usage(grant, %{"output_tokens" => output})
      assert spent.usage["estimated_cost_microusd"] == cost

      {:ok, _child, child_grant, _token} =
        Threads.open_and_mint(user, "Child", parent_thread_id: parent.id)

      assert child_grant.max_cost_microusd == 100_000 - cost
    end
  end

  describe "typed thread reports" do
    test "completing a thread records the requested report type" do
      user = owner("typed-report")
      {:ok, thread} = Threads.open(user, "Objective")
      {:ok, finished} = Threads.finish(thread, %{report: "Done.", report_type: "result"})

      assert finished.report_type == "result"
    end

    test "finish defaults the report type when the caller names none" do
      user = owner("typed-report-default")
      {:ok, thread} = Threads.open(user, "Objective")
      {:ok, finished} = Threads.finish(thread, %{report: "Done."})

      assert finished.report_type == "outcome"
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

  describe "what a thread spent" do
    test "sums calls and usage across every grant the thread has held" do
      user = owner("spend-sums")
      {:ok, thread, grant, _token} = Threads.open_and_mint(user, "Spend some")

      {:ok, _} = Inference.record_usage(grant, %{"input_tokens" => 100, "output_tokens" => 10})

      # Resuming re-mints: the second grant is where later spend lands, and a
      # reader asking what the session cost must see both.
      {:ok, resumed, second, _token} = Threads.mint_grant(thread)
      {:ok, _} = Inference.record_usage(second, %{"input_tokens" => 40, "output_tokens" => 5})

      spend = Threads.spend(resumed)
      assert spend.grants == 2
      assert spend.calls == 2
      assert spend.usage["input_tokens"] == 140
      assert spend.usage["output_tokens"] == 15
    end

    test "a dimension no provider reported is absent rather than zero" do
      user = owner("spend-partial")
      {:ok, thread, grant, _token} = Threads.open_and_mint(user, "Partial usage")
      {:ok, _} = Inference.record_usage(grant, %{"input_tokens" => 7})

      spend = Threads.spend(thread)
      assert spend.usage["input_tokens"] == 7
      refute Map.has_key?(spend.usage, "cache_read_input_tokens")
    end

    test "a thread that never spent reports nothing spent" do
      user = owner("spend-none")
      {:ok, thread} = Threads.open(user, "Never spent")

      assert %{calls: 0, grants: 0, usage: %{}, cost: cost} = Threads.spend(thread)

      # Nothing was bought, so there is nothing to price. `absent` is not
      # `unpriced`: one says no calls were made, the other says calls were made
      # and this deployment cannot say what they cost.
      assert cost.basis == "absent"
      assert cost.microusd == nil
      assert cost.unpriced_calls == 0
      assert cost.unpriced_models == []
    end
  end

  # METER-001. Every assertion here is about the same wrong number: a session
  # on a lane with no declared rates reporting `$0.00`, which reads as a
  # measurement rather than as the absence of one.
  describe "what a thread spent, when the deployment has no price for it" do
    test "a thread on an unpriced model reports an unknown cost, never a zero" do
      unpriced = admit_unpriced_lane()
      user = owner("spend-unpriced")
      {:ok, thread} = Threads.open(user, "Run the coder's own lane", model: unpriced)
      {:ok, _fenced, grant, _token} = Threads.mint_grant(thread)

      {:ok, metered} =
        Inference.record_usage(grant, %{"input_tokens" => 40_000, "output_tokens" => 9_000})

      # The grant itself refuses to invent the figure.
      refute Map.has_key?(metered.usage, "estimated_cost_microusd")
      assert metered.usage["pricing_id"] == "unpriced"

      spend = Threads.spend(thread)

      assert spend.calls == 1
      assert spend.usage["input_tokens"] == 40_000
      # The one that matters: not zero.
      refute spend.cost.microusd == 0
      assert spend.cost.microusd == nil
      assert spend.cost.basis == "unpriced"
      assert spend.cost.unpriced_calls == 1
      assert spend.cost.unpriced_models == [unpriced]
    end

    test "a thread on a priced model reports a total, labelled by its basis" do
      user = owner("spend-priced")
      {:ok, thread, grant, _token} = Threads.open_and_mint(user, "Priced lane")
      {:ok, _} = Inference.record_usage(grant, %{"input_tokens" => 1_000_000})

      spend = Threads.spend(thread)

      rate = Models.default().pricing.input_per_million_tokens

      assert spend.cost.microusd == rate
      assert spend.cost.priced_microusd == rate
      assert spend.cost.basis == "provisional"
      assert spend.cost.unpriced_models == []
    end

    test "one unpriced grant makes the whole session's total unknown, and names why" do
      unpriced = admit_unpriced_lane()
      user = owner("spend-mixed")
      {:ok, thread, first, _token} = Threads.open_and_mint(user, "Start priced")
      {:ok, _} = Inference.record_usage(first, %{"input_tokens" => 1_000_000})

      # A thread re-mints on resume, and a grant pins its own model, so a
      # session whose grants ran on different lanes is exactly the case a total
      # has to survive honestly.
      {:ok, _revoked} = Inference.revoke(first)
      {:ok, second, _token} = unpriced_grant_for(thread, unpriced)
      {:ok, _} = Inference.record_usage(second, %{"input_tokens" => 50_000})

      spend = Threads.spend(thread)

      assert spend.cost.microusd == nil
      # Nothing measured is thrown away — the priced half is still reported,
      # just not as the answer to "what did this cost".
      assert spend.cost.priced_microusd == Models.default().pricing.input_per_million_tokens
      assert spend.cost.basis == "unpriced"
      assert spend.cost.unpriced_models == [unpriced]
    end

    test "a grant that was minted and never called does not make the total unknown" do
      unpriced = admit_unpriced_lane()
      user = owner("spend-idle-unpriced")
      {:ok, thread, first, _token} = Threads.open_and_mint(user, "Priced work")
      {:ok, _} = Inference.record_usage(first, %{"input_tokens" => 1_000_000})

      {:ok, _revoked} = Inference.revoke(first)
      {:ok, _idle, _token} = unpriced_grant_for(thread, unpriced)

      spend = Threads.spend(thread)

      assert spend.grants == 2
      assert spend.cost.microusd == Models.default().pricing.input_per_million_tokens
      assert spend.cost.unpriced_calls == 0
    end

    # `gpt-5.6-luna` was the shipped unpriced lane until it was withdrawn. The
    # invariant it demonstrated did not go with it, so the lane is admitted
    # here for the length of one test instead.
    defp admit_unpriced_lane do
      previous = UnpricedLane.admit!()
      on_exit(fn -> UnpricedLane.restore(previous) end)
      UnpricedLane.id()
    end

    # A thread holds at most one active grant, so a second lane is reached the
    # way a resume reaches it: revoke, then mint again against the same fence.
    defp unpriced_grant_for(thread, model_id) do
      Inference.mint(%{
        owner_visitor_id: thread.owner_visitor_id,
        thread_id: thread.id,
        model_id: model_id
      })
    end
  end
end
