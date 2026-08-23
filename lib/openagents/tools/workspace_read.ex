defmodule OpenAgents.Tools.WorkspaceRead do
  @moduledoc "Reads bounded text from an explicit, noncanonical agent workspace."

  @behaviour OpenAgents.Tools.Tool
  @max_lines 2_000
  @max_bytes 50 * 1_024

  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ExecutionResult, Redaction, Tool, WorkspaceFiles}

  @impl true
  def specification do
    %Tool{
      module_id: "openagents.tool.workspace_read.v1",
      name: "read",
      version: 1,
      description:
        "Reads a UTF-8 file from the explicit repository or computer workspace. " <>
          "Offset is one-based; each result is bounded to 2,000 lines and 50 KiB.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "maxLength" => 512},
          "offset" => %{"type" => "integer", "minimum" => 1},
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => @max_lines}
        },
        "required" => ["path"],
        "additionalProperties" => false
      },
      output_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => true},
      side_effect: :read_only,
      required_scope: "browser_conversation",
      required_authority: "repository.read",
      executor: %{id: "openagents.workspace", disclosure: "the assigned agent workspace"},
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/openagents.com"],
      policy_facets: %{"privacy" => "browser_conversation", "residency" => "host"},
      module_metadata:
        Metadata.first_party("repository.read", "browser_conversation",
          effect: :read_only,
          privacy: "browser_conversation",
          residency: "host",
          surfaces: ["text", "voice"]
        ),
      timeout_ms: 10_000,
      maximum_input_bytes: 2_048,
      maximum_output_bytes: 64 * 1_024,
      implementation: __MODULE__
    }
  end

  @impl true
  def execute(%{"path" => path} = arguments, context) when is_binary(path) do
    offset = Map.get(arguments, "offset", 1)
    limit = Map.get(arguments, "limit", @max_lines)

    with true <- is_integer(offset) and offset > 0,
         true <- is_integer(limit) and limit > 0 and limit <= @max_lines,
         {:ok, target} <- WorkspaceFiles.resolve(context, path, :read),
         {:ok, content} <- WorkspaceFiles.read_regular(target),
         :ok <- valid_content(content),
         {:ok, result} <- bounded_lines(content, offset, limit) do
      {:ok,
       %ExecutionResult{
         result:
           Map.merge(result, %{
             "schema" => "openagents.workspace_read_result.v1",
             "path" => path,
             "digest" => WorkspaceFiles.digest(content),
             "workspace_ref" => target.ref
           })
       }}
    else
      false -> {:error, :invalid_read_range}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(_arguments, _context), do: {:error, :invalid_workspace_path}

  defp bounded_lines(content, offset, limit) do
    lines = lines_with_endings(content)
    total = length(lines)

    cond do
      total == 0 and offset == 1 ->
        {:ok, %{"content" => "", "line_count" => 0, "next_offset" => nil, "offset" => 1}}

      offset > total ->
        {:error, :invalid_read_range}

      true ->
        selected = lines |> Enum.drop(offset - 1) |> Enum.take(limit)

        with {:ok, visible, bytes} <- take_bytes(selected, @max_bytes) do
          count = length(visible)
          more? = offset - 1 + count < total

          {:ok,
           %{
             "content" => visible |> IO.iodata_to_binary() |> Redaction.redact_text(),
             "line_count" => count,
             "next_offset" => if(more?, do: offset + count, else: nil),
             "offset" => offset,
             "returned_bytes" => bytes,
             "total_lines" => total
           }}
        end
    end
  end

  defp lines_with_endings(""), do: []

  defp lines_with_endings(content) do
    parts = :binary.split(content, "\n", [:global])
    trailing_newline? = List.last(parts) == ""
    content_parts = if trailing_newline?, do: Enum.drop(parts, -1), else: parts
    last_index = length(content_parts) - 1

    content_parts
    |> Enum.with_index()
    |> Enum.map(fn {line, index} ->
      if trailing_newline? or index < last_index, do: line <> "\n", else: line
    end)
  end

  defp take_bytes(lines, maximum) do
    Enum.reduce_while(lines, {[], 0}, fn line, {accepted, bytes} ->
      size = byte_size(line)

      cond do
        bytes + size <= maximum ->
          {:cont, {[line | accepted], bytes + size}}

        accepted == [] ->
          {:halt, {:error, :workspace_line_too_large}}

        true ->
          {:halt, {accepted, bytes}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      {accepted, bytes} -> {:ok, Enum.reverse(accepted), bytes}
    end
  end

  defp valid_content(content),
    do: if(String.valid?(content), do: :ok, else: {:error, :workspace_invalid_encoding})
end
