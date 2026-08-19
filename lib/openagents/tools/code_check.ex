defmodule OpenAgents.Tools.CodeCheck do
  @moduledoc """
  A cheap, safe pre-commit gate for Elixir source: full syntax check via
  `Code.string_to_quoted/2` always; a compile probe (`Code.compile_string/1`
  in a throwaway task, immediately purged) ONLY when none of the modules the
  source defines is already loaded — redefining a loaded module would be an
  ungoverned hot-load, so for running modules the sidecar build at promotion
  remains the compile gate and this tool says so honestly.
  """

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ExecutionResult, Tool}

  @impl true
  def specification do
    %Tool{
      module_id: "sarah.tool.code_check.v1",
      name: "code_check",
      version: 1,
      description:
        "Checks Elixir source before committing: always a full syntax parse; additionally a " <>
          "compile probe when the code's modules are not already loaded in the running " <>
          "system. Pass content as the complete file text. Returns ok, or the error with " <>
          "line information.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "content" => %{"type" => "string", "maxLength" => 200_000}
        },
        "required" => ["content"],
        "additionalProperties" => false
      },
      output_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => true},
      side_effect: :read_only,
      required_scope: "browser_conversation",
      required_authority: "code.execute",
      executor: %{
        id: "sarah.repository.self",
        disclosure: "Sarah's own runtime, parsing candidate code in a throwaway process"
      },
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/sarah"],
      policy_facets: %{
        "privacy" => "browser_conversation",
        "residency" => "application_process",
        "consent" => "not_applicable"
      },
      module_metadata:
        Metadata.first_party("code.execute", "browser_conversation",
          effect: :read_only,
          privacy: "browser_conversation",
          residency: "application_process",
          surfaces: ["text"]
        ),
      timeout_ms: 15_000,
      maximum_input_bytes: 262_144,
      maximum_output_bytes: 16_384,
      implementation: __MODULE__
    }
  end

  @impl true
  def execute(%{"content" => content}, _context) when is_binary(content) do
    case Code.string_to_quoted(content, columns: true) do
      {:ok, quoted} ->
        {compile_status, compile_detail} = compile_probe(content, quoted)

        {:ok,
         %ExecutionResult{
           result: %{
             "schema" => "sarah.code_check_result.v1",
             "syntax" => "ok",
             "compile" => compile_status,
             "detail" => compile_detail
           }
         }}

      {:error, {location, message, token}} ->
        {:ok,
         %ExecutionResult{
           result: %{
             "schema" => "sarah.code_check_result.v1",
             "syntax" => "error",
             "compile" => "skipped",
             "detail" =>
               "line #{location_line(location)}: #{format_message(message)}#{inspect(token)}"
           }
         }}
    end
  end

  def execute(_arguments, _context), do: {:error, :invalid_code_content}

  defp location_line(location) when is_list(location), do: Keyword.get(location, :line, 0)
  defp location_line(line) when is_integer(line), do: line
  defp location_line(_location), do: 0

  defp format_message({prefix, suffix}), do: "#{prefix}#{suffix} "
  defp format_message(message) when is_binary(message), do: message <> " "
  defp format_message(other), do: inspect(other) <> " "

  # Compile only when it cannot redefine anything the running system has
  # loaded; purge everything the probe defined either way.
  defp compile_probe(content, quoted) do
    defined = defined_modules(quoted)
    loaded = Enum.filter(defined, &Code.ensure_loaded?/1)

    cond do
      loaded != [] ->
        {"skipped",
         "modules already loaded in the running system (#{inspect(loaded)}); the sidecar " <>
           "build at promotion is the compile gate for running code"}

      true ->
        task =
          Task.async(fn ->
            try do
              modules = Code.compile_string(content)

              for {module, _binary} <- modules do
                :code.purge(module)
                :code.delete(module)
              end

              {"ok", nil}
            rescue
              error in CompileError ->
                {"error", "#{error.line}: #{error.description}"}

              error ->
                {"error", Exception.message(error)}
            end
          end)

        case Task.yield(task, 10_000) || Task.shutdown(task) do
          {:ok, result} -> result
          _timeout -> {"error", "compile probe timed out"}
        end
    end
  end

  defp defined_modules(quoted) do
    {_quoted, modules} =
      Macro.prewalk(quoted, [], fn
        {:defmodule, _meta, [{:__aliases__, _amet, parts} | _body]} = node, acc
        when is_list(parts) ->
          {node, [Module.concat(parts) | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(modules)
  end
end
