defmodule Mix.Tasks.Openagents.Scv.Opencode do
  @moduledoc """
  Runs one bounded local SCV execution through OpenCode.

  Set `OPENAI_API_KEY` in the process environment, then run:

      mix openagents.scv.opencode \
        --repo /absolute/path/to/repository \
        --prompt "Inspect README.md and return a one-sentence description."

  The task uses read-only repository permissions by default. Pass `--write` only
  for a disposable workspace. Run artifacts default to `_build/scv/runs`.
  """

  use Mix.Task

  alias OpenAgents.SCV

  @shortdoc "Run one bounded local SCV execution through OpenCode"

  @switches [
    repo: :string,
    prompt: :string,
    prompt_file: :string,
    model: :string,
    opencode: :string,
    config_seed: :string,
    output: :string,
    timeout_seconds: :integer,
    diagnostic_logs: :boolean,
    write: :boolean,
    json: :boolean
  ]

  @aliases [r: :repo, m: :model, o: :output]

  @impl Mix.Task
  def run(arguments) do
    {options, positionals, invalid} =
      OptionParser.parse(arguments, strict: @switches, aliases: @aliases)

    if invalid != [] do
      Mix.raise("Unknown or invalid options: #{format_invalid(invalid)}")
    end

    if positionals != [] do
      Mix.raise(
        "Unexpected positional arguments. Pass the objective with --prompt or --prompt-file."
      )
    end

    repository = options |> Keyword.get(:repo, File.cwd!()) |> Path.expand()
    prompt = read_prompt!(options)
    output_root = options |> Keyword.get(:output, "_build/scv/runs") |> Path.expand()
    timeout_ms = Keyword.get(options, :timeout_seconds, 300) * 1_000
    permissions = if Keyword.get(options, :write, false), do: :workspace_write, else: :read_only

    driver_options =
      [
        api_key: System.get_env("OPENAI_API_KEY"),
        executable: Keyword.get(options, :opencode, default_executable()),
        config_seed: config_seed(options),
        model: Keyword.get(options, :model, "openai/gpt-5.4-mini"),
        output_root: output_root,
        timeout_ms: timeout_ms,
        diagnostic_logs: Keyword.get(options, :diagnostic_logs, false),
        event_sink: &print_live_event/1
      ]

    case SCV.run(repository, prompt,
           driver: :opencode,
           environment: :opencode_core,
           permission_profile: permissions,
           driver_options: driver_options
         ) do
      {:ok, result} ->
        print_result(result, Keyword.get(options, :json, false))

        if result.status != "succeeded" do
          Mix.raise("SCV execution ended with status #{result.status}.")
        end

      {:error, reason} ->
        Mix.raise("SCV execution could not start: #{inspect(reason)}")
    end
  end

  defp read_prompt!(options) do
    case {Keyword.get(options, :prompt), Keyword.get(options, :prompt_file)} do
      {prompt, nil} when is_binary(prompt) ->
        prompt

      {nil, path} when is_binary(path) ->
        case File.read(Path.expand(path)) do
          {:ok, prompt} ->
            prompt

          {:error, reason} ->
            Mix.raise("Could not read the prompt file: #{:file.format_error(reason)}")
        end

      {nil, nil} ->
        Mix.raise("Pass exactly one of --prompt or --prompt-file.")

      {_prompt, _path} ->
        Mix.raise("Pass exactly one of --prompt or --prompt-file.")
    end
  end

  defp print_result(result, true) do
    Mix.shell().info(Jason.encode!(result, pretty: true))
  end

  defp print_result(result, false) do
    session = List.first(result.events.session_ids) || "none"

    Mix.shell().info("SCV run: #{result.run_id}")
    Mix.shell().info("Status: #{result.status}")
    Mix.shell().info("OpenCode session: #{session}")
    Mix.shell().info("Duration: #{result.duration_ms} ms")
    Mix.shell().info("Events: #{result.events.event_count}")
    Mix.shell().info("Peak OpenCode RSS: #{result.resources.peak_rss_bytes} bytes")
    Mix.shell().info("Estimated cost: $#{format_cost(result.events.usage.cost_usd)}")
    Mix.shell().info("Event artifact: #{result.artifacts.events_path}")
    Mix.shell().info("Summary: #{result.summary_path}")
  end

  defp default_executable do
    System.get_env("OPENCODE_BIN") || System.find_executable("opencode")
  end

  defp config_seed(options) do
    case Keyword.get(options, :config_seed, System.get_env("OPENCODE_CONFIG_SEED")) do
      nil -> nil
      path -> Path.expand(path)
    end
  end

  defp format_invalid(invalid) do
    Enum.map_join(invalid, ", ", fn {name, value} -> "#{name}=#{inspect(value)}" end)
  end

  defp format_cost(cost) when is_number(cost), do: :erlang.float_to_binary(cost / 1, decimals: 6)

  defp print_live_event(%{type: "opencode_diagnostic", line: line}) do
    IO.puts(:stderr, "[SCV][OpenCode] #{line}")
  end

  defp print_live_event(%{type: "opencode_event"} = event) do
    details =
      [
        event.event_type,
        event.tool && "tool=#{event.tool}",
        event.tool_status && "status=#{event.tool_status}",
        event.text_bytes > 0 && "text_bytes=#{event.text_bytes}",
        event.error_name && "error=#{event.error_name}"
      ]
      |> Enum.filter(& &1)
      |> Enum.join(" ")

    IO.puts(:stderr, "[SCV] OpenCode event: #{details}")
  end

  defp print_live_event(%{type: "heartbeat"} = event) do
    rss_mib = Float.round(event.peak_rss_bytes / 1_048_576, 1)

    IO.puts(
      :stderr,
      "[SCV] Running: #{event.elapsed_ms} ms, RSS #{rss_mib} MiB, max CPU #{event.maximum_cpu_percent}%"
    )
  end

  defp print_live_event(%{type: type}) do
    IO.puts(:stderr, "[SCV] #{String.replace(type, "_", " ")}")
  end
end
