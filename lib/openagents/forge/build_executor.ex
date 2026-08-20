defmodule OpenAgents.Forge.BuildExecutor do
  @moduledoc """
  Behaviour for the forge build lane: turn a promoted `{repo, sha}` into
  the set of changed `.beam` binaries for that commit.

  The production adapter is `OpenAgents.Forge.BuildExecutor.Sidecar`, which
  talks to the `sarah-builder` sidecar container through a file queue on
  the shared workspace volume. Tests use `OpenAgents.Forge.FakeBuildExecutor`.
  The adapter is selected via the `:forge_build_executor` application env
  (see `OpenAgents.Forge.Builder`).
  """

  @typedoc "One changed beam: module is the beam basename without `.beam` (`\"Elixir.Foo.Bar\"`)."
  @type beam :: %{module: String.t(), binary: binary()}

  @typedoc "A successful build: changed beams plus bounded compiler/test output."
  @type build_result :: %{
          beams: [beam()],
          warnings: String.t(),
          tests: String.t() | nil,
          duration_ms: non_neg_integer()
        }

  @callback build(repo :: String.t(), sha :: String.t(), opts :: keyword()) ::
              {:ok, build_result()} | {:error, output :: String.t()}

  @max_output_bytes 8_192

  @doc """
  Bound free-form tool output (compiler/test/git) to at most `max_bytes`
  before it is stored in receipts or target details.
  """
  @spec bound_output(String.t(), pos_integer()) :: String.t()
  def bound_output(output, max_bytes \\ @max_output_bytes) when is_binary(output) do
    if byte_size(output) <= max_bytes do
      output
    else
      binary_part(output, 0, max_bytes) <> "\n[truncated]"
    end
  end
end

