defmodule OpenAgents.Notifications.DeliveryTest do
  @moduledoc """
  The outbox half of the email channel: identity, retry, and giving up.

  These tests deliberately configure an adapter that always refuses, so they
  exercise the schedule rather than the send. What arrives at a mailbox, and
  who is allowed to have one, is
  `OpenAgents.Notifications.EmailDeliveryTest`.
  """

  use OpenAgents.DataCase, async: false

  alias OpenAgents.Effects
  alias OpenAgents.Effects.Effect
  alias OpenAgents.Effects.Worker
  alias OpenAgents.Notifications.Delivery

  defmodule FailingAdapter do
    @moduledoc false
    @behaviour OpenAgents.Notifications.Delivery.Adapter

    @impl true
    def deliver(_recipient, _data), do: {:error, :test_failure}
  end

  setup do
    # Restored rather than deleted. Deleting it would take the configured
    # adapter with it and leave every later test in the run talking to the
    # NullAdapter, which is a failure mode that reads like a bug in the code
    # under test.
    configured = Application.get_env(:openagents, OpenAgents.Notifications.Delivery)
    Application.put_env(:openagents, OpenAgents.Notifications.Delivery, adapter: FailingAdapter)

    on_exit(fn ->
      Application.put_env(:openagents, OpenAgents.Notifications.Delivery, configured)
    end)

    :ok
  end

  describe "enqueue/1" do
    test "records one delivery per recipient and dedupe key, however often it is asked" do
      {:ok, first} = enqueue("issue:1:opened", "user-a")
      {:ok, second} = enqueue("issue:1:opened", "user-a")

      assert first.id == second.id
      assert Repo.aggregate(Effect, :count) == 1
      assert first.payload["dedupe_key"] == "issue:1:opened"
    end

    test "a different recipient with the same dedupe key gets a distinct delivery" do
      {:ok, first} = enqueue("issue:1:opened", "user-a")
      {:ok, second} = enqueue("issue:1:opened", "user-b")

      refute first.id == second.id
    end

    test "carries identifiers and no address, so no caller can name a recipient" do
      {:ok, effect} = enqueue("issue:1:opened", "user-a")

      assert Map.keys(effect.payload) |> Enum.sort() ==
               ~w(actor_login dedupe_key issue_id kind user_id)
    end

    test "refuses to queue a delivery that names no account or no event" do
      assert_raise ArgumentError, fn -> Delivery.enqueue(dedupe_key: "x", kind: "mention") end
      assert_raise ArgumentError, fn -> Delivery.enqueue(user_id: "user-a", kind: "mention") end
    end
  end

  describe "handler dispatch" do
    test "a failed attempt increments attempts and reschedules the next try" do
      {user_id, issue_id} = deliverable()
      {:ok, effect} = enqueue("fail-once", user_id, issue_id: issue_id)

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
      {user_id, issue_id} = deliverable()
      {:ok, effect} = enqueue("doomed", user_id, issue_id: issue_id, maximum_attempts: 2)

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

    test "a delivery whose account cannot be resolved completes, and is not retried" do
      {:ok, effect} = enqueue("nobody", "user-a")

      assert %{completed: 1, failed: 0} = Worker.run_once(identity: "worker-a")

      done = Effects.get(effect.id)
      assert done.status == "done"
      assert done.attempts == 1
      assert done.result == %{"outcome" => "recipient_gone"}
      assert done.last_error == nil
      assert done.completed_at != nil
    end
  end

  defp enqueue(dedupe_key, user_id, options \\ []) do
    defaults = [
      dedupe_key: dedupe_key,
      user_id: user_id,
      issue_id: 1,
      kind: "mention",
      actor_login: "someone"
    ]

    Delivery.enqueue(Keyword.merge(defaults, options))
  end

  # An account and an event the adapter will actually be asked about: a
  # confirmed address, the channel on, and an issue in a repository the account
  # can read. Everything `email_dispatch/1` checks has to pass, or the effect
  # is refused before the adapter is reached and there is no schedule to test.
  defp deliverable do
    author = OpenAgents.AccountsFixtures.repository_user_fixture("outbox-author-#{unique()}")
    reader = OpenAgents.AccountsFixtures.repository_user_fixture("outbox-reader-#{unique()}")
    repository = OpenAgents.AccountsFixtures.repository_with_member_fixture(author)
    {:ok, _member} = OpenAgents.Repositories.add_member(repository, reader, "contributor")
    {:ok, issue} = OpenAgents.Issues.create_issue(repository, %{title: "a title"}, author)

    {:ok, pending} =
      OpenAgents.Notifications.EmailChannel.set_address(reader, "outbox-#{unique()}@example.com")

    assert_receive {:email, %Swoosh.Email{subject: subject}}
    code = hd(Regex.run(~r/[0-9A-Z]{8}/, subject))
    {:ok, verified} = OpenAgents.Notifications.EmailChannel.verify(pending, code)

    {:ok, _preferences} =
      OpenAgents.Notifications.update_preferences(verified, %{email_enabled: true})

    {verified.id, issue.id}
  end

  defp unique, do: System.unique_integer([:positive])
end
