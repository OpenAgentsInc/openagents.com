defmodule OpenAgents.Plugins.Discovery.Doc do
  @moduledoc """
  The searchable document for one plugin manifest.

  The discovery text folds the manifest's name and description together with the
  text declared on its surfaces and capabilities. It is what gets embedded for
  semantic search; it does not synthesize a keyword routing table.
  """

  @spec text(map()) :: String.t()
  def text(%{} = manifest) do
    [manifest["name"], manifest["description"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.concat([capability_text(manifest["capabilities"])])
    |> Enum.concat(surface_texts(manifest["surfaces"]))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  def text(_), do: ""

  defp capability_text(nil), do: nil

  defp capability_text(caps) do
    case List.wrap(caps["hosts"]) do
      [] -> nil
      hosts -> Enum.join(hosts, " ")
    end
  end

  defp surface_texts(nil), do: []

  defp surface_texts(surfaces) when is_list(surfaces),
    do: Enum.flat_map(surfaces, &surface_texts/1)

  defp surface_texts(%{} = surface) do
    [surface["name"], surface["description"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.concat(command_texts(surface["slash_commands"]))
    |> Enum.concat(tool_texts(surface["tools"]))
  end

  defp command_texts(nil), do: []

  defp command_texts(commands) when is_list(commands),
    do: Enum.flat_map(commands, &command_texts/1)

  defp command_texts(%{} = command),
    do: [command["command"], command["description"]] |> Enum.reject(&(&1 in [nil, ""]))

  defp tool_texts(nil), do: []

  defp tool_texts(tools) when is_list(tools), do: Enum.flat_map(tools, &tool_texts/1)

  defp tool_texts(%{} = tool),
    do: [tool["name"], tool["description"]] |> Enum.reject(&(&1 in [nil, ""]))
end
