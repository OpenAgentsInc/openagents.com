defmodule OpenAgents.Forge.BuildArtifactNamespaceTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Forge.BuildArtifact

  test "every compiled application module is packageable by the build lane" do
    ebin = Application.app_dir(:openagents, "ebin")

    rejected =
      ebin
      |> Path.join("*.beam")
      |> Path.wildcard()
      |> Enum.reject(fn path ->
        match?({:ok, _module}, path |> File.read!() |> BuildArtifact.beam_module())
      end)
      |> Enum.map(&Path.basename(&1, ".beam"))

    assert rejected == [],
           "these modules fall outside the deployable namespaces " <>
             "(OpenAgents, OpenAgentsWeb, Mix.Tasks.Openagents) and would fail " <>
             "forge artifact packaging: #{inspect(rejected)}"
  end
end
