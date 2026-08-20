defmodule OpenAgents.Modules.DiscoveryTest do
  use ExUnit.Case, async: true
  @moduletag :skip
  alias OpenAgents.Modules.Discovery
  alias OpenAgents.Tools.{ExecutionContext, Registry, Runner}

  test "search is bounded, policy-filtered, and excludes executable detail" do
    snapshot = Registry.current!()

    assert {:ok, result} =
             Discovery.search(snapshot, %{
               "capability" => "conversation.read",
               "data_scope" => "browser_conversation",
               "publisher" => "OpenAgentsInc",
               "compatibility" => 1,
               "first" => 1
             })

    assert result["registry_digest"] == snapshot.digest
    assert length(result["matches"]) == 1
    assert result["truncated"]

    [projection] = result["matches"]
    assert projection["artifact_digest"] =~ ~r/^[0-9a-f]{64}$/
    refute Map.has_key?(projection, "input_schema")
    refute Map.has_key?(projection, "output_schema")
    refute Map.has_key?(projection, "executor")
    refute Map.has_key?(projection, "provenance")
  end

  test "unknown filters and unbounded result requests fail closed" do
    snapshot = Registry.current!()

    assert {:error, :module_discovery_filter_unknown} =
             Discovery.search(snapshot, %{"secret" => "x"})

    assert {:error, :module_discovery_limit_invalid} =
             Discovery.search(snapshot, %{"first" => 21})

    assert {:error, :module_discovery_query_invalid} =
             Discovery.search(snapshot, %{"query" => ""})
  end

  test "discovery references are non-authorizing and stale references are rejected" do
    snapshot = Registry.current!()
    assert {:ok, result} = Discovery.search(snapshot, %{"first" => 1})
    [reference] = result["matches"]
    assert {:ok, artifact} = Discovery.revalidate(snapshot, reference)
    assert artifact.module_id == reference["module_id"]

    stale_registry = Map.put(reference, "registry_digest", String.duplicate("0", 64))
    assert {:error, :stale_module_registry} = Discovery.revalidate(snapshot, stale_registry)

    stale_artifact = Map.put(reference, "artifact_digest", String.duplicate("0", 64))
    assert {:error, :stale_module_artifact} = Discovery.revalidate(snapshot, stale_artifact)
  end

  test "the model-facing tool searches only its turn-captured registry" do
    snapshot = Registry.current!()
    handler_id = "discovery-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        OpenAgents.Observability.event_name(),
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:operation, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    context = %ExecutionContext{
      scope: "browser_conversation",
      scope_ref: "conversation:test",
      authorities: MapSet.new(["module.discover"]),
      module_registry_snapshot: snapshot
    }

    call = %{
      call_id: "call-discover",
      name: "module_discover",
      version: 1,
      raw_arguments: Jason.encode!(%{"publisher" => "OpenAgentsInc", "first" => 2})
    }

    assert {:ok, outcome} = Runner.run(snapshot, call, context)
    assert outcome["status"] == "succeeded"
    assert outcome["result"]["registry_digest"] == snapshot.digest
    assert Enum.all?(outcome["result"]["matches"], &(&1["state"] == "admitted"))
    assert length(outcome["result"]["matches"]) <= 2

    assert_receive {:operation, %{count: 1},
                    %{plane: "tool", operation: "execute", status: "succeeded"}}
  end
end