defmodule OpenAgents.Forge.BuildExecutor.Sidecar do
  @moduledoc """
  Production build adapter: talks to the `sarah-builder` sidecar container
  through a file queue on the shared workspace volume. The Sarah release
  container runs unprivileged with no docker socket, so it cannot exec
  into the sidecar — the queue is the whole interface. Protocol (the
  watcher script lives in `ops/fleet/fleet-startup.sh`):

    * write `<sha>.job.tmp` then rename to `<sha>.job`, containing
      env-style `SHA=` and `REPO_URL=` lines; the URL points at the
      *local* forge (never GitHub) with the operator token embedded as
      userinfo
    * the watcher clones/fetches, checks out the SHA, compiles with
      `MIX_ENV=prod`, diffs beams against its manifest, writes the
      changed-beam tar to `<data_dir>/beams/<sha>.tar`, and answers with
      `<sha>.result` (`STATUS=ok|error`, `MODULES=`, `DURATION=` seconds)
      plus the full output in `<sha>.out`
    * this adapter polls every 2s up to `timeout_ms` (default 300_000),
      reads the beams back out of the tar, and cleans up the queue files

  The pure pieces (`render_job/2`, `parse_result/1`, `beams_from_tar/1`,
  `module_name/1`) are public and unit-tested; the queue choreography is
  thin and exercised only against the real sidecar.
  """

  @behaviour OpenAgents.Forge.BuildExecutor

  import OpenAgents.Forge.BuildExecutor, only: [bound_output: 1]

  alias OpenAgents.Forge.Repos

  @default_timeout_ms 300_000
  @poll_interval_ms 2_000

  @impl true
  def build(repo, sha, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    queue = queue_dir()
    File.mkdir_p!(queue)

    # Drop any stale answer for this sha (e.g. a previously timed-out job
    # that completed later) so we never read yesterday's result.
    File.rm(Path.join(queue, sha <> ".result"))
    File.rm(Path.join(queue, sha <> ".out"))

    job_path = Path.join(queue, sha <> ".job")
    tmp_path = job_path <> ".tmp"
    File.write!(tmp_path, render_job(sha, repo_url(repo)))
    File.rename!(tmp_path, job_path)

    await_result(queue, sha, timeout_ms, timeout_ms)
  end

  # ── pure pieces (unit-tested) ───────────────────────────────────────────

  @doc "Serialize one build job (the two env-style lines the watcher sources)."
  @spec render_job(String.t(), String.t()) :: String.t()
  def render_job(sha, repo_url) do
    "SHA=#{sha}\nREPO_URL=#{repo_url}\n"
  end

  @doc "Parse an env-style result file (`KEY=value` per line) into a map."
  @spec parse_result(String.t()) :: %{String.t() => String.t()}
  def parse_result(contents) when is_binary(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> [{key, value}]
        _other -> []
      end
    end)
    |> Map.new()
  end

  @doc "Read the changed-beam entries out of a beam tar's bytes, sorted by module."
  @spec beams_from_tar(binary()) ::
          {:ok, [OpenAgents.Forge.BuildExecutor.beam()]} | {:error, term()}
  def beams_from_tar(tar_bytes) when is_binary(tar_bytes) do
    case :erl_tar.extract({:binary, tar_bytes}, [:memory]) do
      {:ok, entries} ->
        {:ok,
         entries
         |> Enum.map(fn {name, binary} ->
           %{module: module_name(to_string(name)), binary: binary}
         end)
         |> Enum.sort_by(& &1.module)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc ~S|Module name for a beam path: `"a/Elixir.Foo.Bar.beam"` -> `"Elixir.Foo.Bar"`.|
  @spec module_name(String.t()) :: String.t()
  def module_name(path) when is_binary(path) do
    path |> Path.basename() |> String.replace_suffix(".beam", "")
  end

  # ── queue choreography (thin, integration-only) ─────────────────────────

  defp await_result(queue, sha, remaining_ms, timeout_ms) when remaining_ms <= 0 do
    File.rm(Path.join(queue, sha <> ".job"))
    {:error, "build timed out after #{timeout_ms}ms"}
  end

  defp await_result(queue, sha, remaining_ms, timeout_ms) do
    result_path = Path.join(queue, sha <> ".result")

    case File.read(result_path) do
      {:ok, contents} ->
        out = read_out(queue, sha)
        File.rm(result_path)
        File.rm(Path.join(queue, sha <> ".out"))
        finish(sha, parse_result(contents), out)

      {:error, _absent} ->
        Process.sleep(min(@poll_interval_ms, remaining_ms))
        await_result(queue, sha, remaining_ms - @poll_interval_ms, timeout_ms)
    end
  end

  defp finish(sha, %{"STATUS" => "ok"} = result, out) do
    tar_path = Path.join([Repos.data_dir(), "beams", sha <> ".tar"])

    with {:ok, tar_bytes} <- File.read(tar_path),
         {:ok, beams} <- beams_from_tar(tar_bytes) do
      {:ok, %{beams: beams, warnings: out, tests: nil, duration_ms: duration_ms(result)}}
    else
      {:error, reason} ->
        {:error, bound_output("build ok but beam tar unreadable: #{inspect(reason)}")}
    end
  end

  defp finish(_sha, _result, out), do: {:error, out}

  defp read_out(queue, sha) do
    case File.read(Path.join(queue, sha <> ".out")) do
      {:ok, contents} -> bound_output(contents)
      {:error, _absent} -> ""
    end
  end

  defp duration_ms(result) do
    case Integer.parse(result["DURATION"] || "") do
      {seconds, _rest} -> seconds * 1000
      :error -> 0
    end
  end

  # ── config ──────────────────────────────────────────────────────────────

  @doc """
  Whether this node's sidecar build workspace is warm (its incremental
  manifest exists). Used by the Builder's warm-node preference.
  """
  def warm? do
    build_dir =
      Application.get_env(:openagents, :forge_build_dir, "/var/lib/sarah/workspace/build")

    File.exists?(Path.join(build_dir, ".forge-manifest"))
  end

  defp queue_dir do
    Application.get_env(
      :openagents,
      :forge_build_queue_dir,
      "/var/lib/sarah/workspace/build-queue"
    )
  end

  defp repo_url(repo) do
    base = Application.get_env(:openagents, :forge_internal_git_url, "http://127.0.0.1:8080/git")
    uri = URI.parse(base)

    uri =
      case Application.get_env(:openagents, :forge_operator_token) do
        nil -> uri
        token -> %{uri | userinfo: "x:" <> token}
      end

    URI.to_string(uri) <> "/" <> repo <> ".git"
  end
end
