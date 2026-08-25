defmodule OpenAgents.Notifications.DeliveryTest do
  @moduledoc """
  Proofs for the durable, decision-independent outbound email seam.

  These tests intentionally do not configure a real provider. They exercise the
  outbox invariants (idempotency, retry, terminal failure, and no-recipient
  handling) through the `email.delivery` effect.
  """

  use OpenAgents.DataCase, async: false

  alias OpenAgents.Effects
  alias OpenAgents.Effects.Effect
  alias OpenAgents.Effects.Worker
  alias OpenAgents.Notifications.Delivery

  defmodule FailingAdapter do
    @behaviour OpenAgents.Notifications.Delivery.Adapter

    @impl true
    def deliver(_recipient, _data), do: {:error, :test_failure}
  end

  setup do
    Application.put_env(:openagents, OpenAgents.Notifications.Delivery, adapter: FailingAdapter)

    on_exit(fn ->
      Application.delete_env(:openagents, OpenAgents.Notifications.Delivery)
    end)

    :ok
  end

  describe "enqueue/1" do
    test "records one delivery per dedupe key, no matter how many times it is enqueued" do
      {:ok, first} = Delivery.enqueue(dedupe_key: "issue:1:opened", user_id: "user-a")
      {:ok, second} = Delivery.enqueue(dedupe_key: "issue:1:opened", user_id: "user-a")

      assert first.id == second.id
      assert Repo.aggregate(Effect, :count) == 1
      assert first.payload["dedupe_key"] == "issue:1:opened"
    end

    test "a different user with the same dedupe key gets a distinct delivery" do
      {:ok, first} = Delivery.enqueue(dedupe_key: "issue:1:opened", user_id: "user-a")
      {:ok, second} = Delivery.enqueue(dedupe_key: "issue:1:opened", user_id: "user-b")

      refute first.id == second.id
    end
  end

  describe "handler dispatch" do
    test "a failed attempt increments attempts and reschedules the next try" do
      {:ok, effect} =
        Delivery.enqueue(
          dedupe_key: "fail-once",
          user_id: "user-a",
          data: %{"to" => "test@example.com"}
        )

      before = DateTime.utc_now()
      assert %{completed: 0, failed: 1} = Worker.run_once(identity: "worker-a")

      failed = Effects.get(effect.id)
      assert failed.status == "pending"
      assert failed.attempts == 1
      assert failed.last_error =~ "test_failure"
      assert DateTime.compare(failed.available_at, before) == :gt

      later = DateTime.add(failed.available_at, 1, :second)
      assert [retried] = Effects.claim_batch("worker-b", now: later)
      assert retried.attempts == 2
    end

    test "attempts stop at a terminal failed state" do
      {:ok, effect} =
        Delivery.enqueue(
          dedupe_key: "doomed",
          user_id: "user-a",
          data: %{"to" => "test@example.com"},
          maximum_attempts: 2
        )

      assert %{completed: 0, failed: 1} = Worker.run_once(identity: "worker-a")
      first = Effects.get(effect.id)
      assert first.status == "pending"
      assert first.attempts == 1

      later = DateTime.add(first.available_at, 1, :second)
      assert [claimed] = Effects.claim_batch("worker-b", now: later)
      assert claimed.attempts == 2
      assert :error = Worker.dispatch(claimed)

      dead = Effects.get(effect.id)
      assert dead.status == "failed"
      assert dead.attempts == 2
      assert dead.completed_at != nil
      assert dead.lease_owner == nil

      far_future = DateTime.add(dead.available_at, 3_600, :second)
      assert Effects.claim_batch("worker-c", now: far_future) == []
    end

    test "a delivery with no recipient records nothing to send to, not a failure" do
      {:ok, effect} =
        Delivery.enqueue(
          dedupe_key: "no-recipient",
          user_id: "user-a",
          data: %{"subject" => "hello"}
        )

      assert %{completed: 1, failed: 0} = Worker.run_once(identity: "worker-a")

      done = Effects.get(effect.id)
      assert done.status == "done"
      assert done.attempts == 1
      assert done.result == %{"outcome" => "nothing_to_send_to"}
      assert done.last_error == nil
      assert done.completed_at != nil
    end
  end
end
