defmodule OpenAgents.Stacks.EventDispatcherTest do
  @moduledoc """
  Outbox delivery (#52): undelivered stack events broadcast in insertion
  order on the repository's topic, delivery marks the row so a drained
  outbox stays quiet, and redelivery reuses the same event ID so consumers
  deduplicate.
  """

  use OpenAgents.DataCase, async: false

  alias OpenAgents.PullRequests.PullRequest
  alias OpenAgents.Repo
  alias OpenAgents.Stacks
  alias OpenAgents.Stacks.EventDispatcher
  alias OpenAgents.Stacks.StackEvent

  import Ecto.Query
  import OpenAgents.AccountsFixtures
  import OpenAgents.IssuesFixtures

  test "delivers pending events in order, marks them, and redelivers with the same ID" do
    actor = repository_user_fixture("dispatch-actor")
    repository = repository_with_member_fixture(actor)
    stack = seed_stack(repository, actor)
    record_events(stack, actor)

    EventDispatcher.subscribe(repository.id)

    assert EventDispatcher.deliver_pending() == 3

    assert_receive {:stack_event, %{event_type: "pull_request_stack.created"} = created}
    assert_receive {:stack_event, %{event_type: "pull_request.stacked"} = stacked_1}
    assert_receive {:stack_event, %{event_type: "pull_request.stacked"} = stacked_2}
    refute_receive {:stack_event, _event}

    for event <- [created, stacked_1, stacked_2] do
      assert event.stack_id == stack.id
      assert event.stack_version == 1
      assert event.actor_user_id == actor.id
      assert is_binary(event.id)
    end

    assert created.payload["stack_number"] == stack.number
    assert created.payload["ordering_old"] == []
    assert created.payload["ordering_new"] == [101, 102]

    # The outbox is drained: nothing is pending and nothing rebroadcasts.
    assert EventDispatcher.deliver_pending() == 0
    refute_receive {:stack_event, _event}

    refute Repo.exists?(from event in StackEvent, where: is_nil(event.delivered_at))

    # A redelivery (crash between broadcast and commit) reuses the event ID,
    # so consumers deduplicate.
    created_id = created.id

    Repo.get!(StackEvent, created_id)
    |> StackEvent.delivered_changeset(nil)
    |> Repo.update!()

    assert EventDispatcher.deliver_pending() == 1
    assert_receive {:stack_event, %{id: ^created_id}}
  end

  test "the worker drains the outbox on demand" do
    actor = repository_user_fixture("dispatch-worker")
    repository = repository_with_member_fixture(actor)
    stack = seed_stack(repository, actor)
    record_events(stack, actor)

    EventDispatcher.subscribe(repository.id)

    dispatcher =
      start_supervised!({EventDispatcher, name: nil, poll_interval_ms: 3_600_000})

    assert {:ok, 3} = EventDispatcher.drain(dispatcher)
    assert_receive {:stack_event, %{event_type: "pull_request_stack.created"}}
    assert {:ok, 0} = EventDispatcher.drain(dispatcher)
  end

  defp seed_stack(repository, actor) do
    pr_1 = pull_request(repository, "layer-1", "main")
    pr_2 = pull_request(repository, "layer-2", "layer-1")

    {:ok, stack} = Stacks.create(repository, [pr_1, pr_2], actor)
    stack
  end

  # Writes the outbox rows a stack creation records, in insertion order.
  defp record_events(stack, actor) do
    created = %{
      "stack_number" => stack.number,
      "trunk_ref" => stack.trunk_ref,
      "ordering_old" => [],
      "ordering_new" => [101, 102]
    }

    stacked_1 = %{"stack_number" => stack.number, "pull_request" => 101, "position" => 1}
    stacked_2 = %{"stack_number" => stack.number, "pull_request" => 102, "position" => 2}

    for {event_type, payload} <- [
          {"pull_request_stack.created", created},
          {"pull_request.stacked", stacked_1},
          {"pull_request.stacked", stacked_2}
        ] do
      %StackEvent{}
      |> StackEvent.changeset(%{
        stack_id: stack.id,
        actor_user_id: actor.id,
        event_type: event_type,
        stack_version: 1,
        payload: payload
      })
      |> Repo.insert!()
    end
  end

  defp pull_request(repository, head_ref, base_ref) do
    issue = issue_fixture(repository, %{title: "PR #{head_ref}"})

    {:ok, pull_request} =
      %PullRequest{}
      |> PullRequest.changeset(%{
        repository_id: repository.id,
        issue_id: issue.id,
        head_repository_id: repository.id,
        head_ref: head_ref,
        head_sha: sha_for(head_ref),
        base_ref: base_ref,
        base_sha: sha_for(base_ref),
        state: "open"
      })
      |> Repo.insert()

    Repo.preload(pull_request, :issue)
  end

  defp sha_for(ref) do
    :sha
    |> :crypto.hash(ref)
    |> Base.encode16(case: :lower)
  end
end
