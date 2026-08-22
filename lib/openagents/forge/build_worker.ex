defmodule OpenAgents.Forge.BuildWorker do
  @moduledoc """
  Isolated sidecar worker for versioned forge build requests.

  This module runs in the builder container, not in the serving release. It
  claims requests by atomic rename, checks out the exact pushed commit in a
  fresh workspace, invokes the pinned production toolchain without a shell,
  retains full output in an operator-only file, and publishes a verified
  content-addressed artifact and response through atomic renames.
  """

  alias OpenAgents.Forge.BuildArtifact
  alias OpenAgents.Forge.BuildProtocol

  @poll_ms 250
  @max_command_excerpt 8_192
  @default_output_retention_ms 7 * 24 * 60 * 60 * 1000

  @doc "Run the worker forever. Intended as the sidecar container entrypoint."
  def run do
    queue = required_env!("OPENAGENTS_FORGE_BUILD_QUEUE_DIR")
    artifacts = required_env!("OPENAGENTS_FORGE_ARTIFACT_DIR")
    builds = required_env!("OPENAGENTS_FORGE_BUILD_DIR")
    ensure_builder_paths!(queue, artifacts, builds)
    seed_cache!(builds, System.get_env("OPENAGENTS_FORGE_BUILD_CACHE_SEED_DIR") || File.cwd!())
    loop(queue, artifacts, builds)
  end

  @doc "Claim and process at most one request. Public for protocol integration tests."
  def run_once(queue, artifacts, builds, opts \\ []) do
    ensure_builder_paths!(queue, artifacts, builds)
    expire_outputs(artifacts, opts)
    expire_abandoned(queue)

    queue
    |> request_files()
    |> Enum.find_value(:idle, fn request_path ->
      case claim(request_path, queue) do
        {:ok, running_path} ->
          process_claim(running_path, queue, artifacts, builds, opts)
          :processed

        :lost_race ->
          false
      end
    end)
  end

  defp loop(queue, artifacts, builds) do
    case run_once(queue, artifacts, builds) do
      :idle -> Process.sleep(@poll_ms)
      :processed -> :ok
    end

    loop(queue, artifacts, builds)
  end

  defp process_claim(running_path, queue, artifacts, builds, opts) do
    started = System.monotonic_time(:millisecond)

    response =
      with {:ok, request_bytes} <- File.read(running_path),
           {:ok, request} <- BuildProtocol.decode_request(request_bytes),
           :ok <- ensure_not_expired(request) do
        execute(request, artifacts, builds, started, opts)
      else
        {:error, reason} ->
          build_id = build_id_from_path(running_path)
          BuildProtocol.error_response(build_id, "error", error_code(reason), inspect(reason))
      end

    write_response(queue, response)
  after
    File.rm(running_path)
  end

  defp execute(request, artifacts, builds, started, opts) do
    build_id = request["build_id"]
    workspace = workspace_path(builds, request["repo"])
    output_tmp = Path.join([artifacts, "output", ".#{build_id}.tmp"])

    try do
      File.rm_rf(workspace)
      File.mkdir_p!(workspace)
      File.mkdir_p!(Path.dirname(output_tmp))
      File.write!(output_tmp, "", [:binary])
      File.chmod!(output_tmp, 0o600)

      result =
        with {:ok, beams, toolchain, structural_reasons} <-
               prepare_candidate(request, workspace, builds, output_tmp, opts),
             {:ok, artifact} <-
               BuildArtifact.pack(
                 request["repo"],
                 request["source_sha"],
                 build_id,
                 beams,
                 baseline_manifest: request["baseline_manifest"],
                 toolchain: toolchain,
                 structural_reasons: structural_reasons
               ),
             :ok <- store_artifact(artifacts, artifact) do
          {:ok, artifact}
        end

      {output_ref, output_digest} = finalize_output!(artifacts, build_id, output_tmp)
      output_excerpt = output_excerpt(artifacts, output_ref)
      duration_ms = System.monotonic_time(:millisecond) - started

      case result do
        {:ok, artifact} ->
          BuildProtocol.ok_response(build_id, %{
            artifact_digest: artifact.digest,
            artifact_ref: "artifacts/#{artifact.digest}.tar",
            output_digest: output_digest,
            output_ref: output_ref,
            output_excerpt: output_excerpt,
            duration_ms: duration_ms
          })

        {:error, reason} ->
          BuildProtocol.error_response(build_id, "error", error_code(reason), inspect(reason), %{
            output_digest: output_digest,
            output_ref: output_ref,
            output_excerpt: output_excerpt,
            duration_ms: duration_ms
          })
      end
    rescue
      error ->
        duration_ms = System.monotonic_time(:millisecond) - started

        {output_ref, output_digest} =
          finalize_output_after_crash(
            artifacts,
            build_id,
            output_tmp,
            Exception.format(:error, error)
          )

        output_excerpt = output_excerpt(artifacts, output_ref)

        BuildProtocol.error_response(
          build_id,
          "error",
          "worker_crashed",
          Exception.message(error),
          %{
            output_digest: output_digest,
            output_ref: output_ref,
            output_excerpt: output_excerpt,
            duration_ms: duration_ms
          }
        )
    after
      File.rm_rf(workspace)
    end
  end

  defp prepare_candidate(request, workspace, builds, output, opts) do
    case Keyword.get(opts, :build_fun) do
      build_fun when is_function(build_fun, 2) ->
        case build_fun.(request, workspace) do
          {:ok, beams, toolchain, structural_reasons, retained_output} ->
            File.write!(output, retained_output, [:append, :binary])
            {:ok, beams, toolchain, structural_reasons}

          {:error, _reason} = error ->
            error
        end

      nil ->
        prepare_production_candidate(request, workspace, builds, output, opts)

      _invalid ->
        {:error, :invalid_build_fun}
    end
  end

  defp prepare_production_candidate(request, workspace, builds, output, opts) do
    cache = cache_paths(builds)

    with {:ok, env} <- command_env(opts),
         env =
           [
             {"MIX_BUILD_PATH", cache.build},
             {"MIX_DEPS_PATH", cache.deps}
           ] ++ env,
         :ok <- run_ok("git", ["init", "--quiet", workspace], builds, env, output),
         :ok <-
           run_ok(
             "git",
             ["remote", "add", "origin", request["repo_url"]],
             workspace,
             env,
             output
           ),
         :ok <- fetch_source(request, workspace, env, output),
         :ok <- checkout_exact(request, workspace, env, output),
         {:ok, structural_reasons} <- source_classification(request, workspace, env, output),
         :ok <-
           run_ok(
             "mix",
             ["deps.get", "--only", "prod", "--check-locked"],
             workspace,
             [{"MIX_ENV", "prod"} | env],
             output
           ),
         :ok <-
           run_ok(
             "mix",
             ["compile", "--warnings-as-errors"],
             workspace,
             [{"MIX_ENV", "prod"} | env],
             output
           ),
         {:ok, beams} <- read_candidate_beams(cache.build) do
      toolchain =
        BuildArtifact.current_toolchain(
          lock_path: Path.join(workspace, "mix.lock"),
          app_file: Path.join(cache.build, "lib/openagents/ebin/openagents.app")
        )

      {:ok, beams, toolchain, structural_reasons}
    end
  end

  defp fetch_source(request, workspace, env, output) do
    baseline_sha = get_in(request, ["baseline_manifest", "source_sha"])

    with :ok <-
           run_ok(
             "git",
             ["fetch", "--no-tags", "--depth=1", "origin", request["source_sha"]],
             workspace,
             env,
             output
           ),
         :ok <- fetch_baseline(baseline_sha, request["source_sha"], workspace, env, output) do
      :ok
    end
  end

  defp fetch_baseline(nil, _source_sha, _workspace, _env, _output), do: :ok
  defp fetch_baseline(source_sha, source_sha, _workspace, _env, _output), do: :ok

  defp fetch_baseline(baseline_sha, _source_sha, workspace, env, output) do
    run_ok(
      "git",
      ["fetch", "--no-tags", "--depth=1", "origin", baseline_sha],
      workspace,
      env,
      output
    )
  end

  defp checkout_exact(request, workspace, env, output) do
    with :ok <-
           run_ok(
             "git",
             ["checkout", "--quiet", "--detach", request["source_sha"]],
             workspace,
             env,
             output
           ),
         {:ok, actual} <- run_command("git", ["rev-parse", "HEAD"], workspace, env, output),
         true <- String.trim(actual) == request["source_sha"] or {:error, :checkout_mismatch} do
      :ok
    end
  end

  defp source_classification(%{"baseline_manifest" => nil}, _workspace, _env, _output),
    do: {:ok, ["baseline_missing"]}

  defp source_classification(request, workspace, env, output) do
    baseline_sha = request["baseline_manifest"]["source_sha"]

    with {:ok, diff} <-
           run_command(
             "git",
             ["diff", "--name-only", "#{baseline_sha}..#{request["source_sha"]}"],
             workspace,
             env,
             output
           ) do
      reasons =
        diff
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&structural_reason/1)
        |> Enum.uniq()
        |> Enum.sort()

      {:ok, reasons}
    end
  end

  defp structural_reason("mix.lock"), do: ["dependency_lock_changed"]
  defp structural_reason("mix.exs"), do: ["dependency_definition_changed"]
  defp structural_reason("Dockerfile"), do: ["runtime_image_changed"]
  defp structural_reason("Dockerfile." <> _suffix), do: ["runtime_image_changed"]
  defp structural_reason("config/" <> _path), do: ["config_changed"]
  defp structural_reason("assets/" <> _path), do: ["assets_changed"]
  defp structural_reason("priv/static/" <> _path), do: ["assets_changed"]
  defp structural_reason("priv/repo/migrations/" <> _path), do: ["migration_changed"]
  defp structural_reason("rel/" <> _path), do: ["release_changed"]
  defp structural_reason("native/" <> _path), do: ["nif_changed"]
  defp structural_reason("c_src/" <> _path), do: ["nif_changed"]

  defp structural_reason(path) do
    cond do
      String.ends_with?(path, [".so", ".nif", ".dll", ".dylib"]) -> ["nif_changed"]
      true -> []
    end
  end

  defp read_candidate_beams(build_path) do
    paths = Path.wildcard(Path.join(build_path, "lib/openagents/ebin/*.beam"))

    if paths == [] do
      {:error, :application_beams_missing}
    else
      paths
      |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
        module = Path.basename(path, ".beam")

        case File.read(path) do
          {:ok, binary} -> {:cont, {:ok, [%{module: module, binary: binary} | acc]}}
          {:error, reason} -> {:halt, {:error, {:beam_read_failed, reason}}}
        end
      end)
      |> case do
        {:ok, beams} -> {:ok, Enum.sort_by(beams, & &1.module)}
        error -> error
      end
    end
  end

  defp run_ok(executable, args, cwd, env, output) do
    case run_command(executable, args, cwd, env, output) do
      {:ok, _excerpt} -> :ok
      {:error, reason, _excerpt} -> {:error, reason}
    end
  end

  defp run_command(executable, args, cwd, env, output) do
    case System.find_executable(executable) do
      nil ->
        {:error, {:executable_missing, executable}, ""}

      path ->
        {:ok, io} = File.open(output, [:append, :binary])

        try do
          port =
            Port.open(
              {:spawn_executable, String.to_charlist(path)},
              [
                :binary,
                :exit_status,
                :stderr_to_stdout,
                args: Enum.map(args, &String.to_charlist/1),
                cd: String.to_charlist(cwd),
                env: Enum.map(env, fn {key, value} -> {to_charlist(key), to_charlist(value)} end)
              ]
            )

          collect_port(port, io, "")
        after
          File.close(io)
        end
    end
  rescue
    error -> {:error, {:command_crashed, executable, Exception.message(error)}, ""}
  end

  defp collect_port(port, io, excerpt) do
    receive do
      {^port, {:data, data}} ->
        :ok = IO.binwrite(io, data)
        collect_port(port, io, append_excerpt(excerpt, data))

      {^port, {:exit_status, 0}} ->
        {:ok, excerpt}

      {^port, {:exit_status, status}} ->
        {:error, {:command_failed, status}, excerpt}
    after
      600_000 ->
        Port.close(port)
        {:error, :command_timeout, excerpt}
    end
  end

  defp append_excerpt(excerpt, data) do
    remaining = @max_command_excerpt - byte_size(excerpt)

    if remaining > 0,
      do: excerpt <> binary_part(data, 0, min(remaining, byte_size(data))),
      else: excerpt
  end

  defp command_env(opts) do
    askpass = Keyword.get(opts, :askpass, System.get_env("OPENAGENTS_FORGE_GIT_ASKPASS"))
    base = [{"GIT_TERMINAL_PROMPT", "0"}, {"GIT_CONFIG_NOSYSTEM", "1"}]

    case askpass do
      nil ->
        {:ok, base}

      path when is_binary(path) ->
        with true <- Path.type(path) == :absolute or {:error, :askpass_not_absolute},
             {:ok, %{type: :regular, mode: mode}} <- File.stat(path),
             true <- Bitwise.band(mode, 0o111) != 0 or {:error, :askpass_not_executable} do
          {:ok, [{"GIT_ASKPASS", path} | base]}
        else
          {:error, _reason} = error -> error
          _other -> {:error, :invalid_askpass}
        end
    end
  end

  defp store_artifact(artifacts, artifact) do
    path = Path.join([artifacts, "artifacts", artifact.digest <> ".tar"])

    case BuildProtocol.atomic_write(path, artifact.bytes, mode: 0o444) do
      :ok ->
        :ok

      {:error, :destination_exists} ->
        with {:ok, existing} <- File.read(path),
             true <-
               BuildArtifact.digest(existing) == artifact.digest or
                 {:error, :artifact_digest_collision} do
          :ok
        end

      {:error, reason} ->
        {:error, {:artifact_write_failed, reason}}
    end
  end

  defp finalize_output!(artifacts, build_id, tmp) do
    ref = "output/#{build_id}.log"
    final = Path.join(artifacts, ref)
    File.mkdir_p!(Path.dirname(final))
    File.rm(final)
    File.rename!(tmp, final)
    File.chmod!(final, 0o600)
    {ref, digest_file!(final)}
  end

  defp finalize_output_after_crash(artifacts, build_id, tmp, crash_output) do
    File.mkdir_p!(Path.dirname(tmp))
    File.write!(tmp, crash_output, [:append, :binary])
    finalize_output!(artifacts, build_id, tmp)
  rescue
    _error -> {nil, nil}
  end

  defp digest_file!(path) do
    context =
      path
      |> File.stream!(64 * 1_024, [])
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))

    context |> :crypto.hash_final() |> Base.encode16(case: :lower)
  end

  defp output_excerpt(_artifacts, nil), do: ""

  defp output_excerpt(artifacts, ref) do
    path = Path.join(artifacts, ref)

    with {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        case IO.binread(io, @max_command_excerpt) do
          :eof -> ""
          {:error, _reason} -> ""
          excerpt -> bound_redacted_excerpt(excerpt)
        end
      after
        File.close(io)
      end
    else
      {:error, _reason} -> ""
    end
  end

  defp bound_redacted_excerpt(excerpt) do
    redacted = OpenAgents.LogSafety.redact(excerpt)

    if byte_size(redacted) <= @max_command_excerpt,
      do: redacted,
      else: binary_part(redacted, 0, @max_command_excerpt)
  end

  defp write_response(queue, response) do
    with {:ok, encoded} <- BuildProtocol.encode_response(response) do
      BuildProtocol.atomic_write(
        Path.join([queue, "responses", response["build_id"] <> ".json"]),
        encoded,
        mode: 0o640,
        inherit_parent_owner: true
      )
    end
  end

  defp claim(request_path, queue) do
    running_path = Path.join([queue, "running", Path.basename(request_path)])
    File.mkdir_p!(Path.dirname(running_path))

    case File.rename(request_path, running_path) do
      :ok -> {:ok, running_path}
      {:error, :enoent} -> :lost_race
      {:error, :eexist} -> :lost_race
      {:error, reason} -> raise "build request claim failed: #{inspect(reason)}"
    end
  end

  defp expire_abandoned(queue) do
    queue
    |> Path.join("running/*.json")
    |> Path.wildcard()
    |> Enum.each(fn path ->
      with {:ok, bytes} <- File.read(path),
           {:ok, request} <- BuildProtocol.decode_request(bytes),
           {:error, :request_expired} <- ensure_not_expired(request) do
        response =
          BuildProtocol.error_response(
            request["build_id"],
            "expired",
            "abandoned_build_expired",
            "builder did not complete before the request expiry"
          )

        write_response(queue, response)
        File.rm(path)
      else
        _active_or_malformed -> :ok
      end
    end)
  end

  defp ensure_not_expired(request) do
    {:ok, expiry, 0} = DateTime.from_iso8601(request["expires_at"])

    if DateTime.compare(DateTime.utc_now(), expiry) == :lt,
      do: :ok,
      else: {:error, :request_expired}
  end

  defp request_files(queue) do
    queue |> Path.join("requests/*.json") |> Path.wildcard() |> Enum.sort()
  end

  defp expire_outputs(artifacts, opts) do
    retention_ms = output_retention_ms(opts)
    now_ms = System.system_time(:millisecond)

    artifacts
    |> Path.join("output/*.log")
    |> Path.wildcard()
    |> Enum.each(fn path ->
      case File.stat(path, time: :posix) do
        {:ok, %{mtime: mtime}} when now_ms - mtime * 1000 > retention_ms -> File.rm(path)
        _active_or_unreadable -> :ok
      end
    end)
  end

  defp output_retention_ms(opts) do
    Keyword.get_lazy(opts, :output_retention_ms, fn ->
      case Integer.parse(System.get_env("OPENAGENTS_FORGE_BUILD_OUTPUT_RETENTION_MS") || "") do
        {value, ""} when value >= 86_400_000 -> value
        _invalid_or_missing -> @default_output_retention_ms
      end
    end)
  end

  defp build_id_from_path(path), do: path |> Path.basename(".json")

  # Mix records source paths in compiler manifests and BEAM line tables. A
  # build-ID workspace changes those paths on every attempt, which makes an
  # unchanged module look different and defeats direct-diff classification.
  # Each sidecar processes requests serially, so a repository-scoped stable
  # path preserves isolation between repositories and stable BEAM identities.
  defp workspace_path(builds, repo) do
    identity = :sha256 |> :crypto.hash(repo) |> Base.encode16(case: :lower)
    Path.join([builds, "jobs", "repo-" <> identity])
  end

  defp error_code(reason) do
    reason
    |> case do
      atom when is_atom(atom) -> Atom.to_string(atom)
      {atom, _rest} when is_atom(atom) -> Atom.to_string(atom)
      _other -> "build_failed"
    end
    |> String.replace(~r/[^a-z0-9_]/, "_")
    |> String.slice(0, 128)
  end

  defp ensure_builder_paths!(queue, artifacts, builds) do
    Enum.each([queue, artifacts, builds], fn path ->
      unless Path.type(path) == :absolute do
        raise ArgumentError, "builder paths must be absolute"
      end
    end)

    for path <- [
          Path.join(queue, "requests"),
          Path.join(queue, "running"),
          Path.join(queue, "responses"),
          Path.join(artifacts, "artifacts"),
          Path.join(artifacts, "output"),
          Path.join(builds, "jobs"),
          cache_paths(builds).build,
          cache_paths(builds).deps
        ],
        do: File.mkdir_p!(path)
  end

  @doc false
  def cache_paths(builds) do
    %{
      build: Path.join([builds, "cache", "_build", "prod"]),
      deps: Path.join([builds, "cache", "deps"])
    }
  end

  @doc false
  def seed_cache!(builds, source_root) do
    cache = cache_paths(builds)
    marker = Path.join([builds, "cache", ".seeded"])

    unless File.exists?(marker) do
      copy_cache_entries(Path.join([source_root, "_build", "prod"]), cache.build)
      copy_cache_entries(Path.join(source_root, "deps"), cache.deps)
      File.write!(marker, "seeded\n")
    end

    :ok
  end

  defp copy_cache_entries(source, destination) do
    if File.dir?(source) do
      source
      |> File.ls!()
      |> Enum.each(fn entry ->
        File.cp_r!(Path.join(source, entry), Path.join(destination, entry))
      end)
    end
  end

  defp required_env!(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _missing -> raise ArgumentError, "#{name} is required"
    end
  end
end
