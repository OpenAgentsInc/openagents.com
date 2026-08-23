defmodule OpenAgents.BoxFleetTest do
  use OpenAgents.DataCase, async: false

  import OpenAgents.IssuesFixtures

  alias OpenAgents.Box.{ConversationBox, FanoutItem, FanoutRequest, Fleet, Run}
  alias OpenAgents.BoxRuns
  alias OpenAgents.Conversations
  alias OpenAgents.Forge.Assignment
  alias OpenAgents.Repo

  test "projects admitted, queued, running, and terminal records durably" do
    {:ok, conversation} = Conversations.ensure_conversation("fleet-projection")
    running_box = insert_box(conversation.id, "bx_fleet_running", "running", "box-1")
    terminal_box = insert_box(conversation.id, "bx_fleet_terminal", "archived", "box-2")

    _running_run =
      insert_run(
        conversation.id,
        running_box.id,
        "running",
        "secret https://desktop.ascii.dev/viewer"
      )

    terminal_run = insert_run(conversation.id, terminal_box.id, "completed", "finished")
    {:ok, terminal_run} = BoxRuns.finish(terminal_run.id, "completed", 0)
    repository = repository_fixture()
    issue = issue_fixture(repository)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %Assignment{}
    |> Assignment.changeset(%{
      conversation_box_id: terminal_box.id,
      repository_id: repository.id,
      issue_id: issue.id,
      requesting_principal: %{"type" => "agent", "id" => "agent"},
      branch: "agent/issue-#{issue.number}",
      state: "completed",
      terminal_branch: "agent/issue-#{issue.number}",
      terminal_commit: "abc123",
      admitted_at: now,
      deadline_at: DateTime.add(now, 60, :second),
      finished_at: now
    })
    |> Repo.insert!()

    request =
      %FanoutRequest{}
      |> FanoutRequest.changeset(%{
        conversation_id: conversation.id,
        requesting_principal: %{"type" => "user"},
        requested_count: 1,
        effective_limits: %{"conversation_active_limit" => 10},
        admitted_count: 0,
        queued_count: 1,
        state: "queued"
      })
      |> Repo.insert!()

    queued =
      %FanoutItem{}
      |> FanoutItem.changeset(%{
        request_id: request.id,
        conversation_id: conversation.id,
        position: 0,
        label: "queued-box",
        requesting_principal: %{"type" => "user"},
        state: "queued",
        queue_reason: "conversation_active_limit",
        estimated_burn_rate_microusd: 100_000
      })
      |> Repo.insert!()

    projection = Fleet.projection(conversation.id)

    assert projection.admitted_count == 2
    assert projection.effective_cap == 10
    assert Enum.map(projection.boxes, & &1.label) == ["box-1", "box-2"]
    assert Enum.find(projection.boxes, &(&1.id == running_box.id)).run.state == "running"
    assert Enum.find(projection.boxes, &(&1.id == terminal_box.id)).run.state == "completed"
    assert Enum.find(projection.boxes, &(&1.id == terminal_box.id)).run.output == "finished"

    assert Enum.find(projection.boxes, &(&1.id == terminal_box.id)).assignment.branch ==
             "agent/issue-#{issue.number}"

    assert Enum.find(projection.boxes, &(&1.id == terminal_box.id)).assignment.commit == "abc123"

    assert [%{id: queued_id, kind: :queued, queue_reason: "conversation_active_limit"}] =
             projection.queued

    assert queued_id == queued.id
    refute Enum.any?(projection.boxes, &(&1.kind == :queued))

    refute projection.boxes
           |> Enum.map(& &1.run.output)
           |> Enum.any?(&String.contains?(&1, "desktop.ascii.dev"))

    assert terminal_run.state == "completed"
  end

  test "projection bounds the rendered fleet and queue" do
    {:ok, conversation} = Conversations.ensure_conversation("fleet-bounds")

    for index <- 1..12 do
      insert_box(conversation.id, "bx_fleet_#{index}", "ready")
    end

    request =
      %FanoutRequest{}
      |> FanoutRequest.changeset(%{
        conversation_id: conversation.id,
        requesting_principal: %{"type" => "user"},
        requested_count: 100,
        effective_limits: %{"conversation_active_limit" => 2},
        admitted_count: 0,
        queued_count: 100,
        state: "queued"
      })
      |> Repo.insert!()

    for position <- 0..100 do
      %FanoutItem{}
      |> FanoutItem.changeset(%{
        request_id: request.id,
        conversation_id: conversation.id,
        position: position,
        label: "queued-#{position}",
        requesting_principal: %{"type" => "user"},
        state: "queued",
        queue_reason: "conversation_active_limit",
        estimated_burn_rate_microusd: 100_000
      })
      |> Repo.insert!()
    end

    projection = Fleet.projection(conversation.id)

    assert length(projection.boxes) == 10
    assert length(projection.queued) == 100
    assert projection.queued_truncated?
  end

  test "stop and cancel refuse a user who does not own the conversation" do
    owner = repository_user_fixture("fleet-owner")
    other = repository_user_fixture("fleet-other")
    {:ok, conversation} = Conversations.ensure_conversation(owner)
    box = insert_box(conversation.id, "bx_fleet_private", "ready")
    run = insert_run(conversation.id, box.id, "running", "")

    assert {:error, :conversation_not_found} = Fleet.stop(other, box.label)
    assert {:error, :conversation_not_found} = Fleet.cancel_run(other, box.label, run.id)
  end

  test "controls resolve a user-facing label before calling the Box APIs" do
    user = repository_user_fixture("fleet-label-owner")
    {:ok, conversation} = Conversations.ensure_conversation(user)
    box = insert_box(conversation.id, "bx_fleet_label", "ready", "box-readable")

    assert {:error, :not_found} = Fleet.stop(user, "missing-label")
    assert {:error, :not_found} = Fleet.cancel_run(user, "missing-label", Ecto.UUID.generate())
    assert box.label == "box-readable"
  end

  defp insert_box(conversation_id, box_id, state, label \\ nil) do
    attributes = %{
      conversation_id: conversation_id,
      box_id: box_id,
      state: state,
      setup_status: "done"
    }

    attributes = if label, do: Map.put(attributes, :label, label), else: attributes

    %ConversationBox{}
    |> ConversationBox.changeset(attributes)
    |> Repo.insert!()
  end

  defp insert_run(conversation_id, conversation_box_id, state, output) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %Run{}
    |> Run.changeset(%{
      conversation_id: conversation_id,
      conversation_box_id: conversation_box_id,
      requesting_principal: %{"type" => "user"},
      command: "echo fleet",
      idempotency_key: Ecto.UUID.generate(),
      state: state,
      output: output,
      run_directory: "$HOME/.openagents/box-runs/fleet/#{Ecto.UUID.generate()}",
      admitted_at: now,
      deadline_at: DateTime.add(now, 60, :second),
      finished_at: if(Run.terminal?(%Run{state: state}), do: now, else: nil)
    })
    |> Repo.insert!()
  end
end
