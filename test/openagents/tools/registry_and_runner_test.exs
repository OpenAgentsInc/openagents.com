defmodule OpenAgents.Tools.RegistryAndRunnerTest do
  use ExUnit.Case

  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ExecutionContext, ExecutionResult, Registry, Runner, Tool}

  defmodule EchoTool do
    @behaviour OpenAgents.Tools.Tool

    @impl true
    def specification, do: OpenAgents.Tools.RegistryAndRunnerTest.tool_spec(__MODULE__, "echo", 1)

    @impl true
    def execute(%{"text" => text}, _context),
      do: {:ok, %ExecutionResult{result: %{"echo" => text}, target_receipt_refs: ["message:1"]}}
  end

  defmodule EchoToolV2 do
    @behaviour OpenAgents.Tools.Tool

    @impl true
    def specification, do: OpenAgents.Tools.RegistryAndRunnerTest.tool_spec(__MODULE__, "echo", 2)

    @impl true
    def execute(%{"text" => text}, _context),
      do: {:ok, %ExecutionResult{result: %{"echo" => "v2:" <> text}}}
  end

  defmodule SlowTool do
    @behaviour OpenAgents.Tools.Tool

    @impl true
    def specification do
      %{OpenAgents.Tools.RegistryAndRunnerTest.tool_spec(__MODULE__, "slow", 1) | timeout_ms: 5}
    end

    @impl true
    def execute(_arguments, _context) do
      Process.sleep(100)
      {:ok, %ExecutionResult{result: %{"echo" => "late"}}}
    end
  end

  defmodule LargeTool do
    @behaviour OpenAgents.Tools.Tool

    @impl true
    def specification do
      %{
        OpenAgents.Tools.RegistryAndRunnerTest.tool_spec(__MODULE__, "large", 1)
        | maximum_output_bytes: 8
      }
    end

    @impl true
    def execute(_arguments, _context),
      do: {:ok, %ExecutionResult{result: %{"echo" => String.duplicate("x", 100)}}}
  end

  defmodule WriteTool do
    @behaviour OpenAgents.Tools.Tool

    @impl true
    def specification do
      OpenAgents.Tools.RegistryAndRunnerTest.external_spec(__MODULE__, "write")
    end

    @impl true
    def execute(_arguments, _context),
      do:
        {:ok,
         %ExecutionResult{
           result: %{"echo" => "written"},
           target_receipt_refs: ["target:message:1"]
         }}
  end

  defmodule ReceiptlessWriteTool do
    @behaviour OpenAgents.Tools.Tool

    @impl true
    def specification,
      do: OpenAgents.Tools.RegistryAndRunnerTest.external_spec(__MODULE__, "receiptless_write")

    @impl true
    def execute(_arguments, _context),
      do: {:ok, %ExecutionResult{result: %{"echo" => "written"}}}
  end

  test "catalog digests are deterministic and snapshots do not change after reload" do
    assert {:ok, first} = Registry.build([EchoTool, SlowTool])
    assert {:ok, reordered} = Registry.build([SlowTool, EchoTool])
    assert first.digest == reordered.digest

    assert {:ok, replacement} = Registry.build([EchoToolV2])
    refute first.digest == replacement.digest
    assert {:ok, %Tool{version: 1}} = Registry.fetch(first, "echo", 1)
    assert {:ok, %Tool{version: 2}} = Registry.fetch(replacement, "echo", 2)
    assert {:error, :incompatible_tool_version} = Registry.fetch(first, "echo", 2)
  end

  test "success is schema validated and normalized with executor and attribution" do
    snapshot = build!([EchoTool])

    assert {:ok, outcome} =
             Runner.run(snapshot, call("echo", 1, ~s({"text":"quartz"})), context())

    assert outcome["schema"] == "sarah.tool_outcome.v1"
    assert outcome["status"] == "succeeded"
    assert outcome["result"] == %{"echo" => "quartz"}
    assert outcome["module_ref"]["module_id"] == "sarah.tool.echo"
    assert outcome["executor_ref"]["disclosure"] == "Sarah's local test executor"
    assert outcome["target_receipt_refs"] == ["message:1"]
    assert outcome["attribution_refs"] == ["OpenAgentsInc/sarah"]
  end

  test "unknown tools, incompatible versions, and schema failures are bounded" do
    snapshot = build!([EchoTool])

    assert_error(snapshot, call("missing", 1, "{}"), context(), "unavailable", "unknown_tool")

    assert_error(
      snapshot,
      call("echo", 2, "{}"),
      context(),
      "unavailable",
      "incompatible_tool_version"
    )

    assert_error(
      snapshot,
      call("echo", 1, "{}"),
      context(),
      "failed",
      "required_property_missing"
    )

    assert_error(
      snapshot,
      call("echo", 1, ~s({"text":"ok","widen":true})),
      context(),
      "failed",
      "additional_property_not_allowed"
    )
  end

  test "scope and side-effect policy are application refusals" do
    snapshot = build!([EchoTool, WriteTool])
    wrong_scope = %{context() | scope: "global"}
    missing_authority = %{context() | authorities: MapSet.new()}

    assert_error(
      snapshot,
      call("echo", 1, ~s({"text":"x"})),
      wrong_scope,
      "refused",
      "scope_refused"
    )

    assert_error(
      snapshot,
      call("echo", 1, ~s({"text":"x"})),
      missing_authority,
      "refused",
      "authority_refused"
    )

    assert_error(
      snapshot,
      call("write", 1, ~s({"text":"x"})),
      context(),
      "refused",
      "surface_not_admitted"
    )
  end

  test "external effects require an exact approval and return a concrete target receipt" do
    snapshot = build!([WriteTool, ReceiptlessWriteTool])
    computer_context = external_context([])

    assert_error(
      snapshot,
      call("write", 1, ~s({"text":"x"})),
      computer_context,
      "refused",
      "module_approval_required"
    )

    approved_context = external_context([approval_receipt("sarah.tool.write")])

    assert_error(
      snapshot,
      call("write", 1, ~s({"text":"x"})),
      %{approved_context | authorities: MapSet.new()},
      "refused",
      "authority_refused"
    )

    assert {:ok, outcome} =
             Runner.run(snapshot, call("write", 1, ~s({"text":"x"})), approved_context)

    assert outcome["status"] == "succeeded"
    assert outcome["target_receipt_refs"] == ["target:message:1"]
    assert outcome["executor_ref"]["disclosure"] == "Sarah's local test executor"

    receiptless_context = external_context([approval_receipt("sarah.tool.receiptless_write")])

    assert_error(
      snapshot,
      call("receiptless_write", 1, ~s({"text":"x"})),
      receiptless_context,
      "failed",
      "target_receipt_required"
    )
  end

  test "large catalogs expose only bounded discovery definitions to text and realtime" do
    snapshot = Registry.current!()
    template = Map.fetch!(snapshot.tools, "recall_messages")

    expanded_tools =
      Enum.reduce(1..20, snapshot.tools, fn index, tools ->
        name = "synthetic_capability_#{index}"

        Map.put(tools, name, %{
          template
          | name: name,
            description: "Synthetic capability #{index}"
        })
      end)

    expanded = %{snapshot | tools: expanded_tools}
    prompt_catalog = Registry.prompt_catalog(expanded, "")
    realtime_catalog = Registry.realtime_catalog(expanded, "")

    names = Enum.map(prompt_catalog.definitions, & &1.name)

    # There is no direct/discovery flip any more: the system always selects a
    # bounded, relevance-ranked subset, and it never omits the discovery escape
    # hatch. A large catalog leaves many tools omitted.
    assert prompt_catalog.mode == "selected"
    assert "module_discover" in names
    assert length(names) <= 13
    assert prompt_catalog.omitted_count > 0
    assert "module_discover" in Enum.map(realtime_catalog["tools"], & &1["name"])
    assert realtime_catalog["mode"] == "selected"
    encoded_definitions = Enum.map(prompt_catalog.definitions, &Map.from_struct/1)
    assert byte_size(Jason.encode!(encoded_definitions)) < 24_000
  end

  test "timeout, cancellation, and oversized output are typed outcomes" do
    snapshot = build!([SlowTool, LargeTool, EchoTool])

    assert_error(snapshot, call("slow", 1, ~s({"text":"x"})), context(), "failed", "timeout")

    cancellation_counter = :atomics.new(1, [])

    assert_error(
      snapshot,
      call("echo", 1, ~s({"text":"x"})),
      context(),
      "cancelled",
      "cancelled",
      cancel?: fn -> :atomics.add_get(cancellation_counter, 1, 1) > 1 end
    )

    assert_error(
      snapshot,
      call("large", 1, ~s({"text":"x"})),
      context(),
      "failed",
      "output_too_large"
    )
  end

  test "turn startup captures the installed immutable catalog digest" do
    installed = Registry.current!()
    assert Map.has_key?(installed.tools, "recall_messages")
    assert installed.digest =~ ~r/^[0-9a-f]{64}$/
  end

  def tool_spec(module, name, version) do
    %Tool{
      module_id: "sarah.tool." <> name,
      name: name,
      version: version,
      description: "Echoes bounded test input",
      input_schema: %{
        "type" => "object",
        "properties" => %{"text" => %{"type" => "string", "maxLength" => 100}},
        "required" => ["text"],
        "additionalProperties" => false
      },
      output_schema: %{
        "type" => "object",
        "properties" => %{"echo" => %{"type" => "string", "maxLength" => 200}},
        "required" => ["echo"],
        "additionalProperties" => false
      },
      side_effect: :read_only,
      required_scope: "browser_conversation",
      required_authority: "conversation.read",
      executor: %{id: "sarah.local", disclosure: "Sarah's local test executor"},
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/sarah"],
      policy_facets: %{"privacy" => "browser_scoped", "residency" => "host"},
      module_metadata:
        Metadata.first_party("conversation.read", "browser_conversation",
          effect: :read_only,
          privacy: "browser_scoped",
          residency: "host"
        ),
      timeout_ms: 100,
      maximum_input_bytes: 1_024,
      maximum_output_bytes: 1_024,
      implementation: module
    }
  end

  def external_spec(module, name) do
    %{
      tool_spec(module, name, 1)
      | side_effect: :external_effect,
        required_scope: "browser_computer",
        required_authority: "computer.control",
        module_metadata:
          Metadata.first_party("computer.control", "browser_computer",
            effect: :external_effect,
            privacy: "browser_scoped",
            residency: "host",
            surfaces: ["computer"],
            approval_class: "external_confirmation",
            approval_enforcement: "host_receipt"
          )
    }
  end

  defp build!(modules) do
    assert {:ok, snapshot} = Registry.build(modules)
    snapshot
  end

  defp call(name, version, raw_arguments),
    do: %{call_id: "call-1", name: name, version: version, raw_arguments: raw_arguments}

  defp context do
    %ExecutionContext{
      scope: "browser_conversation",
      scope_ref: "conversation:1",
      authorities: MapSet.new(["conversation.read"])
    }
  end

  defp external_context(approval_receipts) do
    %ExecutionContext{
      surface: "computer",
      scope: "browser_computer",
      scope_ref: "computer-session:1",
      authorities: MapSet.new(["computer.control"]),
      approval_receipts: approval_receipts
    }
  end

  defp approval_receipt(module_id) do
    %{
      "schema" => "sarah.module_approval.v1",
      "approval_class" => "external_confirmation",
      "module_id" => module_id,
      "version" => 1,
      "scope_ref" => "computer-session:1",
      "explicit" => true,
      "actor_type" => "person",
      "receipt_ref" => "approval:1"
    }
  end

  defp assert_error(snapshot, call, context, status, code, options \\ []) do
    assert {:ok, outcome} = Runner.run(snapshot, call, context, options)
    assert outcome["status"] == status
    assert outcome["error"]["code"] == code
    assert byte_size(outcome["error"]["message"]) <= 256
  end
end
