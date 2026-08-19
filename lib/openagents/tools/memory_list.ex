defmodule OpenAgents.Tools.MemoryList do
  @moduledoc "Lists a bounded frozen view of active profile memories for this browser."

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.{ProfileMemory, Tools.MemoryContract}
  alias OpenAgents.Tools.{ExecutionResult, MemoryContext}

  @impl true
  def specification do
    MemoryContract.tool(
      __MODULE__,
      "memory_list",
      "Lists active profile memories from the frozen snapshot for this browser. " <>
        "Use this to review what is stored, such as answering what you know about " <>
        "the user; pass an empty category for all categories",
      input_schema(),
      output_schema(),
      :read_only,
      "memory.read"
    )
  end

  @impl true
  def execute(%{"category" => category, "first" => first}, context) do
    with :ok <- validate_category(category),
         :ok <- validate_first(first),
         {:ok, owner, _message, snapshot} <- MemoryContext.resolve(context),
         {:ok, projections} <- ProfileMemory.project_active(owner, snapshot, limit: 100) do
      selected =
        projections
        |> Enum.filter(&(category == "" or &1["category"] == category))
        |> Enum.filter(&(&1["projection"] == "admitted"))

      memories = selected |> Enum.take(first) |> Enum.map(&projection_output/1)

      {:ok,
       %ExecutionResult{
         result: %{
           "schema" => "sarah.memory_list_result.v1",
           "scope" => "this_browser",
           "snapshot_ref" => snapshot.ref,
           "status" => if(memories == [], do: "empty", else: "matches"),
           "memories" => memories,
           "truncated" => length(selected) > length(memories)
         },
         target_receipt_refs: Enum.map(memories, & &1["record_ref"])
       }}
    end
  end

  defp validate_category(category) when is_binary(category) do
    if category in ["" | OpenAgents.ProfileMemory.Record.categories()],
      do: :ok,
      else: {:error, :invalid_memory_category}
  end

  defp validate_category(_category), do: {:error, :invalid_memory_category}
  defp validate_first(first) when is_integer(first) and first in 1..25, do: :ok
  defp validate_first(_first), do: {:error, :invalid_result_limit}

  defp projection_output(projection) do
    %{
      "record_ref" => "profile-memory:v1:#{projection["id"]}:#{projection["generation"]}",
      "id" => projection["id"],
      "category" => projection["category"],
      "claim" => projection["claim"],
      "generation" => projection["generation"],
      "source_refs" =>
        projection["sources"]
        |> Enum.map(& &1["source_ref"])
        |> Enum.reject(&is_nil/1)
    }
  end

  defp input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "category" => MemoryContract.string(32),
        "first" => %{"type" => "integer", "minimum" => 1, "maximum" => 25}
      },
      "required" => ["category", "first"],
      "additionalProperties" => false
    }
  end

  defp output_schema do
    memory_schema =
      MemoryContract.memory_schema()
      |> put_in(["properties", "record_ref"], MemoryContract.string(128))
      |> Map.update!("required", &["record_ref" | &1])

    %{
      "type" => "object",
      "properties" => %{
        "schema" => MemoryContract.string(64),
        "scope" => MemoryContract.string(32),
        "snapshot_ref" => MemoryContract.string(128),
        "status" => MemoryContract.string(16),
        "memories" => %{"type" => "array", "maxItems" => 25, "items" => memory_schema},
        "truncated" => %{"type" => "boolean"}
      },
      "required" => ["schema", "scope", "snapshot_ref", "status", "memories", "truncated"],
      "additionalProperties" => false
    }
  end
end
