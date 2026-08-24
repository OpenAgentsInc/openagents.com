defmodule OpenAgents.EffectsTest do
  @moduledoc """
  What the durable effect outbox promises (EFFECT-001, EFFECT-002, issue #202).

  The claim under test is not "effects usually run". It is that an effect
  exists exactly when the intent that asked for it committed, that one worker
  runs it at a time, that a worker that dies holding it loses nothing, and that
  a redelivery is safe. Each of those is a separate failure the outbox exists
  to remove, so each gets its own test.
  """

  use OpenAgents.DataCase, async: false

  alias OpenAgents.Effects
  alias OpenAgents.Effects.Effect
  alias OpenAgents.Effects.Worker

  setup do
    Application.put_env(:openagents, :effects,
      handlers: %{"test.echo" => OpenAgents.EffectsEchoHandler},
      backoff_base_ms: 1_000,
      backoff_ceiling_ms: 300_000,
      lease_seconds: 120
    )

    Application.put_env(:openagents, :effects_test_observer, self())

    on_exit(fn ->
      Application.delete_env(:openagents, :effects)
      Application.delete_env(:openagents, :effects_test_observer)
    end)

    :ok
  end

  describe "enqueue/2 inside the caller's transaction" do
    test "a committed transaction leaves exactly one effect" do
      {:ok, effect} =
        Repo.transaction(fn ->
          {:ok, effect} = enqueue("commit-me")
          effect
        end)

      assert %Effect{status: "pending", attempts: 0} = Effects.get(effect.id)
      assert Effects.counts() == %{"pending" => 1}
    end

    test "a rolled-back transaction leaves no effect at all" do
      key = Effects.idempotency_key("test.echo", "test_source", "rollback-me")

      assert {:error, :intent_refused} =
               Repo.transaction(fn ->
                 {:ok, _effect} = enqueue("rollback-me")
                 Repo.rollback(:intent_refused)
               end)

      # This is the whole point of enqueuing inside the caller's transaction:
      # an intent that did not happen owes nothing, and nothing is delivered.
      assert Effects.get_by_key(key) == nil
      assert Effects.counts() == %{}
    end

    test "the same intent enqueued twice is one effect and one delivery" do
      {:ok, first} = enqueue("twice")
      {:ok, second} = enqueue("twice")

      assert first.id == second.id
      assert Repo.aggregate(Effect, :count) == 1
    end

    test "a reused key carrying different content is refused, not silently answered" do
      {:ok, first} = enqueue("fingerprinted", %{"body" => "original"})

      assert {:error, :payload_conflict} =
               Effects.enqueue("test.echo", %{
                 payload: %{"body" => "substituted"},
                 source_kind: "test_source",
                 source_id: "fingerprinted"
               })

      # The first caller's effect stands; the second caller is told no rather
      # than handed a result for a payload it never sent.
      assert Effects.get(first.id).payload == %{"body" => "original"}
      assert Repo.aggregate(Effect, :count) == 1
    end

    test "the deterministic key does not depend on the payload" do
      key = Effects.idempotency_key("test.echo", "test_source", "stable", 7)

      assert key == Effects.idempotency_key("test.echo", "test_source", "stable", 7)
      refute key == Effects.idempotency_key("test.echo", "test_source", "stable")
      refute key == Effects.idempotency_key("test.other", "test_source", "stable", 7)
    end

    test "a source sequence is recorded as evidence, never as a status" do
      {:ok, effect} =
        Effects.enqueue("test.echo", %{
          payload: %{"body" => "sequenced"},
          source_kind: "thread_event",
          source_id: "thread-1",
          source_sequence: 42
        })

      # EFFECT-002: a transcript position is not an execution claim and not a
      # completion claim. The sequence is stored; the status is separate.
      assert effect.source_sequence == 42
      assert effect.status == "pending"
      assert effect.claimed_at == nil
      assert effect.completed_at == nil
    end
  end

  describe "claim_batch/2" do
    test "a claim takes a lease and counts an attempt" do
      {:ok, effect} = enqueue("claim-me")

      assert [claimed] = Effects.claim_batch("worker-a")
      assert claimed.id == effect.id
      assert claimed.status == "claimed"
      assert claimed.attempts == 1
      assert claimed.lease_owner == "worker-a"
      assert DateTime.compare(claimed.lease_expires_at, DateTime.utc_now()) == :gt

      # Claiming is not completing (EFFECT-002).
      assert claimed.claimed_at != nil
      assert claimed.completed_at == nil
    end

    test "an effect a worker holds is not offered to the next worker" do
      {:ok, _effect} = enqueue("held")

      assert [_claimed] = Effects.claim_batch("worker-a")
      assert Effects.claim_batch("worker-b") == []
    end

    test "an effect whose time has not come is not claimable" do
      later = DateTime.add(DateTime.utc_now(), 60, :second)

      {:ok, _effect} =
        Effects.enqueue("test.echo", enqueue_attributes("later", available_at: later))

      assert Effects.claim_batch("worker-a") == []
      assert [_claimed] = Effects.claim_batch("worker-a", now: DateTime.add(later, 1, :second))
    end

    test "concurrent workers over one batch claim disjoint sets and never the same effect twice" do
      for index <- 1..12, do: {:ok, _effect} = enqueue("racer-#{index}")

      claims =
        ["worker-a", "worker-b", "worker-c"]
        |> Task.async_stream(
          fn worker -> Effects.claim_batch(worker, limit: 12) end,
          max_concurrency: 3,
          ordered: false,
          timeout: :infinity
        )
        |> Enum.flat_map(fn {:ok, claimed} -> claimed end)

      ids = Enum.map(claims, & &1.id)

      # Every effect went to exactly one worker: no effect is missing, and no
      # effect was handed to two workers to run twice.
      assert length(ids) == 12
      assert length(Enum.uniq(ids)) == 12
      assert Enum.all?(claims, &(&1.attempts == 1))
      assert Effects.counts() == %{"claimed" => 12}
    end

    test "a claim only offers kinds this release can run" do
      {:ok, _known} = enqueue("known")

      {:ok, _unknown} =
        Effects.enqueue("test.absent", enqueue_attributes("unknown"))

      assert [claimed] = Effects.claim_batch("worker-a", kinds: ["test.echo"])
      assert claimed.kind == "test.echo"
    end
  end

  describe "reclaim_expired/1" do
    test "a dead worker's lease returns the effect to the queue" do
      {:ok, _effect} = enqueue("abandoned")
      assert [claimed] = Effects.claim_batch("worker-a", lease_seconds: 1)

      after_expiry = DateTime.add(claimed.lease_expires_at, 1, :second)

      assert Effects.reclaim_expired(now: after_expiry) == 1

      reclaimed = Effects.get(claimed.id)
      assert reclaimed.status == "pending"
      assert reclaimed.lease_owner == nil
      assert reclaimed.lease_expires_at == nil

      # The attempt the dead worker spent is not refunded, so a handler that
      # reliably kills its worker still reaches maximum_attempts and stops.
      assert reclaimed.attempts == 1

      assert [reclaimed_again] = Effects.claim_batch("worker-b", now: after_expiry)
      assert reclaimed_again.lease_owner == "worker-b"
      assert reclaimed_again.attempts == 2
    end

    test "a live lease is left alone" do
      {:ok, _effect} = enqueue("live")
      assert [claimed] = Effects.claim_batch("worker-a", lease_seconds: 600)

      assert Effects.reclaim_expired() == 0
      assert Effects.get(claimed.id).lease_owner == "worker-a"
    end
  end

  describe "fail/2" do
    test "a failure backs off, releases the lease, and is retried" do
      {:ok, _effect} = enqueue("flaky")
      assert [claimed] = Effects.claim_batch("worker-a")

      before = DateTime.utc_now()
      assert {:ok, failed} = Effects.fail(claimed, {:provider_unavailable, 503})

      assert failed.status == "pending"
      assert failed.lease_owner == nil
      assert failed.last_error =~ "provider_unavailable"
      assert failed.attempts == 1

      # Backoff is a delay, not a refusal: the effect is deliverable again once
      # its time comes, and not before.
      assert DateTime.diff(failed.available_at, before, :millisecond) >= Effects.backoff_ms(1)
      assert Effects.claim_batch("worker-b") == []

      later = DateTime.add(failed.available_at, 1, :second)
      assert [retried] = Effects.claim_batch("worker-b", now: later)
      assert retried.attempts == 2
    end

    test "backoff grows and is capped" do
      assert Effects.backoff_ms(1) == 1_000
      assert Effects.backoff_ms(2) == 2_000
      assert Effects.backoff_ms(3) == 4_000
      assert Effects.backoff_ms(40) == 300_000
    end

    test "an effect that exhausts its attempts stops being delivered" do
      {:ok, _effect} =
        Effects.enqueue("test.echo", enqueue_attributes("doomed", maximum_attempts: 2))

      assert [first] = Effects.claim_batch("worker-a")
      assert {:ok, retryable} = Effects.fail(first, :first_failure)
      assert retryable.status == "pending"

      later = DateTime.add(retryable.available_at, 1, :second)
      assert [second] = Effects.claim_batch("worker-a", now: later)
      assert second.attempts == 2

      assert {:ok, dead} = Effects.fail(second, :second_failure)

      # An effect that cannot be run must stop pretending it will be, so that
      # something else can notice it.
      assert dead.status == "failed"
      assert dead.completed_at != nil
      assert dead.lease_owner == nil
      assert Effects.claim_batch("worker-a", now: DateTime.add(later, 3_600, :second)) == []
    end
  end

  describe "complete/1" do
    test "completion is idempotent under redelivery" do
      {:ok, _effect} = enqueue("redelivered")
      assert [claimed] = Effects.claim_batch("worker-a")

      assert {:ok, done} = Effects.complete(claimed)
      assert done.status == "done"
      assert done.completed_at != nil
      assert done.lease_owner == nil

      # The second worker — the one whose lease expired mid-flight and whose
      # effect someone else already finished — reports success without
      # contradicting the record or writing a second completion.
      assert {:ok, again} = Effects.complete(claimed)
      assert again.id == done.id
      assert again.status == "done"
      assert again.completed_at == done.completed_at
    end

    test "completing a failed effect after the fact does not resurrect a failure" do
      {:ok, _effect} = enqueue("late")
      assert [claimed] = Effects.claim_batch("worker-a")
      assert {:ok, _done} = Effects.complete(claimed)

      # A stale worker reporting failure for an effect already completed does
      # not turn a completed effect back into pending work.
      assert {:ok, unchanged} = Effects.fail(claimed, :too_late)
      assert unchanged.status == "done"
    end
  end

  describe "the worker" do
    test "one pass claims, dispatches, and completes" do
      {:ok, effect} = enqueue("dispatch-me", %{"body" => "hello"})

      assert %{claimed: 1, completed: 1, failed: 0} = Worker.run_once(identity: "worker-a")

      assert_received {:effect_ran, "hello", key, id}
      assert key == effect.idempotency_key
      assert id == effect.id
      assert Effects.get(effect.id).status == "done"
    end

    test "a handler that raises is a retry, not a crash" do
      {:ok, effect} = enqueue("boom", %{"raise" => "handler exploded"})

      assert %{claimed: 1, completed: 0, failed: 1} = Worker.run_once(identity: "worker-a")

      failed = Effects.get(effect.id)
      assert failed.status == "pending"
      assert failed.last_error =~ "handler exploded"
      assert failed.attempts == 1
    end

    test "a pass reclaims expired leases before it claims" do
      {:ok, effect} = enqueue("stranded", %{"body" => "recovered"})
      assert [claimed] = Effects.claim_batch("dead-worker", lease_seconds: -1)
      assert claimed.status == "claimed"

      assert %{reclaimed: 1, claimed: 1, completed: 1} = Worker.run_once(identity: "worker-b")

      assert_received {:effect_ran, "recovered", _key, _id}
      assert Effects.get(effect.id).status == "done"
    end

    test "an effect whose kind has no handler fails loudly rather than vanishing" do
      {:ok, effect} = Effects.enqueue("test.absent", enqueue_attributes("orphan"))

      # The claim only offers admitted kinds, so an unregistered kind is never
      # picked up and quietly marked done.
      assert %{claimed: 0} = Worker.run_once(identity: "worker-a")
      assert Effects.get(effect.id).status == "pending"

      # Dispatched directly — as a recovery path would — it is a refusal.
      assert [claimed] = Effects.claim_batch("worker-a")
      assert :error = Worker.dispatch(claimed)
      assert Effects.get(effect.id).last_error =~ "unknown_kind"
    end

    test "a running worker drives a pass on demand, with no sleeping" do
      {:ok, effect} = enqueue("ticked", %{"body" => "tick"})

      worker =
        start_supervised!({Worker, name: :effects_test_worker, poll: false, identity: "worker-t"})

      assert %{claimed: 1, completed: 1} = Worker.tick(worker)
      assert_received {:effect_ran, "tick", _key, _id}
      assert Effects.get(effect.id).status == "done"
    end
  end

  describe "for_source/2" do
    test "an intent can be asked what it is owed" do
      {:ok, first} = enqueue("audited-1")
      {:ok, second} = enqueue("audited-2")

      assert Effects.for_source("test_source", "audited-1") |> Enum.map(& &1.id) == [first.id]
      assert Effects.for_source("test_source", "audited-2") |> Enum.map(& &1.id) == [second.id]
      assert Effects.for_source("test_source", "never-asked") == []
    end
  end

  defp enqueue(source_id, payload \\ %{"body" => "noop"}) do
    Effects.enqueue("test.echo", enqueue_attributes(source_id, payload: payload))
  end

  defp enqueue_attributes(source_id, extra \\ []) do
    [payload: %{"body" => "noop"}, source_kind: "test_source", source_id: source_id]
    |> Keyword.merge(extra)
    |> Map.new()
  end
end
