defmodule OpenAgents.Tools.Discovery.Doc do
  @moduledoc """
  The searchable document for one tool: the text that gets embedded / lexically
  scored, and the effective tag set used for tag filtering.

  Effective tags fold the tool's authored `tags` together with its required
  authority and the tokens of its name, so a tag search for `delegation`,
  `computer`, or `incident` lands on the right tool without every tool having to
  hand-author an exhaustive list.
  """

  alias OpenAgents.Tools.Tool

  @doc "The text used for embedding and lexical scoring: name, description, tags."
  @spec text(Tool.t()) :: String.t()
  def text(%Tool{} = tool) do
    [tool.name, tool.description, Enum.join(effective_tags(tool), " ")]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  @doc "Downcased effective tag set for filtering."
  @spec tags(Tool.t()) :: MapSet.t(String.t())
  def tags(%Tool{} = tool), do: tool |> effective_tags() |> MapSet.new()

  @doc "Lowercased content tokens of the document, for lexical overlap scoring."
  @spec tokens(Tool.t()) :: MapSet.t(String.t())
  def tokens(%Tool{} = tool), do: tool |> text() |> tokenize()

  @doc "Tokenize free text the same way both sides of a lexical match are tokenized."
  @spec tokenize(String.t()) :: MapSet.t(String.t())
  def tokenize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 2))
    |> MapSet.new()
  end

  def tokenize(_text), do: MapSet.new()

  defp effective_tags(%Tool{} = tool) do
    authored = List.wrap(tool.tags)

    authority_tokens =
      tool.required_authority |> to_string() |> String.split(~r/[._]/, trim: true)

    name_tokens = tool.name |> to_string() |> String.split(~r/[._]/, trim: true)

    (authored ++ authority_tokens ++ name_tokens)
    |> Enum.map(&String.downcase(to_string(&1)))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end
end
