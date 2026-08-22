defmodule OpenAgents.Forge.RelupPackage do
  @moduledoc """
  Validates a digest-addressed relup package and deploys it to the current fleet.

  The package must match the running revision and the target node operating
  system and architecture. This prevents an operator from passing a macOS or
  ARM release to Linux/AMD64 nodes.
  """

  alias OpenAgents.Forge.RelupDeployment

  @schema "openagents.relup-package.v1"
  @sha_pattern ~r/\A[0-9a-f]{40}\z/
  @digest_pattern ~r/\A[0-9a-f]{64}\z/
  @version_pattern ~r/\A[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?\z/
  @maximum_manifest_bytes 65_536
  @maximum_artifact_bytes 536_870_912

  @doc "Validate and load the target release from a relup package directory."
  def load(directory, opts \\ [])

  def load(directory, opts) when is_binary(directory) do
    with {:ok, manifest, package_manifest_digest} <- read_manifest(directory),
         :ok <- validate_manifest(manifest, opts),
         {:ok, artifact_bytes} <- read_artifact(directory, manifest),
         :ok <- verify_artifact(artifact_bytes, manifest["to_artifact_digest"]) do
      nodes =
        Keyword.get_lazy(opts, :expected_nodes, &OpenAgents.Cluster.members/0) |> Enum.sort()

      {:ok,
       %{
         sha: manifest["to_revision"],
         from_revision: manifest["from_revision"],
         release_name: manifest["release_name"],
         from_version: manifest["from_version"],
         to_version: manifest["to_version"],
         from_state_version: manifest["from_state_version"],
         to_state_version: manifest["to_state_version"],
         artifact_bytes: artifact_bytes,
         artifact_digest: manifest["to_artifact_digest"],
         package_manifest_digest: package_manifest_digest,
         expected_nodes: nodes,
         expected_fleet_size: length(nodes)
       }}
    end
  end

  def load(_directory, _opts), do: {:error, :invalid_package_directory}

  @doc "Validate a relup package and deploy it one node at a time."
  def deploy(directory, opts \\ []) do
    started_at = System.monotonic_time(:millisecond)

    with {:ok, request} <- load(directory, opts) do
      deployment_opts =
        Keyword.drop(opts, [:current_revision, :expected_nodes, :system_architecture])

      case RelupDeployment.run(request, deployment_opts) do
        {status, result} when status in [:ok, :error] and is_map(result) ->
          {status,
           Map.put(
             result,
             :duration_ms,
             System.monotonic_time(:millisecond) - started_at
           )}

        other ->
          other
      end
    end
  end

  defp read_manifest(directory) do
    path = Path.join(directory, "package.json")

    with {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular and stat.size <= @maximum_manifest_bytes,
         {:ok, bytes} <- File.read(path),
         {:ok, manifest} <- Jason.decode(bytes) do
      {:ok, manifest, digest(bytes)}
    else
      {:error, :enoent} -> {:error, :missing_package_manifest}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_package_manifest_json}
      {:error, reason} -> {:error, {:package_manifest_unreadable, safe_code(reason)}}
      false -> {:error, :invalid_package_manifest_file}
    end
  end

  defp validate_manifest(manifest, opts) when is_map(manifest) do
    current_revision =
      Keyword.get_lazy(opts, :current_revision, fn -> OpenAgents.BuildInfo.revision() end)

    cond do
      manifest["schema"] != @schema ->
        {:error, :wrong_package_schema}

      manifest["release_name"] != "openagents" ->
        {:error, :invalid_release_name}

      not sha?(manifest["from_revision"]) ->
        {:error, :invalid_from_revision}

      not sha?(manifest["to_revision"]) ->
        {:error, :invalid_to_revision}

      manifest["from_revision"] != current_revision ->
        {:error, :running_revision_mismatch}

      not version?(manifest["from_version"]) ->
        {:error, :invalid_from_version}

      not version?(manifest["to_version"]) ->
        {:error, :invalid_to_version}

      manifest["from_version"] == manifest["to_version"] ->
        {:error, :degenerate_version_transition}

      manifest["from_state_version"] not in [1, 2] ->
        {:error, :invalid_from_state_version}

      manifest["to_state_version"] not in [1, 2] ->
        {:error, :invalid_to_state_version}

      manifest["to_state_version"] < manifest["from_state_version"] ->
        {:error, :state_version_regression}

      not digest?(manifest["to_artifact_digest"]) ->
        {:error, :invalid_target_artifact_digest}

      manifest["target_system"] != expected_system(opts) ->
        {:error, :target_system_mismatch}

      true ->
        :ok
    end
  end

  defp validate_manifest(_manifest, _opts), do: {:error, :invalid_package_manifest}

  defp read_artifact(directory, manifest) do
    filename = "openagents-#{manifest["to_version"]}.tar.gz"
    path = Path.join(directory, filename)

    with {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular and stat.size <= @maximum_artifact_bytes,
         {:ok, bytes} <- File.read(path) do
      {:ok, bytes}
    else
      {:error, :enoent} -> {:error, :missing_target_artifact}
      {:error, reason} -> {:error, {:target_artifact_unreadable, safe_code(reason)}}
      false -> {:error, :invalid_target_artifact_file}
    end
  end

  defp verify_artifact(bytes, expected_digest) do
    if digest(bytes) == expected_digest, do: :ok, else: {:error, :target_artifact_digest_mismatch}
  end

  defp expected_system(opts) do
    Keyword.get_lazy(opts, :system_architecture, fn ->
      :erlang.system_info(:system_architecture) |> to_string()
    end)
  end

  defp sha?(value), do: is_binary(value) and Regex.match?(@sha_pattern, value)
  defp digest?(value), do: is_binary(value) and Regex.match?(@digest_pattern, value)
  defp version?(value), do: is_binary(value) and Regex.match?(@version_pattern, value)
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp safe_code(reason), do: OpenAgents.OperationalLog.code(reason)
end
