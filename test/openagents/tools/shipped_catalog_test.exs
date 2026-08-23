defmodule OpenAgents.Tools.ShippedCatalogTest do
  @moduledoc """
  The shipped tool catalog is a closed, read-only set (TOOL-005).

  These assertions read `config/config.exs` directly rather than the ambient
  `:tools` application environment, because the test environment deliberately
  installs a broader fixture catalog. Reading the ambient value would prove
  something about the fixture and nothing about what ships.
  """

  use ExUnit.Case, async: true

  alias OpenAgents.Tools.{ConversationExecutionContext, Registry}

  # The zero base recorded in `docs/2026-08-23-agent-tools-zero-base.md`.
  # Changing this list is a policy change: read section 6 first.
  @shipped [
    OpenAgents.Tools.ModuleDiscover,
    OpenAgents.Tools.RepoRead,
    OpenAgents.Tools.RepoGrep,
    OpenAgents.Tools.RepoList,
    OpenAgents.Tools.ConnectedRepositoryRead,
    OpenAgents.Tools.ConnectedRepositoryList
  ]

  # The authorities every conversation caller already holds, and that a
  # read-only tool can rely on. Widening this set widens the catalog.
  @admitted_authorities MapSet.new(["module.discover", "repository.read"])

  defp shipped_modules do
    "config/config.exs"
    |> Config.Reader.read!(env: :prod)
    |> get_in([:openagents, :tools])
  end

  test "the shipped catalog is exactly the admitted set" do
    assert shipped_modules() == @shipped
  end

  test "every shipped tool is read-only" do
    {:ok, snapshot} = Registry.build(shipped_modules())

    for {name, tool} <- snapshot.tools do
      assert tool.side_effect == :read_only,
             "#{name} ships with side effect #{inspect(tool.side_effect)}; " <>
               "the shipped catalog admits read-only tools only"
    end
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
