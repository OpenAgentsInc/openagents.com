defmodule OpenAgents.SCV.Executor.OpenCode do
  @moduledoc """
  Runs one bounded OpenCode process under the local SCV control boundary.

  This initial executor treats the OpenCode process as one coarse effect. It
  isolates OpenCode state, denies unsafe capabilities, records JSON events, and
  collects host-observed measurements. A later worker transport persists each
  individual OpenCode tool request before execution.
  """

  alias OpenAgents.SCV.OpenCodeEvents
  alias OpenAgents.SCV.OpenCodeReport
  alias OpenAgents.SCV.ResourceSampler

  @schema "openagents.scv.opencode.run.v1"
  @default_model "openai/gpt-5.4-mini"
  @default_timeout_ms 5 * 60 * 1_000
  @maximum_timeout_ms 60 * 60 * 1_000
  @default_maximum_output_bytes 16 * 1_024 * 1_024
  @maximum_output_bytes 64 * 1_024 * 1_024
  @default_sample_interval_ms 250
  @default_heartbeat_interval_ms 5_000
  @maximum_prompt_bytes 32_768
  @maximum_model_bytes 128
  @model_pattern ~r/\A[a-zA-Z0-9_.:-]+\/[a-zA-Z0-9_.:-]+\z/

  @spec run(Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, atom() | tuple()}
  def run(repository, prompt, options \\ []) do
    with {:ok, input} <- validate_input(repository, prompt, options),
         :ok <-
           emit_event(input, "run_preparing", %{
             model: input.model,
             permission_profile: Atom.to_string(input.permissions)
           }),
         {:ok, paths} <- prepare_paths(input.output_root, input.run_id, input.config_seed) do
      try do
        execute(input, paths, options)
      after
        File.rm_rf(paths.scratch)
      end
    end
  end

  defp validate_input(repository, prompt, options) do
    model = Keyword.get(options, :model, @default_model)
    timeout_ms = Keyword.get(options, :timeout_ms, @default_timeout_ms)

    maximum_output_bytes =
      Keyword.get(options, :maximum_output_bytes, @default_maximum_output_bytes)

    sample_interval_ms = Keyword.get(options, :sample_interval_ms, @default_sample_interval_ms)
    permissions = Keyword.get(options, :permissions, :read_only)
    run_id = Keyword.get(options, :run_id, Ecto.UUID.generate())
    output_root = Keyword.get(options, :output_root, default_output_root())
    api_key = Keyword.get(options, :api_key, System.get_env("OPENAI_API_KEY"))
    executable = Keyword.get(options, :executable, default_executable())
    config_seed = Keyword.get(options, :config_seed)
    diagnostic_logs = Keyword.get(options, :diagnostic_logs, false)
    repository_revision = Keyword.get(options, :repository_revision)
    event_context = Keyword.get(options, :event_context, %{})
    run_context = Keyword.get(options, :run_context, %{})

    heartbeat_interval_ms =
      Keyword.get(options, :heartbeat_interval_ms, @default_heartbeat_interval_ms)

    event_sink = Keyword.get(options, :event_sink, fn _event -> :ok end)

    with {:ok, repository} <- validate_directory(repository),
         :ok <- validate_prompt(prompt),
         :ok <- validate_model(model),
         :ok <- validate_integer(timeout_ms, 1, @maximum_timeout_ms, :timeout_invalid),
         :ok <-
           validate_integer(
             maximum_output_bytes,
             1,
             @maximum_output_bytes,
             :maximum_output_invalid
           ),
         :ok <- validate_integer(sample_interval_ms, 10, 60_000, :sample_interval_invalid),
         :ok <- validate_permissions(permissions),
         :ok <- validate_run_id(run_id),
         {:ok, output_root} <- validate_output_root(output_root),
         :ok <- validate_api_key(api_key),
         :ok <- validate_boolean(diagnostic_logs, :diagnostic_logs_invalid),
         :ok <-
           validate_integer(
             heartbeat_interval_ms,
             250,
             60_000,
             :heartbeat_interval_invalid
           ),
         :ok <- validate_event_sink(event_sink),
         :ok <- validate_repository_revision(repository_revision),
         :ok <- validate_context(event_context, :event_context_invalid),
         :ok <- validate_context(run_context, :run_context_invalid),
         {:ok, config_seed} <- validate_config_seed(config_seed),
         {:ok, executable} <- validate_executable(executable) do
      {:ok,
       %{
         repository: repository,
         prompt: prompt,
         prompt_bytes: byte_size(prompt),
         model: model,
         timeout_ms: timeout_ms,
         maximum_output_bytes: maximum_output_bytes,
         sample_interval_ms: sample_interval_ms,
         permissions: permissions,
         run_id: run_id,
         output_root: output_root,
         api_key: api_key,
         executable: executable,
         config_seed: config_seed,
         diagnostic_logs: diagnostic_logs,
         repository_revision: repository_revision,
         event_context: event_context,
         run_context: run_context,
         heartbeat_interval_ms: heartbeat_interval_ms,
         event_sink: event_sink
       }}
    end
  end

  defp prepare_paths(output_root, run_id, config_seed) do
    run_dir = Path.join(output_root, run_id)

    paths = %{
      run_dir: run_dir,
      artifacts: Path.join(run_dir, "artifacts"),
      events: Path.join([run_dir, "artifacts", "events.jsonl"]),
      summary: Path.join(run_dir, "summary.json"),
      scratch: Path.join(run_dir, "scratch"),
      home: Path.join([run_dir, "scratch", "home"]),
      config_root: Path.join([run_dir, "scratch", "xdg", "config"]),
      config: Path.join([run_dir, "scratch", "xdg", "config", "opencode"]),
      data: Path.join([run_dir, "scratch", "xdg", "data"]),
      state: Path.join([run_dir, "scratch", "xdg", "state"]),
      cache: Path.join([run_dir, "scratch", "xdg", "cache"]),
      tmp: Path.join([run_dir, "scratch", "tmp"]),
      database: Path.join([run_dir, "scratch", "opencode.db"]),
      prompt: Path.join([run_dir, "scratch", "prompt.txt"])
    }

    directories = [
      paths.artifacts,
      paths.home,
      paths.config,
      paths.data,
      paths.state,
      paths.cache,
      paths.tmp
    ]

    if File.exists?(run_dir) do
      {:error, :run_exists}
    else
      with :ok <- File.mkdir_p(run_dir),
           :ok <- File.chmod(run_dir, 0o700),
           :ok <- create_directories(directories),
           :ok <- seed_config(paths.config, config_seed) do
        {:ok, paths}
      end
    end
  end

  defp execute(input, paths, options) do
    started_at = DateTime.utc_now()
    started_ms = monotonic_ms()
    permission_map = permission_map(input.permissions)
    config = open_code_config()
    environment = command_environment(input, paths, config, permission_map)
    arguments = command_arguments(input)
    sample_fun = Keyword.get(options, :sample_fun, &ResourceSampler.sample/1)

    with :ok <- write_prompt(paths.prompt, input.prompt),
         {:ok, events_io} <- File.open(paths.events, [:write, :binary]),
         :ok <- File.chmod(paths.events, 0o600) do
      :ok = emit_event(input, "process_starting", %{executable: input.executable})

      execution =
        try do
          run_port(input, arguments, environment, events_io, sample_fun)
        after
          File.close(events_io)
        end

      result =
        build_result(
          input,
          paths,
          execution,
          started_at,
          started_ms,
          config,
          permission_map
        )

      with :ok <- write_summary(paths.summary, result) do
        :ok =
          emit_event(input, "run_finished", %{
            status: result.status,
            duration_ms: result.duration_ms,
            summary_path: paths.summary
          })

        {:ok, Map.put(result, :summary_path, paths.summary)}
      end
    else
      {:error, {:prompt_write_failed, _reason}} = error -> error
      {:error, reason} -> {:error, {:artifact_open_failed, reason}}
    end
  end

  defp run_port(input, arguments, environment, events_io, sample_fun) do
    shell = System.find_executable("sh") || "/bin/sh"

    shell_arguments = [
      "-c",
      "exec \"$@\" < \"$SCV_PROMPT_FILE\"",
      "scv-opencode",
      input.executable | arguments
    ]

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(shell)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: Enum.map(shell_arguments, &String.to_charlist/1),
          cd: String.to_charlist(input.repository),
          env: port_environment(environment)
        ]
      )

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    now = monotonic_ms()

    :ok = emit_event(input, "process_started", %{os_pid: os_pid})

    state = %{
      events: OpenCodeEvents.new(),
      report: OpenCodeReport.new(),
      line_buffer: "",
      observed_output_bytes: 0,
      captured_output_bytes: 0,
      output_truncated?: false,
      sample_count: 0,
      sample_error_count: 0,
      peak_rss_bytes: 0,
      maximum_cpu_percent: 0.0,
      started_ms: now,
      next_heartbeat_ms: now + input.heartbeat_interval_ms,
      heartbeat_interval_ms: input.heartbeat_interval_ms,
      input: input
    }

    collect_port(
      port,
      os_pid,
      events_io,
      state,
      monotonic_ms() + input.timeout_ms,
      now,
      input.sample_interval_ms,
      input.maximum_output_bytes,
      sample_fun,
      [input.api_key]
    )
  rescue
    error ->
      %{
        status: "failed",
        exit_status: nil,
        error_code: "process_start_failed",
        error_detail: Exception.message(error),
        events: OpenCodeEvents.new(),
        report: OpenCodeReport.new(),
        observed_output_bytes: 0,
        captured_output_bytes: 0,
        output_truncated?: false,
        sample_count: 0,
        sample_error_count: 0,
        peak_rss_bytes: 0,
        maximum_cpu_percent: 0.0
      }
  end

  defp collect_port(
         port,
         os_pid,
         events_io,
         state,
         deadline_ms,
         next_sample_ms,
         sample_interval_ms,
         maximum_output_bytes,
         sample_fun,
         redactions
       ) do
    now = monotonic_ms()

    cond do
      now >= deadline_ms ->
        terminate_port(port, os_pid)
        finish_collection(state, events_io, redactions, "timeout", nil, "command_timeout")

      now >= next_sample_ms ->
        sampled = sample_resources(state, os_pid, sample_fun)

        collect_port(
          port,
          os_pid,
          events_io,
          sampled,
          deadline_ms,
          now + sample_interval_ms,
          sample_interval_ms,
          maximum_output_bytes,
          sample_fun,
          redactions
        )

      true ->
        wait_ms = max(min(deadline_ms, next_sample_ms) - now, 1)

        receive do
          {^port, {:data, data}} when is_binary(data) ->
            {updated, limit_reached?} =
              capture_output(state, data, events_io, maximum_output_bytes, redactions)

            if limit_reached? do
              terminate_port(port, os_pid)

              finish_collection(
                updated,
                events_io,
                redactions,
                "output_limit",
                nil,
                "output_limit"
              )
            else
              collect_port(
                port,
                os_pid,
                events_io,
                updated,
                deadline_ms,
                next_sample_ms,
                sample_interval_ms,
                maximum_output_bytes,
                sample_fun,
                redactions
              )
            end

          {^port, {:exit_status, exit_status}} ->
            status = if exit_status == 0, do: "succeeded", else: "failed"
            error_code = if exit_status == 0, do: nil, else: "command_failed"

            finish_collection(
              state,
              events_io,
              redactions,
              status,
              exit_status,
              error_code
            )
        after
          wait_ms ->
            collect_port(
              port,
              os_pid,
              events_io,
              state,
              deadline_ms,
              next_sample_ms,
              sample_interval_ms,
              maximum_output_bytes,
              sample_fun,
              redactions
            )
        end
    end
  end

  defp capture_output(state, data, events_io, maximum_output_bytes, redactions) do
    observed = state.observed_output_bytes + byte_size(data)
    available = max(maximum_output_bytes - state.captured_output_bytes, 0)
    captured = binary_part(data, 0, min(byte_size(data), available))
    updated = append_event_bytes(state, captured, events_io, redactions)

    updated = %{
      updated
      | observed_output_bytes: observed,
        captured_output_bytes: updated.captured_output_bytes + byte_size(captured),
        output_truncated?: byte_size(captured) < byte_size(data)
    }

    {updated, updated.output_truncated? or updated.captured_output_bytes >= maximum_output_bytes}
  end

  defp append_event_bytes(state, "", _events_io, _redactions), do: state

  defp append_event_bytes(state, data, events_io, redactions) do
    pieces = :binary.split(state.line_buffer <> data, "\n", [:global])
    {buffer, complete_lines} = List.pop_at(pieces, -1)

    {events, report} =
      Enum.reduce(complete_lines, {state.events, state.report}, fn line, {events, report} ->
        redacted = redact(line, redactions)
        :ok = IO.binwrite(events_io, redacted <> "\n")
        :ok = observe_output_line(state.input, redacted)
        {ingest_nonempty(events, redacted), ingest_report(report, redacted)}
      end)

    %{state | events: events, report: report, line_buffer: buffer || ""}
  end

  defp finish_collection(state, events_io, redactions, status, exit_status, error_code) do
    {events, report, line_buffer} =
      flush_line(
        state.input,
        state.events,
        state.report,
        state.line_buffer,
        events_io,
        redactions
      )

    :ok = :file.sync(events_io)

    :ok =
      emit_event(state.input, "process_finished", %{
        status: status,
        exit_status: exit_status,
        error_code: error_code
      })

    state
    |> Map.put(:events, events)
    |> Map.put(:report, report)
    |> Map.put(:line_buffer, line_buffer)
    |> Map.put(:status, status)
    |> Map.put(:exit_status, exit_status)
    |> Map.put(:error_code, error_code)
    |> Map.put(:error_detail, nil)
  end

  defp flush_line(_input, events, report, "", _events_io, _redactions),
    do: {events, report, ""}

  defp flush_line(input, events, report, line, events_io, redactions) do
    redacted = redact(line, redactions)
    :ok = IO.binwrite(events_io, redacted)
    :ok = observe_output_line(input, redacted)

    {
      ingest_nonempty(events, redacted),
      ingest_report(report, redacted),
      ""
    }
  end

  defp ingest_nonempty(events, ""), do: events
  defp ingest_nonempty(events, line), do: OpenCodeEvents.ingest(events, line)

  defp ingest_report(report, ""), do: report
  defp ingest_report(report, line), do: OpenCodeReport.ingest(report, line)

  defp observe_output_line(_input, ""), do: :ok

  defp observe_output_line(input, line) do
    case Jason.decode(line) do
      {:ok, event} when is_map(event) ->
        emit_event(input, "opencode_event", live_open_code_event(event))

      _invalid when input.diagnostic_logs ->
        emit_event(input, "opencode_diagnostic", %{line: line})

      _invalid ->
        :ok
    end
  end

  defp live_open_code_event(event) do
    part = if is_map(event["part"]), do: event["part"], else: %{}
    state = if is_map(part["state"]), do: part["state"], else: %{}

    %{
      event_type: bounded_value(event["type"], 64, "unknown"),
      session_id: bounded_value(event["sessionID"], 128, nil),
      tool: bounded_value(part["tool"], 128, nil),
      tool_status: bounded_value(state["status"], 32, nil),
      text_bytes: byte_count(part["text"]),
      error_name: bounded_value(get_in(event, ["error", "name"]), 128, nil)
    }
  end

  defp sample_resources(state, os_pid, sample_fun) do
    sampled =
      case sample_fun.(os_pid) do
        {:ok, %{rss_bytes: rss_bytes, cpu_percent: cpu_percent}}
        when is_integer(rss_bytes) and rss_bytes >= 0 and is_number(cpu_percent) and
               cpu_percent >= 0 ->
          %{
            state
            | sample_count: state.sample_count + 1,
              peak_rss_bytes: max(state.peak_rss_bytes, rss_bytes),
              maximum_cpu_percent: max(state.maximum_cpu_percent, cpu_percent)
          }

        _error ->
          %{state | sample_error_count: state.sample_error_count + 1}
      end

    maybe_emit_heartbeat(sampled)
  end

  defp maybe_emit_heartbeat(state) do
    now = monotonic_ms()

    if now >= state.next_heartbeat_ms do
      :ok =
        emit_event(state.input, "heartbeat", %{
          elapsed_ms: max(now - state.started_ms, 0),
          peak_rss_bytes: state.peak_rss_bytes,
          maximum_cpu_percent: state.maximum_cpu_percent,
          observed_output_bytes: state.observed_output_bytes,
          sample_count: state.sample_count
        })

      %{state | next_heartbeat_ms: now + state.heartbeat_interval_ms}
    else
      state
    end
  end

  defp terminate_port(port, os_pid) do
    terminate_os_process(os_pid)

    if Port.info(port) do
      Port.close(port)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp terminate_os_process(os_pid) when is_integer(os_pid) and os_pid > 0 do
    case System.find_executable("kill") do
      nil ->
        :ok

      executable ->
        System.cmd(executable, ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end

    :ok
  rescue
    _error -> :ok
  end

  defp build_result(input, paths, execution, started_at, started_ms, config, permissions) do
    finished_at = DateTime.utc_now()
    duration_ms = max(monotonic_ms() - started_ms, 0)
    events_bytes = File.read!(paths.events)

    %{
      schema: @schema,
      run_id: input.run_id,
      status: execution.status,
      error_code: execution.error_code,
      exit_status: execution.exit_status,
      started_at: DateTime.to_iso8601(started_at),
      finished_at: DateTime.to_iso8601(finished_at),
      duration_ms: duration_ms,
      repository: %{
        path: input.repository,
        git_sha: input.repository_revision || git_sha(input.repository)
      },
      scv: input.run_context,
      runtime: %{
        adapter: "opencode",
        executable: input.executable,
        model: input.model,
        diagnostic_logs: input.diagnostic_logs,
        config_seeded: not is_nil(input.config_seed),
        permission_profile: Atom.to_string(input.permissions),
        permission_digest: digest(Jason.encode!(permissions)),
        config_digest: digest(Jason.encode!(config))
      },
      request: %{
        prompt_bytes: input.prompt_bytes,
        timeout_ms: input.timeout_ms,
        maximum_output_bytes: input.maximum_output_bytes
      },
      events: OpenCodeEvents.summary(execution.events),
      report: OpenCodeReport.summary(execution.report),
      resources: %{
        wall_time_ms: duration_ms,
        sample_count: execution.sample_count,
        sample_error_count: execution.sample_error_count,
        peak_rss_bytes: execution.peak_rss_bytes,
        maximum_cpu_percent: execution.maximum_cpu_percent,
        observed_output_bytes: execution.observed_output_bytes,
        captured_output_bytes: execution.captured_output_bytes,
        output_truncated: execution.output_truncated?
      },
      artifacts: %{
        events_path: paths.events,
        events_bytes: byte_size(events_bytes),
        events_digest: digest(events_bytes)
      }
    }
  end

  defp write_summary(path, result) do
    temporary = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))
    bytes = Jason.encode!(result, pretty: true)

    with :ok <- File.write(temporary, bytes, [:binary, :exclusive]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, {:summary_write_failed, reason}}
    end
  end

  defp write_prompt(path, prompt) do
    with :ok <- File.write(path, prompt, [:binary, :exclusive]),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      {:error, reason} -> {:error, {:prompt_write_failed, reason}}
    end
  end

  defp command_arguments(input) do
    arguments = [
      "run",
      "--pure",
      "--format",
      "json",
      "--model",
      input.model,
      "--dir",
      input.repository
    ]

    if input.diagnostic_logs do
      ["--print-logs", "--log-level", "DEBUG" | arguments]
    else
      arguments
    end
  end

  defp command_environment(input, paths, config, permissions) do
    safe = %{
      "CI" => "1",
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_TERMINAL_PROMPT" => "0",
      "HOME" => paths.home,
      "LANG" => "C.UTF-8",
      "LC_ALL" => "C.UTF-8",
      "LOGNAME" => "scv",
      "NO_COLOR" => "1",
      "OPENAI_API_KEY" => input.api_key,
      "OPENCODE_CLIENT" => "scv",
      "OPENCODE_CONFIG_CONTENT" => Jason.encode!(config),
      "OPENCODE_CONFIG_DIR" => paths.config,
      "OPENCODE_DB" => paths.database,
      "OPENCODE_DISABLE_AUTOUPDATE" => "1",
      "OPENCODE_DISABLE_CLAUDE_CODE" => "1",
      "OPENCODE_DISABLE_DEFAULT_PLUGINS" => "1",
      "OPENCODE_DISABLE_EMBEDDED_WEB_UI" => "1",
      "OPENCODE_DISABLE_EXTERNAL_SKILLS" => "1",
      "OPENCODE_DISABLE_LSP_DOWNLOAD" => "1",
      "OPENCODE_DISABLE_MODELS_FETCH" => "1",
      "OPENCODE_DISABLE_PROJECT_CONFIG" => "1",
      "OPENCODE_DISABLE_SHARE" => "1",
      "OPENCODE_EXPERIMENTAL_DISABLE_FILEWATCHER" => "1",
      "OPENCODE_PERMISSION" => Jason.encode!(permissions),
      "OPENCODE_PURE" => "1",
      "PATH" => System.get_env("PATH", "/usr/local/bin:/usr/bin:/bin"),
      "PWD" => input.repository,
      "SCV_PROMPT_FILE" => paths.prompt,
      "SHELL" => "/bin/sh",
      "TERM" => "dumb",
      "TMPDIR" => paths.tmp,
      "USER" => "scv",
      "XDG_CACHE_HOME" => paths.cache,
      "XDG_CONFIG_HOME" => paths.config_root,
      "XDG_DATA_HOME" => paths.data,
      "XDG_STATE_HOME" => paths.state
    }

    System.get_env()
    |> Map.new(fn {key, _value} -> {key, false} end)
    |> Map.merge(safe)
  end

  defp port_environment(environment) do
    Enum.map(environment, fn
      {key, false} -> {String.to_charlist(key), false}
      {key, value} -> {String.to_charlist(key), String.to_charlist(value)}
    end)
  end

  defp permission_map(:read_only) do
    %{
      "bash" => "deny",
      "edit" => "deny",
      "external_directory" => "deny",
      "glob" => "allow",
      "grep" => "allow",
      "list" => "allow",
      "lsp" => "deny",
      "question" => "deny",
      "read" => "allow",
      "skill" => "deny",
      "task" => "deny",
      "webfetch" => "deny",
      "websearch" => "deny"
    }
  end

  defp permission_map(:workspace_write) do
    permission_map(:read_only)
    |> Map.put("edit", "allow")
  end

  defp open_code_config do
    %{
      "$schema" => "https://opencode.ai/config.json",
      "autoupdate" => false,
      "share" => "disabled",
      "username" => "scv"
    }
  end

  defp create_directories(directories) do
    Enum.reduce_while(directories, :ok, fn directory, :ok ->
      case File.mkdir_p(directory) do
        :ok ->
          case File.chmod(directory, 0o700) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:directory_chmod_failed, reason}}}
          end

        {:error, reason} ->
          {:halt, {:error, {:directory_create_failed, reason}}}
      end
    end)
  end

  defp seed_config(_destination, nil), do: :ok

  defp seed_config(destination, source) do
    entries = ["node_modules", "package.json", "bun.lock", "bun.lockb", "package-lock.json"]

    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      source_path = Path.join(source, entry)
      destination_path = Path.join(destination, entry)

      if File.exists?(source_path) do
        case File.cp_r(source_path, destination_path) do
          {:ok, _copied} -> {:cont, :ok}
          {:error, _path, reason} -> {:halt, {:error, {:config_seed_failed, reason}}}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp validate_directory(repository) when is_binary(repository) do
    expanded = Path.expand(repository)

    cond do
      Path.type(repository) != :absolute -> {:error, :repository_not_absolute}
      not File.dir?(expanded) -> {:error, :repository_not_found}
      true -> {:ok, expanded}
    end
  end

  defp validate_directory(_repository), do: {:error, :repository_invalid}

  defp validate_prompt(prompt)
       when is_binary(prompt) and byte_size(prompt) in 1..@maximum_prompt_bytes do
    if String.trim(prompt) == "", do: {:error, :prompt_empty}, else: :ok
  end

  defp validate_prompt(_prompt), do: {:error, :prompt_invalid}

  defp validate_model(model)
       when is_binary(model) and byte_size(model) in 1..@maximum_model_bytes do
    if Regex.match?(@model_pattern, model), do: :ok, else: {:error, :model_invalid}
  end

  defp validate_model(_model), do: {:error, :model_invalid}

  defp validate_integer(value, minimum, maximum, _error)
       when is_integer(value) and value >= minimum and value <= maximum,
       do: :ok

  defp validate_integer(_value, _minimum, _maximum, error), do: {:error, error}

  defp validate_boolean(value, _error) when is_boolean(value), do: :ok
  defp validate_boolean(_value, error), do: {:error, error}

  defp validate_event_sink(event_sink) when is_function(event_sink, 1), do: :ok
  defp validate_event_sink(_event_sink), do: {:error, :event_sink_invalid}

  defp validate_repository_revision(nil), do: :ok

  defp validate_repository_revision(revision) when is_binary(revision) do
    if Regex.match?(~r/\A[0-9a-f]{40}\z/, revision),
      do: :ok,
      else: {:error, :repository_revision_invalid}
  end

  defp validate_repository_revision(_revision), do: {:error, :repository_revision_invalid}

  defp validate_context(context, error) when is_map(context) and map_size(context) <= 16 do
    allowed = MapSet.new([:driver, :environment, :runner, :capabilities])

    if context |> Map.keys() |> MapSet.new() |> MapSet.subset?(allowed),
      do: :ok,
      else: {:error, error}
  end

  defp validate_context(_context, error), do: {:error, error}

  defp validate_permissions(permissions) when permissions in [:read_only, :workspace_write],
    do: :ok

  defp validate_permissions(_permissions), do: {:error, :permissions_invalid}

  defp validate_run_id(run_id) when is_binary(run_id) do
    case Ecto.UUID.cast(run_id) do
      {:ok, ^run_id} -> :ok
      _invalid -> {:error, :run_id_invalid}
    end
  end

  defp validate_run_id(_run_id), do: {:error, :run_id_invalid}

  defp validate_output_root(output_root) when is_binary(output_root) do
    if Path.type(output_root) == :absolute,
      do: {:ok, Path.expand(output_root)},
      else: {:error, :output_root_not_absolute}
  end

  defp validate_output_root(_output_root), do: {:error, :output_root_invalid}

  defp validate_api_key(api_key) when is_binary(api_key) and byte_size(api_key) in 8..16_384,
    do: :ok

  defp validate_api_key(_api_key), do: {:error, :openai_api_key_missing}

  defp validate_config_seed(nil), do: {:ok, nil}

  defp validate_config_seed(config_seed) when is_binary(config_seed) do
    expanded = Path.expand(config_seed)

    cond do
      Path.type(config_seed) != :absolute ->
        {:error, :config_seed_not_absolute}

      not File.dir?(expanded) ->
        {:error, :config_seed_not_found}

      not File.dir?(Path.join(expanded, "node_modules")) ->
        {:error, :config_seed_dependencies_missing}

      true ->
        {:ok, expanded}
    end
  end

  defp validate_config_seed(_config_seed), do: {:error, :config_seed_invalid}

  defp validate_executable(executable) when is_binary(executable) do
    expanded = Path.expand(executable)

    with true <- Path.type(executable) == :absolute or {:error, :executable_not_absolute},
         {:ok, %{type: :regular, mode: mode}} <- File.stat(expanded),
         true <- Bitwise.band(mode, 0o111) != 0 or {:error, :executable_not_executable} do
      {:ok, expanded}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :executable_invalid}
    end
  end

  defp validate_executable(_executable), do: {:error, :executable_missing}

  defp default_executable do
    System.get_env("OPENCODE_BIN") || System.find_executable("opencode")
  end

  defp default_output_root do
    Path.expand("_build/scv/runs", File.cwd!())
  end

  defp emit_event(input, type, data) do
    event =
      %{
        schema: "openagents.scv.event.v1",
        run_id: input.run_id,
        type: type,
        emitted_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }
      |> Map.merge(input.event_context)
      |> Map.merge(data)

    try do
      input.event_sink.(event)
    rescue
      _error -> :ok
    catch
      _kind, _reason -> :ok
    end

    try do
      :telemetry.execute([:openagents, :scv, :event], %{count: 1}, event)
    rescue
      _error -> :ok
    end

    :ok
  end

  defp bounded_value(value, maximum_bytes, _fallback)
       when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= maximum_bytes,
       do: value

  defp bounded_value(_value, _maximum_bytes, fallback), do: fallback

  defp byte_count(value) when is_binary(value), do: byte_size(value)
  defp byte_count(_value), do: 0

  defp redact(binary, redactions) do
    Enum.reduce(redactions, binary, fn
      value, output when is_binary(value) and value != "" ->
        :binary.replace(output, value, "[REDACTED]", [:global])

      _value, output ->
        output
    end)
  end

  defp git_sha(repository) do
    case System.find_executable("git") do
      nil ->
        nil

      executable ->
        case System.cmd(executable, ["-C", repository, "rev-parse", "HEAD"],
               stderr_to_stdout: true
             ) do
          {sha, 0} -> String.trim(sha)
          _error -> nil
        end
    end
  end

  defp digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
