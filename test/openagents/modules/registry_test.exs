defmodule OpenAgents.Modules.RegistryTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Modules.{Artifact, Metadata, Registry}
  alias OpenAgents.Tools.Tool
  alias OpenAgents.Tools.Registry, as: ToolRegistry

  defmodule AdmittedTool do
    @behaviour OpenAgents.Tools.Tool
    def specification,
      do: OpenAgents.Modules.RegistryTest.tool_spec(__MODULE__, "module_test", 1)

    def execute(_arguments, _context), do: {:error, :not_executed}
  end

  defmodule ReplacementTool do
    @behaviour OpenAgents.Tools.Tool

    def specification do
      predecessor = AdmittedTool.specification()
      {:ok, predecessor_artifact} = Artifact.from_tool(predecessor)

      metadata =
        OpenAgents.Modules.RegistryTest.tool_spec(__MODULE__, "module_test", 2).module_metadata
        |> Map.put("predecessor", %{
          "module_id" => predecessor_artifact.module_id,
          "version" => predecessor_artifact.version,
          "artifact_digest" => predecessor_artifact.artifact_digest
        })

      %{
        OpenAgents.Modules.RegistryTest.tool_spec(__MODULE__, "module_test", 2)
        | module_metadata: metadata
      }
    end

    def execute(_arguments, _context), do: {:error, :not_executed}
  end

  defmodule DisabledTool do
    @behaviour OpenAgents.Tools.Tool

    def specification do
      tool = OpenAgents.Modules.RegistryTest.tool_spec(__MODULE__, "disabled_test", 1)
      %{tool | module_metadata: Map.put(tool.module_metadata, "state", "disabled")}
    end

    def execute(_arguments, _context), do: {:error, :must_not_execute}
  end

  defmodule DeprecatedTool do
    @behaviour OpenAgents.Tools.Tool

    def specification do
      tool = OpenAgents.Modules.RegistryTest.tool_spec(__MODULE__, "deprecated_test", 1)

      metadata =
        tool.module_metadata
        |> Map.put("state", "deprecated")
        |> Map.put("deprecation", %{
          "reason" => "Replaced by a reviewed successor.",
          "replacement" => nil
        })

      %{tool | module_metadata: metadata}
    end

    def execute(_arguments, _context), do: {:error, :not_executed}
  end

  defmodule RevokedTool do
    @behaviour OpenAgents.Tools.Tool

    def specification do
      tool = OpenAgents.Modules.RegistryTest.tool_spec(__MODULE__, "revoked_test", 1)
      %{tool | module_metadata: Map.put(tool.module_metadata, "state", "revoked")}
    end

    def execute(_arguments, _context), do: {:error, :must_not_execute}
  end

  defmodule IncompleteTool do
    @behaviour OpenAgents.Tools.Tool

    def specification do
      tool = OpenAgents.Modules.RegistryTest.tool_spec(__MODULE__, "incomplete_test", 1)
      %{tool | module_metadata: Map.delete(tool.module_metadata, "attribution_policy")}
    end

    def execute(_arguments, _context), do: {:error, :must_not_execute}
  end

  defmodule MissingDependencyTool do
    @behaviour OpenAgents.Tools.Tool

    def specification do
      tool = OpenAgents.Modules.RegistryTest.tool_spec(__MODULE__, "dependency_test", 1)

      compatibility =
        Map.put(tool.module_metadata["compatibility"], "dependencies", [
          %{"module_id" => "sarah.tool.missing", "version" => 1}
        ])

      metadata = Map.put(tool.module_metadata, "compatibility", compatibility)
      %{tool | module_metadata: metadata}
    end

    def execute(_arguments, _context), do: {:error, :must_not_execute}
  end

  test "artifact pins schemas, policy, attribution, and loaded executor identity" do
    assert {:ok, snapshot} = ToolRegistry.build([AdmittedTool])
    assert [artifact] = Registry.discover(snapshot)
    assert artifact.schema == "sarah.module_artifact.v1"
    assert artifact.state == "admitted"
    assert artifact.approval_class == "host_policy"
    assert artifact.capability_scopes == ["conversation.read"]
    assert artifact.data_scopes == ["browser_conversation"]
    assert artifact.attribution_policy["required"]
    assert artifact.provenance["integrity"]["digest"] == artifact.implementation_digest
    assert artifact.artifact_digest =~ ~r/^[0-9a-f]{64}$/
    assert :ok = Artifact.validate(artifact)
    assert :ok = Artifact.verify_implementation(artifact, AdmittedTool)
  end

  test "disabled modules stay in provenance but cannot be discovered or executed" do
    assert {:ok, snapshot} = ToolRegistry.build([AdmittedTool, DisabledTool, RevokedTool])
    assert Map.has_key?(snapshot.modules, {"sarah.tool.disabled_test", 1})
    assert Map.has_key?(snapshot.modules, {"sarah.tool.revoked_test", 1})
    refute Map.has_key?(snapshot.tools, "disabled_test")
    refute Map.has_key?(snapshot.tools, "revoked_test")
    assert Enum.map(Registry.discover(snapshot), & &1.module_id) == ["sarah.tool.module_test"]
    assert {:error, :module_ineligible} = Registry.fetch(snapshot, "sarah.tool.disabled_test", 1)
    assert {:error, :unknown_tool} = ToolRegistry.fetch(snapshot, "disabled_test", 1)
    assert {:error, :module_ineligible} = Registry.fetch(snapshot, "sarah.tool.revoked_test", 1)
  end

  test "deprecated modules remain explicit and executable during their bounded transition" do
    assert {:ok, snapshot} = ToolRegistry.build([DeprecatedTool])
    assert {:ok, artifact} = Registry.fetch(snapshot, "sarah.tool.deprecated_test", 1)
    assert artifact.state == "deprecated"
    assert artifact.deprecation["reason"] != ""
    assert {:ok, _tool} = ToolRegistry.fetch(snapshot, "deprecated_test", 1)
  end

  test "policy-incomplete metadata and unresolved dependencies fail closed" do
    assert {:error,
            {:invalid_module_artifact, "sarah.tool.incomplete_test", :module_metadata_incomplete}} =
             ToolRegistry.build([IncompleteTool])

    assert {:error,
            {:module_dependency_missing, "sarah.tool.dependency_test", "sarah.tool.missing", 1}} =
             ToolRegistry.build([MissingDependencyTool])
  end

  test "a later registry preserves predecessor provenance without mutating an older snapshot" do
    assert {:ok, first} = ToolRegistry.build([AdmittedTool])
    assert {:ok, replacement} = ToolRegistry.build([ReplacementTool])

    assert {:ok, old_tool} = ToolRegistry.fetch(first, "module_test", 1)
    assert old_tool.version == 1
    assert {:error, :incompatible_tool_version} = ToolRegistry.fetch(first, "module_test", 2)

    assert {:ok, new_artifact} = Registry.fetch(replacement, "sarah.tool.module_test", 2)
    old_artifact = Map.fetch!(first.modules, {"sarah.tool.module_test", 1})
    assert new_artifact.predecessor["artifact_digest"] == old_artifact.artifact_digest
    assert new_artifact.rollback["strategy"] == "disable_or_restore_predecessor"
    refute replacement.digest == first.digest
  end

  test "tampered artifact or executor identity is rejected" do
    assert {:ok, snapshot} = ToolRegistry.build([AdmittedTool])
    artifact = Map.fetch!(snapshot.modules, {"sarah.tool.module_test", 1})

    bad_artifact_digest = %{artifact | artifact_digest: String.duplicate("0", 64)}
    assert {:error, :module_artifact_digest_invalid} = Artifact.validate(bad_artifact_digest)

    tampered = %{artifact | implementation_digest: String.duplicate("0", 64)}
    tampered = %{tampered | artifact_digest: Artifact.artifact_digest(tampered)}
    assert {:error, :module_executor_invalid} = Artifact.validate(tampered)

    assert {:error, :module_integrity_mismatch} =
             Artifact.verify_implementation(tampered, AdmittedTool)
  end

  def tool_spec(module, name, version) do
    %Tool{
      module_id: "sarah.tool." <> name,
      name: name,
      version: version,
      description: "Bounded module registry test",
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
      executor: %{id: "sarah.local", disclosure: "Sarah local module test"},
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/openagents.com"],
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
end
