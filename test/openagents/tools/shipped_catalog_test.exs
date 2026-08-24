defmodule OpenAgents.Tools.ShippedCatalogTest do
  @moduledoc """
  The shipped tool catalog is a closed set, read-only but for consent (TOOL-006).

  These assertions read `config/config.exs` directly rather than the ambient
  `:tools` application environment, because the test environment deliberately
  installs a broader fixture catalog. Reading the ambient value would prove
  something about the fixture and nothing about what ships.
  """

  use ExUnit.Case, async: true

  alias OpenAgents.Modules.SurfacePolicy
  alias OpenAgents.Tools.{ConversationExecutionContext, Registry}

  # The zero base recorded in `docs/2026-08-23-agent-tools-zero-base.md`, plus
  # the first tool admitted back. Changing this list is a policy change: read
  # section 6 first.
  @shipped [
    OpenAgents.Tools.ModuleDiscover,
    OpenAgents.Tools.RepoRead,
    OpenAgents.Tools.RepoGrep,
    OpenAgents.Tools.RepoList,
    OpenAgents.Tools.ConnectedRepositoryRead,
    OpenAgents.Tools.ConnectedRepositoryList,
    OpenAgents.Tools.IssueCapture
  ]

  # Tools that ship without being read-only. Every one must be gated on a
  # current consent receipt, which the effect test below proves rather than
  # trusts. This list is the whole of the exception: a tool that writes and is
  # not named here fails.
  @consent_gated [OpenAgents.Tools.IssueCapture]

  # The authorities every conversation caller already holds, and that a shipped
  # tool can rely on. Widening this set widens the catalog.
  @admitted_authorities MapSet.new([
                          "module.discover",
                          "repository.read",
                          "repository.write"
                        ])

  defp shipped_modules do
    "config/config.exs"
    |> Config.Reader.read!(env: :prod)
    |> get_in([:openagents, :tools])
  end

  test "the shipped catalog is exactly the admitted set" do
    assert shipped_modules() == @shipped
  end

  test "every shipped tool is read-only, or is gated on a current consent receipt" do
    {:ok, snapshot} = Registry.build(shipped_modules())
    consent_gated = MapSet.new(@consent_gated)

    for {name, tool} <- snapshot.tools do
      if tool.side_effect == :read_only do
        refute MapSet.member?(consent_gated, tool.implementation),
               "#{name} is read-only and needs no consent gate; drop it from @consent_gated"
      else
        assert MapSet.member?(consent_gated, tool.implementation),
               "#{name} ships with side effect #{inspect(tool.side_effect)} and is not in " <>
                 "@consent_gated. A writing tool is admitted only as a deliberate policy " <>
                 "change; read docs/2026-08-23-agent-tools-zero-base.md section 6 first"
      end
    end
  end

  # The exception is only safe because the gate is real. A tool that writes
  # must be one `SurfacePolicy` refuses without an explicit, current,
  # person-signed receipt — never one whose metadata quietly opts out through
  # the `executor_consent` path that lets a reversible write run unasked.
  # Without this, adding a name to @consent_gated would be enough to ship an
  # ungated write.
  test "a shipped tool that writes actually refuses a caller who has not consented" do
    {:ok, snapshot} = Registry.build(shipped_modules())

    writing =
      for {_name, tool} <- snapshot.tools, tool.side_effect != :read_only, do: tool

    assert length(writing) == length(@consent_gated)

    for tool <- writing do
      {:ok, artifact} = Registry.module_for_tool(snapshot, tool.name, tool.version)

      assert SurfacePolicy.require_target_receipt?(artifact),
             "#{tool.name} writes but claims no affected target"

      assert {:error, :module_approval_required} =
               SurfacePolicy.authorize_execution(artifact, consentless_context()),
             "#{tool.name} writes and ran for a caller holding no approval receipt"
    end
  end

  defp consentless_context do
    %OpenAgents.Tools.ExecutionContext{
      scope: "browser_conversation",
      scope_ref: "conversation:#{Ecto.UUID.generate()}",
      authorities: ConversationExecutionContext.authorities(),
      approval_receipts: [],
      surface: "text",
      conversation_id: Ecto.UUID.generate(),
      owner_user_id: Ecto.UUID.generate(),
      owner_visitor_id: Ecto.UUID.generate()
    }
  end

  test "every shipped tool needs only an authority a conversation caller holds" do
    {:ok, snapshot} = Registry.build(shipped_modules())
    conversation_authorities = ConversationExecutionContext.authorities()

    for {name, tool} <- snapshot.tools do
      assert MapSet.member?(@admitted_authorities, tool.required_authority),
             "#{name} requires #{tool.required_authority}, which the shipped " <>
               "catalog does not admit"

      assert MapSet.member?(conversation_authorities, tool.required_authority),
             "#{name} requires #{tool.required_authority}, which no conversation " <>
               "caller holds, so the model would be offered a tool that refuses"
    end
  end

  test "the shipped catalog builds and stays well under the registry ceiling" do
    assert {:ok, snapshot} = Registry.build(shipped_modules())
    assert map_size(snapshot.tools) == length(@shipped)
    assert length(shipped_modules()) <= 64
  end

  test "nothing ships untested: the fixture catalog covers the shipped one" do
    fixture = MapSet.new(Application.fetch_env!(:openagents, :tools))

    for module <- shipped_modules() do
      assert MapSet.member?(fixture, module),
             "#{inspect(module)} ships but is absent from the test fixture " <>
               "catalog in config/test.exs"
    end
  end
end
