defmodule OpenAgents.SCV.OpenCodeEventsTest do
  use ExUnit.Case, async: true

  alias OpenAgents.SCV.OpenCodeEvents

  test "aggregates bounded usage and tool outcomes without retaining text" do
    events =
      OpenCodeEvents.new()
      |> OpenCodeEvents.ingest(
        Jason.encode!(%{
          "type" => "tool_use",
          "sessionID" => "ses_test",
          "part" => %{
            "tool" => "read",
            "state" => %{"status" => "completed", "output" => "private source"}
          }
        })
      )
      |> OpenCodeEvents.ingest(
        Jason.encode!(%{
          "type" => "step_finish",
          "sessionID" => "ses_test",
          "part" => %{
            "cost" => 0.0125,
            "tokens" => %{
              "input" => 11,
              "output" => 7,
              "reasoning" => 3,
              "cache" => %{"read" => 5, "write" => 2}
            }
          }
        })
      )
      |> OpenCodeEvents.ingest(
        Jason.encode!(%{
          "type" => "text",
          "sessionID" => "ses_test",
          "part" => %{"text" => "private response"}
        })
      )
      |> OpenCodeEvents.ingest(
        "timestamp=2026-08-20T13:00:00.000Z level=INFO message=bootstrapping"
      )
      |> OpenCodeEvents.ingest("not-json")
      |> OpenCodeEvents.summary()

    assert events.event_count == 3
    assert events.diagnostic_line_count == 1
    assert events.invalid_event_count == 1
    assert events.event_types == %{"step_finish" => 1, "text" => 1, "tool_use" => 1}
    assert events.session_ids == ["ses_test"]
    assert events.text_event_count == 1
    assert events.tool_calls == %{"read" => 1}
    assert events.tool_outcomes == %{"read:completed" => 1}

    assert events.usage == %{
             input_tokens: 11,
             output_tokens: 7,
             reasoning_tokens: 3,
             cache_read_tokens: 5,
             cache_write_tokens: 2,
             cost_usd: 0.0125
           }

    refute inspect(events) =~ "private source"
    refute inspect(events) =~ "private response"
  end

  test "bounds event-controlled identifiers" do
    oversized = String.duplicate("x", 256)

    events =
      OpenCodeEvents.new()
      |> OpenCodeEvents.ingest(
        Jason.encode!(%{
          "type" => oversized,
          "sessionID" => oversized,
          "part" => %{"tool" => oversized, "state" => %{"status" => oversized}}
        })
      )
      |> OpenCodeEvents.summary()

    assert events.event_types == %{"unknown" => 1}
    assert events.session_ids == []
    assert events.tool_calls == %{}
  end
end
