defmodule OpenAgents.Tools.WorkspaceBash do
  @moduledoc """
  Runs one bounded shell command inside an explicit, noncanonical agent
  workspace.

  The command never runs against the canonical application checkout or the
  Forge data directory: the workspace root passes the same fail-closed checks
  as the workspace file tools. The child process starts with an emptied
  environment, its own session and process group, and — where the host
  supports unprivileged network namespaces — no network access. Output is
  captured as one interleaved stdout/stderr stream, redacted, and bounded to
  the last #{2_000} lines or 50 KiB; when the preview is truncated the full
  redacted output is stored as a bounded-lifetime host artifact.
  """

  @behaviour OpenAgents.Tools.Tool

  alias OpenAgents.Modules.Metadata
  alias OpenAgents.Tools.{ExecutionResult, Redaction, Tool, WorkspaceFiles}

  @default_timeout_seconds 30
  @maximum_timeout_seconds 120
  @maximum_preview_lines 2_000
  @maximum_preview_bytes 50 * 1_024
  @maximum_captured_bytes 1_024 * 1_024
  @artifact_lifetime_seconds 24 * 60 * 60
  @path "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

  @impl true
  def specification do
    %Tool{
      module_id: "openagents.tool.workspace_bash.v1",
      name: "bash",
      version: 1,
      description:
        "Runs one shell command inside the assigned agent workspace and returns its exit " <>
          "status with bounded, interleaved output.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "command" => %{"type" => "string", "maxLength" => 4_000},
          "timeout_seconds" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => @maximum_timeout_seconds
          }
        },
        "required" => ["command"],
        "additionalProperties" => false
      },
      output_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => true},
      side_effect: :reversible_write,
      required_scope: "browser_conversation",
      required_authority: "command.execute",
      executor: %{id: "openagents.workspace", disclosure: "the assigned agent workspace"},
      maintainer: "OpenAgents",
      attribution: ["OpenAgentsInc/openagents.com"],
      policy_facets: %{"privacy" => "browser_conversation", "residency" => "host"},
      module_metadata:
        Metadata.first_party("command.execute", "browser_conversation",
          effect: :reversible_write,
          privacy: "browser_conversation",
          residency: "host",
          surfaces: ["text", "voice"],
          approval_class: "exact_current_user_consent",
          approval_enforcement: "host_receipt"
        ),
      timeout_ms: (@maximum_timeout_seconds + 10) * 1_000,
      maximum_input_bytes: 8_192,
      maximum_output_bytes: 96 * 1_024,
      implementation: __MODULE__
    }
  end

  @impl true
  def execute(%{"command" => command} = arguments, context) when is_binary(command) do
    with :ok <- validate_command(command),
         {:ok, timeout_ms} <- timeout_ms(arguments),
         {:ok, workspace} <- WorkspaceFiles.resolve_root(context, :write),
         {:ok, launcher} <- launcher(workspace.root),
         {:ok, run} <-
           reserve(workspace.root, fn -> run_command(launcher, workspace, command, timeout_ms) end) do
      build_result(workspace, command, launcher, run)
    end
  end

  def execute(_arguments, _context), do: {:error, :invalid_command}

  @doc "Removes expired command-output artifacts from the host artifact store."
  def purge_expired_artifacts(now \\ DateTime.utc_now()) do
    store =
      Application.get_env(
        :openagents,
        :workspace_snapshot_dir,
        Path.join(System.tmp_dir!(), "openagents-workspace-snapshots")
      )

    with true <- is_binary(store), {:ok, entries} <- File.ls(store) do
      Enum.each(entries, fn entry ->
        directory = Path.join(store, entry)
        manifest = Path.join(directory, "manifest.json")

        with {:ok, encoded} <- File.read(manifest),
             {:ok, %{"kind" => "command_output", "expires_at" => expires_at}} <-
               Jason.decode(encoded),
             {:ok, expiry, _offset} <- DateTime.from_iso8601(expires_at),
             :lt <- DateTime.compare(expiry, now) do
          File.rm_rf(directory)
        else
          _keep -> :ok
        end
      end)
    end

    :ok
  end

  defp validate_command(command) do
    cond do
      String.trim(command) == "" -> {:error, :invalid_command}
      not String.valid?(command) -> {:error, :invalid_command}
      String.contains?(command, "\0") -> {:error, :invalid_command}
      true -> :ok
    end
  end

  defp timeout_ms(arguments) do
    case Map.get(arguments, "timeout_seconds", @default_timeout_seconds) do
      seconds when is_integer(seconds) and seconds >= 1 and seconds <= @maximum_timeout_seconds ->
        {:ok, seconds * 1_000}

      _invalid ->
        {:error, :invalid_command_timeout}
    end
  end

  # One command at a time per workspace: a second concurrent call is refused
  # instead of queued, so a stuck command cannot pile up hidden work.
  defp reserve(root, operation) do
    case :global.trans({{__MODULE__, root}, self()}, fn -> {:ok, operation.()} end, [node()], 0) do
      :aborted -> {:error, :command_concurrency_limit}
      result -> result
    end
  end

  # The launch chain is `env -i` (emptied environment), then `unshare -r -n`
  # when the host supports unprivileged network namespaces (network denied by
  # default), then `setsid -w` (own session and process group so the whole
  # tree can be cancelled, forwarding the exit status), then `sh -c`.
  defp launcher(root) do
    sh = System.find_executable("sh")
    env = System.find_executable("env")
    setsid = System.find_executable("setsid")

    if is_nil(sh) or is_nil(env) do
      {:error, :command_executor_unavailable}
    else
      {network, sandbox} = network_sandbox()

      environment = [
        "-i",
        "PATH=#{@path}",
        "HOME=#{root}",
        "LANG=C.UTF-8",
        "LC_ALL=C.UTF-8",
        "TERM=dumb"
      ]

      session = if setsid, do: [setsid, "-w"], else: []
      # The user command runs in an inner shell so that signal-terminated
      # commands surface as a conventional 128+signal exit status.
      chain = environment ++ sandbox ++ session ++ [sh, "-c", ~S(sh -c "$0")]
      {:ok, %{path: env, prefix: chain, network: network}}
    end
  end

  defp network_sandbox do
    case :persistent_term.get({__MODULE__, :network_sandbox}, :unknown) do
      :unknown ->
        sandbox = probe_network_sandbox()
        :persistent_term.put({__MODULE__, :network_sandbox}, sandbox)
        sandbox

      sandbox ->
        sandbox
    end
  end

  defp probe_network_sandbox do
    with unshare when is_binary(unshare) <- System.find_executable("unshare"),
         {_output, 0} <- System.cmd(unshare, ["-r", "-n", "true"], stderr_to_stdout: true) do
      {"denied", [unshare, "-r", "-n"]}
    else
      _unavailable -> {"unrestricted", []}
    end
  rescue
    _error -> {"unrestricted", []}
  end

  defp run_command(launcher, workspace, command, timeout_ms) do
    parent = self()

    port =
      Port.open({:spawn_executable, launcher.path}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        {:args, launcher.prefix ++ [command]},
        {:cd, workspace.root}
      ])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _closed -> nil
      end

    janitor = start_janitor(parent, os_pid)
    started = System.monotonic_time(:millisecond)
    outcome = collect(port, os_pid, [], 0, started + timeout_ms)
    send(janitor, :done)
    Map.put(outcome, :duration_ms, System.monotonic_time(:millisecond) - started)
  end

  # If the tool task is killed mid-command (host timeout or cancellation from
  # any client), the janitor outlives it and still tears down the process tree.
  defp start_janitor(parent, os_pid) do
    spawn(fn ->
      reference = Process.monitor(parent)

      receive do
        :done -> :ok
        {:DOWN, ^reference, :process, ^parent, _reason} -> kill_tree(os_pid)
      end
    end)
  end

  defp collect(port, os_pid, chunks, bytes, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        chunks = [chunk | chunks]
        bytes = bytes + byte_size(chunk)

        if bytes > @maximum_captured_bytes do
          chunks = shutdown(port, os_pid, chunks)
          %{status: :output_limited, exit_status: nil, output: captured(chunks)}
        else
          collect(port, os_pid, chunks, bytes, deadline)
        end

      {^port, {:exit_status, status}} ->
        %{status: :exited, exit_status: status, output: captured(chunks)}
    after
      remaining ->
        chunks = shutdown(port, os_pid, chunks)
        %{status: :timed_out, exit_status: nil, output: captured(chunks)}
    end
  end

  defp shutdown(port, os_pid, chunks) do
    kill_tree(os_pid)
    drain(port, chunks)
  end

  defp drain(port, chunks) do
    receive do
      {^port, {:data, chunk}} -> drain(port, [chunk | chunks])
      {^port, {:exit_status, _status}} -> chunks
    after
      2_000 ->
        close_port(port)
        chunks
    end
  end

  defp close_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Kills the spawned process and every descendant. Descendants started by
  # `setsid -w` lead their own process groups, so each group whose leader is a
  # descendant is killed as a group; the launcher's own group (shared with the
  # runtime) is never signalled.
  defp kill_tree(nil), do: :ok

  defp kill_tree(os_pid) do
    kill = System.find_executable("kill")

    if is_binary(kill) do
      descendants = descendant_pids(os_pid)

      Enum.each(descendants, fn pid ->
        _group = System.cmd(kill, ["-KILL", "--", "-#{pid}"], stderr_to_stdout: true)
      end)

      Enum.each(descendants ++ [Integer.to_string(os_pid)], fn pid ->
        _process = System.cmd(kill, ["-KILL", "--", "#{pid}"], stderr_to_stdout: true)
      end)
    end

    :ok
  end

  defp descendant_pids(os_pid) do
    case System.cmd("ps", ["-eo", "pid=,ppid="], stderr_to_stdout: true) do
      {table, 0} ->
        children =
          table
          |> String.split("\n", trim: true)
          |> Enum.reduce(%{}, fn line, acc ->
            case String.split(line) do
              [pid, ppid] -> Map.update(acc, ppid, [pid], &[pid | &1])
              _other -> acc
            end
          end)

        collect_descendants(children, [Integer.to_string(os_pid)], [])

      _failure ->
        []
    end
  end

  defp collect_descendants(_children, [], found), do: found

  defp collect_descendants(children, [pid | rest], found) do
    next = Map.get(children, pid, [])
    collect_descendants(children, next ++ rest, next ++ found)
  end

  defp captured(chunks), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()

  defp build_result(workspace, command, launcher, run) do
    output = run.output |> scrub() |> Redaction.redact_text()
    {preview, truncated} = bound_output(output)

    with {:ok, artifact} <- maybe_store_artifact(workspace, output, truncated) do
      {status, exit_code, signal} = classify(run)
      receipt = receipt(workspace, command, output)

      result =
        %{
          "schema" => "openagents.workspace_bash_result.v1",
          "command" => Redaction.redact_text(command),
          "status" => status,
          "exit_code" => exit_code,
          "signal" => signal,
          "timed_out" => run.status == :timed_out,
          "duration_ms" => run.duration_ms,
          "network" => launcher.network,
          "output" => preview,
          "output_bytes" => byte_size(output),
          "returned_bytes" => byte_size(preview),
          "truncated" => truncated,
          "artifact_ref" => artifact && artifact.ref,
          "artifact_expires_at" => artifact && artifact.expires_at,
          "workspace_ref" => workspace.ref,
          "effect_receipt" => receipt
        }

      refs = [receipt | if(artifact, do: [artifact.ref], else: [])]

      case command_error(status) do
        nil ->
          {:ok, %ExecutionResult{result: result, target_receipt_refs: refs}}

        error ->
          {:ok,
           %ExecutionResult{
             result: result,
             status: "failed",
             error: error,
             target_receipt_refs: refs
           }}
      end
    end
  end

  defp classify(%{status: :timed_out}), do: {"timed_out", nil, nil}
  defp classify(%{status: :output_limited}), do: {"output_limited", nil, nil}
  defp classify(%{exit_status: 127}), do: {"command_not_found", 127, nil}

  defp classify(%{exit_status: status}) when is_integer(status) and status > 128,
    do: {"signaled", status, status - 128}

  defp classify(%{exit_status: status}), do: {"exited", status, nil}

  defp command_error("timed_out"),
    do: %{"code" => "command_timed_out", "message" => "The command exceeded its time limit."}

  defp command_error("output_limited"),
    do: %{
      "code" => "command_output_limit",
      "message" => "The command exceeded the captured output limit."
    }

  defp command_error(_status), do: nil

  defp scrub(output) do
    if String.valid?(output) do
      output
    else
      output
      |> String.chunk(:valid)
      |> Enum.map_join(fn chunk -> if String.valid?(chunk), do: chunk, else: "\uFFFD" end)
    end
  end

  defp bound_output(output) do
    lines = String.split(output, "\n")

    preview =
      lines
      |> Enum.take(-@maximum_preview_lines)
      |> Enum.join("\n")
      |> tail_bytes(@maximum_preview_bytes)

    {preview, preview != output}
  end

  defp tail_bytes(text, limit) when byte_size(text) <= limit, do: text

  defp tail_bytes(text, limit) do
    text
    |> binary_part(byte_size(text) - limit, limit)
    |> trim_partial_prefix(3)
  end

  defp trim_partial_prefix(text, 0), do: text

  defp trim_partial_prefix(text, attempts) do
    case text do
      <<_first, rest::binary>> ->
        if String.valid?(text), do: text, else: trim_partial_prefix(rest, attempts - 1)

      _empty ->
        text
    end
  end

  defp maybe_store_artifact(_workspace, _output, false), do: {:ok, nil}

  defp maybe_store_artifact(workspace, output, true) do
    id = Ecto.UUID.generate()

    expires_at =
      DateTime.utc_now() |> DateTime.add(@artifact_lifetime_seconds) |> DateTime.to_iso8601()

    with {:ok, store} <- WorkspaceFiles.snapshot_root(workspace.root),
         directory = Path.join(store, id),
         :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- secure_write(Path.join(directory, "output"), output),
         :ok <-
           secure_write(
             Path.join(directory, "manifest.json"),
             Jason.encode!(%{
               "kind" => "command_output",
               "bytes" => byte_size(output),
               "expires_at" => expires_at,
               "workspace_ref" => workspace.ref
             })
           ) do
      _sweep = purge_expired_artifacts()
      {:ok, %{ref: "workspace-artifact:" <> id, expires_at: expires_at}}
    else
      _failure -> {:error, :workspace_artifact_failed}
    end
  end

  defp secure_write(path, content) do
    with :ok <- File.write(path, content, [:binary, :exclusive]) do
      File.chmod(path, 0o600)
    end
  end

  defp receipt(workspace, command, output) do
    identity =
      WorkspaceFiles.digest(workspace.ref <> "\0" <> command) |> binary_part(0, 24)

    "workspace-command:" <>
      identity <> ":" <> (WorkspaceFiles.digest(output) |> binary_part(0, 32))
  end
end
