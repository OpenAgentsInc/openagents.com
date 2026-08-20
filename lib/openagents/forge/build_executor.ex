defmodule OpenAgents.Forge.BuildExecutor do
  @moduledoc """
  Behaviour for the isolated forge build lane.

  A successful executor returns a complete, independently verified artifact;
  it does not return an unbound list of tar entries. Production uses the
  versioned JSON file protocol in `OpenAgents.Forge.BuildExecutor.Sidecar`.
  """

  @typedoc "One verified normalized BEAM, still named by a string."
  @type beam :: %{module: String.t(), binary: binary()}

  @typedoc "A successful build and its content-addressed artifact."
  @type build_result :: %{
          artifact_bytes: binary(),
          artifact_digest: String.t(),
          manifest: map(),
          beams: [beam()],
          warnings: String.t(),
          tests: String.t() | nil,
          duration_ms: non_neg_integer(),
          output_digest: String.t() | nil,
          output_ref: String.t() | nil
        }

  @type build_error ::
          String.t() | %{required(:code) => String.t(), required(:output) => String.t()}

  @callback build(repo :: String.t(), sha :: String.t(), opts :: keyword()) ::
              {:ok, build_result()} | {:error, build_error()}

  @max_output_bytes 8_192

  @doc "Bound and redact compiler, test, or git output before persistence."
  @spec bound_output(String.t(), pos_integer()) :: String.t()
  def bound_output(output, max_bytes \\ @max_output_bytes) when is_binary(output) do
    output = OpenAgents.LogSafety.redact(output)

    if byte_size(output) <= max_bytes do
      output
    else
      binary_part(output, 0, max_bytes) <> "\n[truncated]"
    end
  end
end

