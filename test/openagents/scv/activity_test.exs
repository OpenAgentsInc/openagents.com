defmodule OpenAgents.SCV.ActivityTest do
  use ExUnit.Case, async: false

  alias OpenAgents.SCV.Activity

  test "projects telemetry events into bounded public activity" do
    activity = start_supervised!({Activity, name: nil, pubsub: nil, telemetry: false})
    run_id = Ecto.UUID.generate()

    Activity.observe(
      %{
        schema: "openagents.scv.event.v1",
        run_id: run_id,
        type: "run_preparing",
        objective: "private objective",
        repository: "/private/repository",
        model: "openai/gpt-5.6-luna"
      },
      activity
    )

    assert [entry] = Activity.public_projection(activity)
    assert entry["status"] == "running"
    assert entry["text"] == "Preparing an admitted SCV run"
    assert entry["id"] =~ ~r/^scv-[0-9a-f]{8}$/
    assert entry["label"] =~ ~r/^SCV [0-9A-F]{8}$/

    rendered = inspect(entry)
    refute rendered =~ run_id
    refute rendered =~ "private objective"
    refute rendered =~ "/private/repository"
    refute rendered =~ "gpt-5.6-luna"

    Activity.observe(
      %{
        schema: "openagents.scv.event.v1",
        run_id: run_id,
        type: "opencode_event",
        event_type: "tool_use",
        tool: "grep",
        tool_status: "completed",
        output: "private tool output"
      },
      activity
    )

    assert [entry] = Activity.public_projection(activity)
    assert entry["tool"] == "grep"
    assert entry["text"] == "Searching repository context"
    refute inspect(entry) =~ "private tool output"

    Activity.observe(
      %{schema: "openagents.scv.event.v1", run_id: run_id, type: "run_finished"},
      activity
    )

    assert Activity.public_projection(activity) == []
  end

  test "observes the executor telemetry event" do
    activity = start_supervised!({Activity, name: nil, pubsub: nil})
    run_id = Ecto.UUID.generate()

    :telemetry.execute(
      [:openagents, :scv, :event],
      %{count: 1},
      %{
        schema: "openagents.scv.event.v1",
        run_id: run_id,
        type: "heartbeat"
      }
    )

    assert [%{"text" => "Working within its resource budget"}] =
             Activity.public_projection(activity)

    :telemetry.execute(
      [:openagents, :scv, :event],
      %{count: 1},
      %{schema: "openagents.scv.event.v1", run_id: run_id, type: "run_finished"}
    )

    assert Activity.public_projection(activity) == []
    assert Activity.public_projection() == []
  end

  test "projects Codex app-server activity without protocol content" do
    activity = start_supervised!({Activity, name: nil, pubsub: nil, telemetry: false})
    run_id = Ecto.UUID.generate()

    Activity.observe(
      %{
        schema: "openagents.scv.event.v1",
        run_id: run_id,
        type: "driver_started",
        model: "gpt-5.6-luna"
      },
      activity
    )

    assert [%{"text" => "Codex runtime started"}] = Activity.public_projection(activity)

    Activity.observe(
      %{
        schema: "openagents.scv.event.v1",
        run_id: run_id,
        type: "tool_started",
        activity_kind: "command",
        command: "private command"
      },
      activity
    )

    assert [entry] = Activity.public_projection(activity)
    assert entry["text"] == "Running a read-only repository command"
    refute inspect(entry) =~ "private command"
    refute inspect(entry) =~ "gpt-5.6-luna"
  end

  test "ignores malformed and unrelated events" do
    activity = start_supervised!({Activity, name: nil, pubsub: nil, telemetry: false})

    Activity.observe(
      %{schema: "other", run_id: Ecto.UUID.generate(), type: "heartbeat"},
      activity
    )

    Activity.observe(%{schema: "openagents.scv.event.v1", type: "heartbeat"}, activity)

    assert Activity.public_projection(activity) == []
  end

  test "returns an empty projection while the activity process is unavailable" do
    assert Activity.public_projection(OpenAgents.SCV.UnavailableActivity) == []
  end

  test "expires an SCV that stops emitting heartbeats" do
    activity =
      start_supervised!(
        {Activity,
         name: nil, pubsub: nil, telemetry: false, expire_after_ms: 0, prune_interval_ms: nil}
      )

    Activity.observe(
      %{
        schema: "openagents.scv.event.v1",
        run_id: Ecto.UUID.generate(),
        type: "heartbeat"
      },
      activity
    )

    assert [_entry] = Activity.public_projection(activity)

    send(activity, :prune)

    assert Activity.public_projection(activity) == []
  end
end
