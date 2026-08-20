defmodule OpenAgents.Modules.LifecycleTest do
  use OpenAgents.SarahDataCase, async: true

  alias OpenAgents.Modules.{Discovery, Lifecycle, LifecycleReceipt, Metadata}
  alias OpenAgents.Tools.{Registry, Tool}

  defmodule DependencyBaseTool do
    @behaviour OpenAgents.Tools.Tool
    def specification,
      do: OpenAgents.Modules.LifecycleTest.tool_spec(__MODULE__, "dependency_base")

    def execute(_arguments, _context),
      do: {:ok, %OpenAgents.Tools.ExecutionResult{result: %{"ok" => true}}}
  end

  defmodule DependentTool do
    @behaviour OpenAgents.Tools.Tool

    def specification do
      tool = OpenAgents.Modules.LifecycleTest.tool_spec(__MODULE__, "dependent")

      compatibility =
        Map.put(tool.module_metadata["compatibility"], "dependencies", [
          %{"module_id" => "sarah.tool.dependency_base", "version" => 1}
        ])

      %{tool | module_metadata: Map.put(tool.module_metadata, "compatibility", compatibility)}
    end

    def execute(_arguments, _context),
      do: {:ok, %OpenAgents.Tools.ExecutionResult{result: %{"ok" => true}}}
  end

  test "only an authenticated operator can stage, admit, deprecate, and revoke" do
    base = Registry.current!()
    {module_id, version} = first_ref(base)

    assert {:error, :authenticated_operator_required} =
             Lifecycle.transition(base, module_id, version, "stage", %{}, %{"reason" => "test"})

    assert Repo.aggregate(LifecycleReceipt, :count) == 0

    assert {:ok, staged_receipt, staged} =
             Lifecycle.transition(
               base,
               module_id,
               version,
               "stage",
               operator("stage"),
               %{"reason" => "Stage for bounded operator review."}
             )

    assert staged_receipt.to_state == "staged"

    assert {:error, :module_ineligible} =
             OpenAgents.Modules.Registry.fetch(staged, module_id, version)

    assert {:ok, admitted_receipt, admitted} =
             Lifecycle.transition(
               base,
               module_id,
               version,
               "admit",
               operator("admit"),
               %{"reason" => "All first-party admission checks passed."}
             )

    assert admitted_receipt.generation == 2

    assert {:ok, admitted_artifact} =
             OpenAgents.Modules.Registry.fetch(admitted, module_id, version)

    assert admitted_artifact.state == "admitted"

    assert {:ok, deprecated_receipt, deprecated} =
             Lifecycle.transition(
               base,
               module_id,
               version,
               "deprecate",
               operator("deprecate"),
               %{"reason" => "A successor is ready.", "replacement" => nil}
             )

    assert deprecated_receipt.to_state == "deprecated"
    assert {:ok, default_discovery} = Discovery.search(deprecated, %{})
    refute Enum.any?(default_discovery["matches"], &(&1["module_id"] == module_id))
    assert {:ok, historical} = Discovery.search(deprecated, %{"include_deprecated" => true})
    assert Enum.any?(historical["matches"], &(&1["module_id"] == module_id))

    predecessor = Map.fetch!(deprecated.modules, {module_id, version}).predecessor

    assert {:ok, rollback_receipt, rolled_back} =
             Lifecycle.transition(
               base,
               module_id,
               version,
               "rollback",
               operator("rollback"),
               %{
                 "reason" => "Restore the predecessor after regression.",
                 "predecessor" => predecessor
               }
             )

    assert rollback_receipt.action == "rollback"

    assert {:ok, rolled_back_artifact} =
             OpenAgents.Modules.Registry.fetch(rolled_back, module_id, version)

    assert rolled_back_artifact.state == "admitted"

    assert {:ok, revoked_receipt, revoked} =
             Lifecycle.transition(
               base,
               module_id,
               version,
               "revoke",
               operator("revoke"),
               %{"reason" => "Integrity incident requires permanent retirement."}
             )

    assert revoked_receipt.to_state == "revoked"

    assert {:error, :module_ineligible} =
             OpenAgents.Modules.Registry.fetch(revoked, module_id, version)

    assert {:ok, captured} = Lifecycle.capture(base)
    assert captured.digest == revoked.digest
  end

  test "disable and revoke report active dependent impact before mutation" do
    assert {:ok, base} = Registry.build([DependencyBaseTool, DependentTool])

    assert {:error, {:active_module_dependents, [dependent_ref]}} =
             Lifecycle.transition(
               base,
               "sarah.tool.dependency_base",
               1,
               "disable",
               operator("impact"),
               %{"reason" => "Exercise dependency impact checks."}
             )

    assert dependent_ref =~ "sarah.tool.dependent"
    assert Repo.aggregate(LifecycleReceipt, :count) == 0
  end

  test "approval references are unique and receipts are bounded" do
    base = Registry.current!()
    {module_id, version} = first_ref(base)
    operator = operator("unique")

    assert {:ok, receipt, _snapshot} =
             Lifecycle.transition(base, module_id, version, "stage", operator, %{
               "reason" => "Stage once."
             })

    assert receipt.approval_receipt_ref == operator.approval_receipt_ref
    assert receipt.base_registry_digest == base.digest
    assert receipt.resulting_registry_digest =~ ~r/^[0-9a-f]{64}$/

    assert {:error, %Ecto.Changeset{}} =
             Lifecycle.transition(base, module_id, version, "admit", operator, %{
               "reason" => "Cannot reuse an approval receipt."
             })
  end

  def tool_spec(module, name) do
    %Tool{
      module_id: "sarah.tool." <> name,
      name: name,
      version: 1,
      description: "Bounded lifecycle dependency test",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      output_schema: %{
        "type" => "object",
        "properties" => %{"ok" => %{"type" => "boolean"}},
        "required" => ["ok"],
        "additionalProperties" => false
      },
      side_effect: :read_only,
      required_scope: "browser_conversation",
      required_authority: "conversation.read",
      executor: %{id: "sarah.test", disclosure: "Sarah lifecycle test"},
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/sarah"],
      policy_facets: %{"privacy" => "test", "residency" => "test"},
      module_metadata:
        Metadata.first_party("conversation.read", "browser_conversation",
          effect: :read_only,
          privacy: "test",
          residency: "test"
        ),
      timeout_ms: 100,
      maximum_input_bytes: 100,
      maximum_output_bytes: 100,
      implementation: module
    }
  end

  defp first_ref(snapshot) do
    artifact = snapshot.modules |> Map.values() |> Enum.sort_by(& &1.module_id) |> hd()
    {artifact.module_id, artifact.version}
  end

  defp operator(suffix) do
    %{
      authenticated: true,
      role: "operator",
      actor_id: "operator:test",
      auth_method: "test_session",
      approval_receipt_ref: "operator-approval:#{suffix}:#{System.unique_integer([:positive])}"
    }
  end
end