defmodule OpenAgents.Forge.BuildExecutor.Sidecar do
  @moduledoc """
  Production adapter for the isolated forge builder.

  The serving release atomically writes a strictly validated
  `requests/<build-id>.json`. The sidecar claims it by rename and atomically
  writes `responses/<build-id>.json`; artifacts are immutable
  `artifacts/<sha256>.tar` objects. Credentials belong only to the builder's
  mounted askpass helper or workload identity and never appear in JSON, a URL,
  argv output, or the serving release.
  """

  @behaviour OpenAgents.Forge.BuildExecutor

  import OpenAgents.Forge.BuildExecutor, only: [bound_output: 1]

  alias OpenAgents.Forge.BuildArtifact
  alias OpenAgents.Forge.BuildProtocol

  @default_timeout_ms 300_000
  @poll_interval_ms 250

  @impl true
  def build(repo, sha, opts) do
    build_id = Keyword.fetch!(opts, :build_id)
    target_id = Keyword.fetch!(opts, :target_id)

    timeout_ms =
      Keyword.get(
        opts,
        :timeout_ms,
        Application.get_env(:openagents, :forge_build_timeout_ms, @default_timeout_ms)
      )

    baseline_manifest = Keyword.get(opts, :baseline_manifest)
    queue = queue_dir()
    request_path = request_path(queue, build_id)
    response_path = response_path(queue, build_id)

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(timeout_ms, :millisecond)
      |> DateTime.to_iso8601()

    request =
      BuildProtocol.request!(%{
        build_id: build_id,
        repo: repo,
        source_sha: sha,
        target_id: target_id,
        repo_url: repo_url(repo),
        baseline_manifest: baseline_manifest,
        expires_at: expires_at
      })

    with {:ok, encoded} <- BuildProtocol.encode_request(request),
         :ok <- File.mkdir_p(Path.dirname(response_path)),
         :ok <- BuildProtocol.atomic_write(request_path, encoded, mode: 0o640) do
      await_response(request, response_path, timeout_ms, timeout_ms)
    else
      {:error, reason} ->
        {:error, %{code: "request_write_failed", output: bound_output(inspect(reason))}}
    end
  rescue
    error ->
      {:error,
       %{
         code: "request_invalid",
         output: bound_output("build request invalid: " <> Exception.message(error))
       }}
  end

  @doc "Repository URL with no embedded credential, query, or fragment."
  def repo_url(repo) do
    base = Application.get_env(:openagents, :forge_internal_git_url, "http://127.0.0.1:8080/git")
    URI.to_string(URI.parse(base)) <> "/" <> repo <> ".git"
  end

  @doc "Queue root used by both the serving adapter and builder."
  def queue_dir do
    Application.get_env(
      :openagents,
      :forge_build_queue_dir,
      "/var/lib/openagents/workspace/build-queue"
    )
  end

  @doc "Builder-owned immutable artifact and output root."
  def artifact_dir do
    Application.get_env(:openagents, :forge_artifact_dir, "/var/lib/openagents/artifacts")
  end

  @doc false
  def request_path(queue, build_id), do: Path.join([queue, "requests", build_id <> ".json"])

  @doc false
  def response_path(queue, build_id), do: Path.join([queue, "responses", build_id <> ".json"])

  defp await_response(request, _response_path, remaining_ms, timeout_ms) when remaining_ms <= 0 do
    File.rm(request_path(queue_dir(), request["build_id"]))

    {:error,
     %{
       code: "build_timeout",
       output: "build #{request["build_id"]} timed out after #{timeout_ms}ms"
     }}
  end

  defp await_response(request, response_path, remaining_ms, timeout_ms) do
    case File.read(response_path) do
      {:ok, bytes} ->
        File.rm(response_path)
        finish(request, bytes)

      {:error, :enoent} ->
        delay = min(@poll_interval_ms, remaining_ms)
        Process.sleep(delay)
        await_response(request, response_path, remaining_ms - delay, timeout_ms)

      {:error, reason} ->
        {:error, %{code: "response_read_failed", output: bound_output(inspect(reason))}}
    end
  end

  defp finish(request, response_bytes) do
    with {:ok, response} <- BuildProtocol.decode_response(response_bytes),
         true <- response["build_id"] == request["build_id"] or {:error, :build_id_mismatch} do
      case response["status"] do
        "ok" ->
          finish_ok(request, response)

        status ->
          output =
            [response["error"] || "isolated build #{status}", response["output_excerpt"]]
            |> Enum.reject(&(&1 in [nil, ""]))
            |> Enum.join("\n")

          {:error,
           %{
             code: response["error_code"] || "build_#{status}",
             output: bound_output(output),
             duration_ms: response["duration_ms"],
             output_digest: response["output_digest"],
             output_ref: response["output_ref"]
           }}
      end
    else
      {:error, reason} ->
        {:error, %{code: "invalid_response", output: bound_output(inspect(reason))}}
    end
  end

  defp finish_ok(request, response) do
    artifact_path = safe_artifact_path!(response["artifact_ref"])

    with {:ok, bytes} <- File.read(artifact_path),
         {:ok, verified} <-
           BuildArtifact.verify(bytes,
             digest: response["artifact_digest"],
             repo: request["repo"],
             source_sha: request["source_sha"],
             build_id: request["build_id"]
           ) do
      {:ok,
       %{
         artifact_bytes: bytes,
         artifact_digest: verified.digest,
         manifest: verified.manifest,
         beams: verified.beams,
         warnings: bound_output(response["output_excerpt"] || ""),
         tests: nil,
         duration_ms: response["duration_ms"],
         output_digest: response["output_digest"],
         output_ref: response["output_ref"]
       }}
    else
      {:error, reason} ->
        {:error, %{code: "artifact_verification_failed", output: bound_output(inspect(reason))}}
    end
  rescue
    error ->
      {:error,
       %{
         code: "artifact_reference_invalid",
         output: bound_output(Exception.message(error))
       }}
  end

  defp safe_artifact_path!("artifacts/" <> basename = ref) do
    if ref == "artifacts/" <> Path.basename(basename) do
      Path.join(artifact_dir(), ref)
    else
      raise ArgumentError, "unsafe artifact reference"
    end
  end

  defp safe_artifact_path!(_ref), do: raise(ArgumentError, "invalid artifact reference")
end
