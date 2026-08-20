defmodule OpenAgentsWeb.ToolActivityTest do
  @moduledoc """
  The event-header projection: collapsed titles say what actually ran, every
  derived string is byte-capped, and the expansion helpers stay bounded.
  Owner-directed derivations per tool are pinned here (issue #79).
  """

  use ExUnit.Case, async: true
  alias OpenAgentsWeb.ToolActivity

  defp activity(tool_name, arguments, status \\ "succeeded") do
    raw = if is_nil(arguments), do: nil, else: Jason.encode!(arguments)
    %{tool_name: tool_name, status: status, raw_arguments: raw}
  end

  describe "title/1 derivation per tool" do
    test "computer_run joins the argv as a one-line command string" do
      step =
        activity("computer_run", %{
          "machine_id" => "m1",
          "argv" => ["sed", "-n", "1,60p", "docs/TOOL_RUNTIME.md"]
        })

      assert ToolActivity.title(step) == "sed -n 1,60p docs/TOOL_RUNTIME.md"
    end

    test "computer_agent is agent id plus prompt excerpt" do
      step =
        activity("computer_agent", %{"agent_id" => "claude", "prompt" => "Fix the flaky test"})

      assert ToolActivity.title(step) == "claude: Fix the flaky test"
    end

    test "github_repo_read is read repository/path" do
      step =
        activity("github_repo_read", %{
          "repository" => "OpenAgentsInc/sarah",
          "path" => "DESIGN.md",
          "ref" => "main"
        })

      assert ToolActivity.title(step) == "read OpenAgentsInc/sarah/DESIGN.md"
    end

    test "conversation_search is search with the quoted query" do
      step = activity("conversation_search", %{"query" => "voice budget"})

      assert ToolActivity.title(step) == ~s(search "voice budget")
    end

    test "self-describing tools keep their human subject even with arguments" do
      step = activity("computer_probe", %{"machine_id" => "m1"})

      assert ToolActivity.title(step) == "Finished a check of what's installed on your computer"
    end

    test "other tools fall back to the subject sentence plus a bounded key=value excerpt" do
      step = activity("recall_messages", %{"query" => "the plan"}, "running")

      assert ToolActivity.title(step) ==
               "Working on a look back through this conversation · query=the plan"
    end

    test "a historical step with nil raw_arguments falls back to the current subject" do
      step = activity("computer_run", nil, "succeeded")

      assert ToolActivity.title(step) == "Finished a command on your computer"
    end

    test "undecodable raw_arguments fall back to the current subject" do
      step = %{tool_name: "computer_run", status: "failed", raw_arguments: "{not json"}

      assert ToolActivity.title(step) == "Couldn't finish a command on your computer"
    end

    test "titles are one line and byte-capped with the fuller text on the title attribute" do
      long = String.duplicate("a", 400)
      step = activity("computer_run", %{"argv" => ["echo", "one\ntwo", long]})

      title = ToolActivity.title(step)
      attribute = ToolActivity.title_attribute(step)

      refute title =~ "\n"
      assert byte_size(title) <= 200 + byte_size("…")
      assert String.ends_with?(title, "…")
      assert byte_size(attribute) > byte_size(title)
      assert attribute =~ "one two"
    end

    test "byte caps cut on a UTF-8 boundary" do
      step = activity("computer_run", %{"argv" => ["echo", String.duplicate("é", 300)]})

      title = ToolActivity.title(step)

      assert String.valid?(title)
      assert byte_size(title) <= 200 + byte_size("…")
    end
  end

  describe "status_note/1" do
    test "derived titles carry a text status note for non-success outcomes" do
      step = activity("computer_run", %{"argv" => ["false"]}, "failed")

      assert ToolActivity.status_note(step) == "FAILED"
    end

    test "success stays quiet and subject sentences carry their own status" do
      assert ToolActivity.status_note(activity("computer_run", %{"argv" => ["true"]})) == nil
      assert ToolActivity.status_note(activity("computer_probe", %{}, "failed")) == nil
    end
  end

  describe "expansion helpers" do
    test "arguments render as bounded pretty JSON" do
      step = activity("computer_run", %{"argv" => ["ls"]})

      pretty = ToolActivity.arguments_pretty(step)

      assert pretty =~ "\"argv\""
      assert pretty =~ "\"ls\""
    end

    test "payloads are byte-capped" do
      payload = %{"output" => String.duplicate("x", 10_000)}

      pretty = ToolActivity.payload_pretty(payload)

      assert byte_size(pretty) <= 2_048 + byte_size("…")
      assert String.ends_with?(pretty, "…")
    end

    test "empty payloads render nothing" do
      assert ToolActivity.payload_pretty(nil) == nil
      assert ToolActivity.payload_pretty(%{}) == nil
    end

    test "the executor disclosure appears verbatim only for terminal steps" do
      terminal = %{status: "succeeded", executor_disclosure: "Sarah policy worker"}
      running = %{status: "running", executor_disclosure: "Sarah policy worker"}

      assert ToolActivity.executor_detail(terminal) == "EXECUTOR / Sarah policy worker"
      assert ToolActivity.executor_detail(running) == nil
    end

    test "the timeline lists the lifecycle instants that exist" do
      step = %{
        requested_at: ~U[2026-08-17 12:01:02.000000Z],
        started_at: ~U[2026-08-17 12:01:03.000000Z],
        completed_at: nil
      }

      assert ToolActivity.timeline(step) ==
               "REQUESTED 2026-08-17T12:01:02Z · STARTED 2026-08-17T12:01:03Z"

      assert ToolActivity.timeline(%{}) == nil
    end

    test "timestamp/1 prefers the most recent instant" do
      step = %{
        requested_at: ~U[2026-08-17 12:01:02.000000Z],
        started_at: ~U[2026-08-17 12:01:03.000000Z],
        completed_at: ~U[2026-08-17 12:01:09.000000Z]
      }

      assert ToolActivity.timestamp(step) == ~U[2026-08-17 12:01:09.000000Z]
      assert ToolActivity.timestamp(%{}) == nil
    end
  end

  describe "duration/2" do
    test "formats seconds, minutes, and hours" do
      base = ~U[2026-08-17 12:00:00.000000Z]

      assert ToolActivity.duration(base, ~U[2026-08-17 12:00:42.000000Z]) == "42s"
      assert ToolActivity.duration(base, ~U[2026-08-17 12:03:07.000000Z]) == "3m 7s"
      assert ToolActivity.duration(base, ~U[2026-08-17 13:02:00.000000Z]) == "1h 2m"
      assert ToolActivity.duration(nil, base) == nil
    end
  end
end
