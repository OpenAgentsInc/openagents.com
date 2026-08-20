defmodule OpenAgents.SCV.OpenCodeReportTest do
  use ExUnit.Case, async: true

  alias OpenAgents.SCV.OpenCodeReport

  test "collects only prose text events" do
    report =
      OpenCodeReport.new()
      |> OpenCodeReport.ingest(
        Jason.encode!(%{"type" => "tool_use", "part" => %{"output" => "private source"}})
      )
      |> OpenCodeReport.ingest(
        Jason.encode!(%{"type" => "text", "part" => %{"text" => "First finding"}})
      )
      |> OpenCodeReport.ingest("not-json")
      |> OpenCodeReport.ingest(
        Jason.encode!(%{"type" => "text", "part" => %{"text" => "Second finding"}})
      )
      |> OpenCodeReport.summary()

    assert report == %{
             schema: "openagents.scv.report.v1",
             text: "First finding\nSecond finding",
             bytes: 28,
             truncated: false
           }

    refute inspect(report) =~ "private source"
  end

  test "bounds a report without producing invalid UTF-8" do
    oversized = String.duplicate("🚀", 9_000)

    report =
      OpenCodeReport.new()
      |> OpenCodeReport.ingest(
        Jason.encode!(%{"type" => "text", "part" => %{"text" => oversized}})
      )
      |> OpenCodeReport.summary()

    assert report.bytes <= 32_768
    assert byte_size(report.text) == report.bytes
    assert String.valid?(report.text)
    assert report.truncated
  end

  test "splits a report into ordered UTF-8-safe chunks" do
    text = String.duplicate("audit 🚀 ", 1_000)
    report = %{text: text}

    chunks = OpenCodeReport.chunks(report, 1_025)

    assert length(chunks) > 1
    assert Enum.all?(chunks, &(byte_size(&1) <= 1_025))
    assert Enum.all?(chunks, &String.valid?/1)
    assert Enum.join(chunks) == text
  end
end
