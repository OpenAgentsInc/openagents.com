defmodule OpenAgents.ObservabilityTest do
  use OpenAgents.DataCase, async: false
  alias OpenAgents.Observability
  alias OpenAgents.Observability.{Readback, ReleaseGate}

  test "events expose only finite identifiers and reject private or unbounded metadata" do
    handler_id = "observability-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        Observability.event_name(),
        fn event, measurements, metadata, _config ->
          send(test_pid, {:event, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok =
             Observability.emit(%{duration_ms: 12}, %{
               plane: "provider",
               operation: "respond",
               status: "succeeded",
               surface: "text",
               provider_id: "openai"
             })

    assert_receive {:event, [:openagents, :operation], %{count: 1, duration_ms: 12}, metadata}
    refute Map.has_key?(metadata, :content)

    assert {:error, :telemetry_metadata_key_refused} =
             Observability.emit(%{}, %{
               plane: "memory",
               operation: "recall",
               status: "recalled",
               message_content: "private words"
             })

    assert {:error, :telemetry_identifier_invalid} =
             Observability.emit(%{}, %{
               plane: "tool",
               operation: "execute",
               status: "failed",
               module_id: String.duplicate("x", 129)
             })
  end

  test "read-back is aggregate-only and the zero-tolerance gate is explicit" do
    readback = Readback.snapshot()

    assert readback.schema == "openagents.observability.readback.v1"

    assert Map.keys(readback.planes) |> Enum.sort() ==
             ~w(collective evaluation memory module provider tool)

    assert Enum.all?(readback.planes, fn {_plane, statuses} ->
             Enum.all?(statuses, fn {status, count} ->
               is_binary(status) and is_integer(count) and count >= 0
             end)
           end)

    refute inspect(readback) =~ "message_content"
    refute inspect(readback) =~ "prompt"
    assert ReleaseGate.evaluate(readback).status == "passed"

    blocked = put_in(readback, [:integrity, "missing_collective_consent"], 1)
    report = ReleaseGate.evaluate(blocked)
    assert report.status == "blocked"
    assert report.blockers == [%{check: "missing_collective_consent", count: 1, threshold: 0}]

    assert ReleaseGate.thresholds().blocking["cross_scope_private_leakage"] == 0
    assert ReleaseGate.thresholds().blocking["failed_attribution_reconciliation"] == 0
  end
end
