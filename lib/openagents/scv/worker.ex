defmodule OpenAgents.SCV.Worker do
  @moduledoc """
  Starts one read-only SCV from a worker environment.

  The staging entry point accepts only the OpenCode driver, the
  `opencode-core` environment, and the read-only permission profile. It writes
  structured events as JSON lines while the SCV runs and writes one terminal
  result after completion.
  """

  alias OpenAgents.SCV
  alias OpenAgents.SCV.OpenCodeReport
  alias OpenAgents.SCV.Run

  @default_model "openai/gpt-5.4-mini"
  @default_timeout_ms 300_000
  @default_output_root "/workspace/runs"
  @maximum_report_chunk_bytes 3_072

  @spec run(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(environment \\ System.get_env(), options \\ [])

  def run(environment, options) when is_map(environment) and is_list(options) do
    with {:ok, input} <- parse_environment(environment),
         {:ok, run} <- build_run(input, options) do
      SCV.run(run)
    end
  end

  def run(_environment, _options), do: {:error, :worker_input_invalid}

  @doc "Runs an SCV and emits Cloud Logging-compatible JSON lines."
  @spec run_from_env!() :: :ok
  def run_from_env! do
    sink = &write_json/1

    case run(System.get_env(), event_sink: sink) do
      {:ok, %{status: "succeeded"} = result} ->
        write_terminal_events(result)
        :ok

      {:ok, result} ->
        write_terminal_events(result)
        raise "SCV worker finished with status #{result.status}"

      {:error, reason} ->
        write_json(%{
          schema: "openagents.scv.worker.result.v1",
          type: "worker_failed",
          emitted_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          error_code: error_code(reason)
        })

        raise "SCV worker could not start: #{error_code(reason)}"
    end
  end

  defp parse_environment(environment) do
    with {:ok, repository} <- fetch_required(environment, "SCV_REPOSITORY"),
         {:ok, objective} <- fetch_required(environment, "SCV_OBJECTIVE"),
         {:ok, api_key} <- fetch_required(environment, "OPENAI_API_KEY"),
         {:ok, driver} <- fetch_value(environment, "SCV_DRIVER", "opencode", ["opencode"]),
         {:ok, scv_environment} <-
           fetch_value(environment, "SCV_ENVIRONMENT", "opencode-core", ["opencode-core"]),
         {:ok, permission_profile} <-
           fetch_value(environment, "SCV_PERMISSION_PROFILE", "read_only", ["read_only"]),
         {:ok, timeout_ms} <-
           fetch_integer(environment, "SCV_TIMEOUT_MS", @default_timeout_ms, 1..3_600_000),
         {:ok, heartbeat_interval_ms} <-
           fetch_integer(environment, "SCV_HEARTBEAT_INTERVAL_MS", 5_000, 250..60_000),
         {:ok, diagnostic_logs} <-
           fetch_boolean(environment, "SCV_DIAGNOSTIC_LOGS", false),
         {:ok, repository_revision} <-
           fetch_optional_revision(environment, "SCV_REPOSITORY_REVISION") do
      {:ok,
       %{
         repository: repository,
         repository_revision: repository_revision,
         objective: objective,
         api_key: api_key,
         driver: driver,
         environment: scv_environment,
         permission_profile: permission_profile,
         model: Map.get(environment, "SCV_MODEL", @default_model),
         output_root: Map.get(environment, "SCV_OUTPUT_ROOT", @default_output_root),
         executable: Map.get(environment, "OPENCODE_BIN"),
         config_seed: optional_value(environment, "OPENCODE_CONFIG_SEED"),
         run_id: optional_value(environment, "SCV_RUN_ID"),
         timeout_ms: timeout_ms,
         heartbeat_interval_ms: heartbeat_interval_ms,
         diagnostic_logs: diagnostic_logs
       }}
    end
  end

  defp build_run(input, options) do
    event_sink = Keyword.get(options, :event_sink, fn _event -> :ok end)
    overrides = Keyword.get(options, :driver_options, [])

    driver_options =
      [
        api_key: input.api_key,
        executable: input.executable,
        config_seed: input.config_seed,
        model: input.model,
        output_root: input.output_root,
        timeout_ms: input.timeout_ms,
        heartbeat_interval_ms: input.heartbeat_interval_ms,
        diagnostic_logs: input.diagnostic_logs,
        event_sink: event_sink
      ]
      |> Keyword.merge(overrides)

    run_options = [
      driver: input.driver,
      environment: input.environment,
      permission_profile: String.to_existing_atom(input.permission_profile),
      repository_revision: input.repository_revision,
      driver_options: driver_options
    ]

    run_options =
      if input.run_id, do: Keyword.put(run_options, :run_id, input.run_id), else: run_options

    Run.new(input.repository, input.objective, run_options)
  end

  defp fetch_required(environment, name) do
    case optional_value(environment, name) do
      nil -> {:error, {:environment_missing, name}}
      value -> {:ok, value}
    end
  end

  defp fetch_value(environment, name, default, admitted) do
    value = optional_value(environment, name) || default

    if value in admitted,
      do: {:ok, value},
      else: {:error, {:environment_value_not_admitted, name}}
  end

  defp fetch_integer(environment, name, default, range) do
    value = optional_value(environment, name) || Integer.to_string(default)

    case Integer.parse(value) do
      {integer, ""} ->
        if integer in range,
          do: {:ok, integer},
          else: {:error, {:environment_integer_invalid, name}}

      _invalid ->
        {:error, {:environment_integer_invalid, name}}
    end
  end

  defp fetch_boolean(environment, name, default) do
    case optional_value(environment, name) do
      nil -> {:ok, default}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _invalid -> {:error, {:environment_boolean_invalid, name}}
    end
  end

  defp fetch_optional_revision(environment, name) do
    case optional_value(environment, name) do
      nil ->
        {:ok, nil}

      revision ->
        if Regex.match?(~r/\A[0-9a-f]{40}\z/, revision),
          do: {:ok, revision},
          else: {:error, {:environment_revision_invalid, name}}
    end
  end

  defp optional_value(environment, name) do
    case Map.get(environment, name) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _value ->
        nil
    end
  end

  @doc false
  @spec terminal_events(map()) :: [map()]
  def terminal_events(result) when is_map(result) do
    chunks = OpenCodeReport.chunks(result.report, @maximum_report_chunk_bytes)
    emitted_at = DateTime.utc_now() |> DateTime.to_iso8601()
    chunk_count = length(chunks)
    report_digest = digest(result.report.text)

    report_events =
      chunks
      |> Enum.with_index(1)
      |> Enum.map(fn {chunk, sequence} ->
        %{
          schema: "openagents.scv.report.chunk.v1",
          type: "report_chunk",
          emitted_at: emitted_at,
          run_id: result.run_id,
          repository_revision: result.repository.git_sha,
          sequence: sequence,
          chunk_count: chunk_count,
          report_digest: report_digest,
          text: chunk
        }
      end)

    report_metadata = %{
      schema: result.report.schema,
      bytes: result.report.bytes,
      truncated: result.report.truncated,
      chunk_count: chunk_count,
      digest: report_digest
    }

    report_events ++ [worker_result(result, report_metadata, emitted_at)]
  end

  defp worker_result(result, report_metadata, emitted_at) do
    %{
      schema: "openagents.scv.worker.result.v1",
      type: "worker_finished",
      emitted_at: emitted_at,
      run_id: result.run_id,
      status: result.status,
      driver: result.scv.driver,
      environment: result.scv.environment,
      repository_revision: result.repository.git_sha,
      duration_ms: result.duration_ms,
      event_count: result.events.event_count,
      tool_calls: result.events.tool_calls,
      usage: result.events.usage,
      resources: result.resources,
      artifact_digest: result.artifacts.events_digest,
      report: report_metadata
    }
  end

  defp write_terminal_events(result) do
    result
    |> terminal_events()
    |> Enum.each(&write_json/1)
  end

  defp digest(value) do
    "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
  end

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "worker_failed"

  defp write_json(value), do: IO.puts(Jason.encode!(value))
end
