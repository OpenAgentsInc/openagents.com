defmodule OpenAgents.Tools.RepoGrep do
  @moduledoc "Searches OpenAgents source for a pattern, bounded, without shelling out."

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ExecutionResult, Repository, Tool}

  @max_results 100
  @max_file_bytes 1_000_000
  @skip_dirs ~w(.git _build deps node_modules priv/static assets/node_modules)

  @impl true
  def specification do
    %Tool{
      module_id: "sarah.tool.repo_grep.v1",
      name: "repo_grep",
      version: 1,
      description:
        "Searches OpenAgents source code for a regular expression. Returns matching " <>
          "path:line:text rows, bounded. Optional glob filters files (e.g. \"lib/**/*.ex\"); " <>
          "from selects \"image\" (running source, default) or \"workspace\" (this job's clone).",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{"type" => "string", "maxLength" => 512},
          "glob" => %{"type" => "string", "maxLength" => 256},
          "from" => %{"type" => "string", "enum" => ["image", "workspace"]},
          "max_results" => %{"type" => "integer", "minimum" => 1, "maximum" => 100}
        },
        "required" => ["pattern"],
        "additionalProperties" => false
      },
      output_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => true},
      side_effect: :read_only,
      required_scope: "browser_conversation",
      required_authority: "repository.read",
      executor: %{
        id: "sarah.repository.self",
        disclosure: "the OpenAgents runtime, searching her running source"
      },
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/openagents.com"],
      policy_facets: %{
        "privacy" => "browser_conversation",
        "residency" => "host",
        "consent" => "not_applicable"
      },
      module_metadata:
        Metadata.first_party("repository.read", "browser_conversation",
          effect: :read_only,
          privacy: "browser_conversation",
          residency: "host",
          surfaces: ["text"]
        ),
      timeout_ms: 30_000,
      maximum_input_bytes: 2_048,
      maximum_output_bytes: 131_072,
      implementation: __MODULE__
    }
  end

  @impl true
  def execute(%{"pattern" => pattern} = arguments, context) when is_binary(pattern) do
    with {:ok, root} <- Repository.tool_root(Map.get(arguments, "from", "image"), context),
         {:ok, regex} <- compile_pattern(pattern) do
      limit = Map.get(arguments, "max_results", @max_results)
      glob = Map.get(arguments, "glob")

      matches =
        root
        |> candidate_files(glob)
        |> Enum.reduce_while([], fn file, acc ->
          remaining = limit - length(acc)

          if remaining <= 0 do
            {:halt, acc}
          else
            {:cont, acc ++ file_matches(root, file, regex, remaining)}
          end
        end)

      {:ok,
       %ExecutionResult{
         result: %{
           "schema" => "sarah.repo_grep_result.v1",
           "pattern" => pattern,
           "status" => if(matches == [], do: "empty", else: "matches"),
           "matches" => matches,
           "truncated" => length(matches) >= limit
         }
       }}
    end
  end

  def execute(_arguments, _context), do: {:error, :invalid_search_pattern}

  defp compile_pattern(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> {:ok, regex}
      {:error, _reason} -> {:error, :invalid_search_pattern}
    end
  end

  defp candidate_files(root, glob) do
    pattern = if is_binary(glob) and glob != "", do: glob, else: "**/*"

    root
    |> Path.join(pattern)
    |> Path.wildcard(match_dot: false)
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(fn path ->
      relative = Path.relative_to(path, root)
      Enum.any?(@skip_dirs, &(relative == &1 or String.starts_with?(relative, &1 <> "/")))
    end)
    |> Enum.sort()
  end

  defp file_matches(root, file, regex, remaining) do
    case File.stat(file) do
      {:ok, %{size: size}} when size <= @max_file_bytes ->
        content = File.read!(file)

        if String.valid?(content) do
          relative = Path.relative_to(file, root)

          content
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _number} -> Regex.match?(regex, line) end)
          |> Enum.take(remaining)
          |> Enum.map(fn {line, number} ->
            %{"path" => relative, "line" => number, "text" => String.slice(line, 0, 400)}
          end)
        else
          []
        end

      _too_big_or_missing ->
        []
    end
  end
end
