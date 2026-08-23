defmodule OpenAgents.Tools.AdmittedCatalogTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Tools.{
    AdmittedCatalog,
    ConnectedRepositoryList,
    ConnectedRepositoryRead,
    ExecutionContext,
    Registry,
    RepoWrite
  }

  test "does not advertise tools outside the captured authority and surface" do
    assert {:ok, snapshot} = Registry.build([ConnectedRepositoryRead, RepoWrite])

    context =
      execution_context("text", ["repository.read"], [
        approval_receipt("sarah.tool.repo_write.v1")
      ])

    names =
      snapshot
      |> AdmittedCatalog.provider_definitions(context, "read and write repository files",
        top_k: 10,
        always_include: ["read_repository_file", "repo_write"]
      )
      |> Enum.map(& &1.name)

    assert "read_repository_file" in names
    refute "repo_write" in names

    voice_names =
      snapshot
      |> AdmittedCatalog.realtime_catalog(
        execution_context("voice", ["repository.read", "repository.write"], [
          approval_receipt("sarah.tool.repo_write.v1")
        ]),
        "read and write repository files",
        top_k: 10,
        always_include: ["read_repository_file", "repo_write"]
      )
      |> Map.fetch!("tools")
      |> Enum.map(& &1["name"])

    assert "read_repository_file" in voice_names
    refute "repo_write" in voice_names
  end

  test "equivalent text and voice contexts advertise the same authorized tool names" do
    assert {:ok, snapshot} =
             Registry.build([ConnectedRepositoryRead, ConnectedRepositoryList])

    opts = [
      top_k: 10,
      always_include: ["read_repository_file", "list_repository_directory"]
    ]

    text_names =
      snapshot
      |> AdmittedCatalog.provider_definitions(
        execution_context("text", ["repository.read"]),
        "inspect connected repository files",
        opts
      )
      |> Enum.map(& &1.name)
      |> Enum.sort()

    voice_names =
      snapshot
      |> AdmittedCatalog.realtime_catalog(
        execution_context("voice", ["repository.read"]),
        "inspect connected repository files",
        opts
      )
      |> Map.fetch!("tools")
      |> Enum.map(& &1["name"])
      |> Enum.sort()

    assert text_names == ["list_repository_directory", "read_repository_file"]
    assert voice_names == text_names
  end

  defp execution_context(surface, authorities, approval_receipts \\ []) do
    %ExecutionContext{
      scope: "browser_conversation",
      scope_ref: "conversation:test",
      surface: surface,
      authorities: MapSet.new(authorities),
      approval_receipts: approval_receipts
    }
  end

  defp approval_receipt(module_id) do
    %{
      "schema" => "sarah.module_approval.v1",
      "approval_class" => "exact_current_user_consent",
      "module_id" => module_id,
      "version" => 1,
      "scope_ref" => "conversation:test",
      "explicit" => true,
      "actor_type" => "person",
      "receipt_ref" => "approval:test"
    }
  end
end
