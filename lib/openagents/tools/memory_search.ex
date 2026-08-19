defmodule OpenAgents.Tools.MemorySearch do
  @moduledoc "Searches a bounded frozen view of active profile memories for this browser."

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Tools.{ExecutionResult, MemoryContract, MemoryList}

  @impl true
  def specification do
    list = MemoryList.specification()
    properties = Map.put(list.input_schema["properties"], "query", MemoryContract.string(200))

    input_schema = %{
      list.input_schema
      | "properties" => properties,
        "required" => ["category", "first", "query"]
    }

    MemoryContract.tool(
      __MODULE__,
      "memory_search",
      "Filters active profile memories from the frozen snapshot for this browser by " <>
        "literal substring match against stored claims. Use a short keyword, not a " <>
        "question; to see everything stored, use memory_list instead",
      input_schema,
      list.output_schema,
      :read_only,
      "memory.read"
    )
  end

  @impl true
  def execute(%{"query" => query} = arguments, context) do
    normalized_query = query |> String.normalize(:nfkc) |> String.trim() |> String.downcase()

    if byte_size(normalized_query) in 1..200 do
      with {:ok, %ExecutionResult{} = listed} <-
             MemoryList.execute(Map.delete(arguments, "query"), context) do
        matches =
          Enum.filter(listed.result["memories"], fn memory ->
            String.contains?(String.downcase(memory["claim"]), normalized_query)
          end)

        result =
          listed.result
          |> Map.put("schema", "sarah.memory_search_result.v1")
          |> Map.put("status", if(matches == [], do: "empty", else: "matches"))
          |> Map.put("memories", matches)

        {:ok,
         %ExecutionResult{
           result: result,
           target_receipt_refs: Enum.map(matches, & &1["record_ref"])
         }}
      end
    else
      {:error, :invalid_memory_query}
    end
  end
end
