defmodule OpenAgents.ProgramArtifacts do
  @moduledoc "Boot-installed immutable catalog of typed model-program artifacts."

  alias OpenAgents.ProgramArtifacts.{Artifact, Reader, Snapshot}
  alias OpenAgents.Provenance.Canonical

  @persistent_key {__MODULE__, :catalog}
  @artifact_paths ["sarah/programs/memory-intent.shadow.v1.json"]
  @admitted_digests %{
    "sarah.program.memory_intent.shadow.v1" =>
      "35c030b15c57aeb43f36a8ed9ca327a6e02f9eaab8e8db82e1b598e440c4a1ea"
  }

  @type catalog :: %{
          by_id: %{String.t() => Artifact.t()},
          by_signature: %{String.t() => Artifact.t()},
          digest: String.t()
        }

  @spec install!() :: catalog()
  def install! do
    catalog = load_catalog!()
    :persistent_term.put(@persistent_key, catalog)
    catalog
  end

  @spec current!() :: catalog()
  def current! do
    case :persistent_term.get(@persistent_key, :not_installed) do
      :not_installed -> raise "Sarah program-artifact catalog is not installed"
      catalog -> catalog
    end
  end

  @spec capture(String.t()) :: Snapshot.t()
  def capture(signature_id), do: capture(current!(), signature_id)

  @spec capture(catalog(), String.t()) :: Snapshot.t()
  def capture(catalog, signature_id) when is_map(catalog) and is_binary(signature_id) do
    case Map.fetch(catalog.by_signature, signature_id) do
      {:ok, artifact} ->
        admitted_snapshot(catalog, artifact)

      :error ->
        degraded_snapshot(catalog, signature_id, "deterministic_baseline:no_admitted_artifact")
    end
  end

  @doc false
  def compile_catalog(artifacts) when is_list(artifacts) do
    with :ok <- validate_unique(artifacts, & &1.id, :duplicate_program_artifact_id),
         :ok <- validate_unique(artifacts, & &1.signature_id, :duplicate_program_signature),
         :ok <- validate_predecessors(artifacts),
         :ok <- validate_admission_digests(artifacts) do
      by_id = Map.new(artifacts, &{&1.id, &1})
      by_signature = Map.new(artifacts, &{&1.signature_id, &1})

      {:ok,
       %{
         by_id: by_id,
         by_signature: by_signature,
         digest:
           artifacts
           |> Enum.sort_by(& &1.id)
           |> Enum.map(&%{"id" => &1.id, "digest" => &1.digest})
           |> Canonical.digest!()
       }}
    end
  end

  defp load_catalog! do
    artifacts = Enum.map(@artifact_paths, &load_artifact!/1)

    case compile_catalog(artifacts) do
      {:ok, catalog} ->
        catalog

      {:error, reason} ->
        raise ArgumentError, "invalid program-artifact catalog: #{inspect(reason)}"
    end
  end

  defp load_artifact!(relative_path) do
    path = Path.join(priv_dir!(), relative_path)

    with {:ok, contents} <- File.read(path),
         {:ok, artifact} <- Reader.read(contents) do
      artifact
    else
      {:error, reason} ->
        raise ArgumentError, "invalid program artifact #{relative_path}: #{inspect(reason)}"
    end
  end

  defp validate_unique(artifacts, identity, reason) do
    identities = Enum.map(artifacts, identity)
    if length(identities) == MapSet.size(MapSet.new(identities)), do: :ok, else: {:error, reason}
  end

  defp validate_predecessors(artifacts) do
    ids = MapSet.new(artifacts, & &1.id)

    case Enum.find(artifacts, fn artifact ->
           artifact.predecessor != nil and not MapSet.member?(ids, artifact.predecessor)
         end) do
      nil -> :ok
      artifact -> {:error, {:unknown_program_predecessor, artifact.id}}
    end
  end

  defp validate_admission_digests(artifacts) do
    case Enum.find(artifacts, fn artifact -> @admitted_digests[artifact.id] != artifact.digest end) do
      nil -> :ok
      artifact -> {:error, {:program_artifact_not_admitted, artifact.id}}
    end
  end

  defp admitted_snapshot(catalog, artifact) do
    receipt = %{
      "schema" => "sarah.program_capture.v1",
      "signature_id" => artifact.signature_id,
      "artifact_id" => artifact.id,
      "artifact_digest" => artifact.digest,
      "catalog_digest" => catalog.digest,
      "activation_status" => artifact.activation_status,
      "degraded" => false,
      "reason" => "admitted_artifact_captured"
    }

    %Snapshot{
      signature_id: artifact.signature_id,
      artifact: artifact,
      degraded?: false,
      reason: receipt["reason"],
      receipt: receipt
    }
  end

  defp degraded_snapshot(catalog, signature_id, reason) do
    receipt = %{
      "schema" => "sarah.program_capture.v1",
      "signature_id" => signature_id,
      "artifact_id" => nil,
      "artifact_digest" => nil,
      "catalog_digest" => catalog.digest,
      "activation_status" => "baseline",
      "degraded" => true,
      "reason" => reason
    }

    %Snapshot{
      signature_id: signature_id,
      artifact: nil,
      degraded?: true,
      reason: reason,
      receipt: receipt
    }
  end

  defp priv_dir! do
    case :code.priv_dir(:openagents) do
      path when is_list(path) -> List.to_string(path)
      {:error, reason} -> raise "Sarah priv directory unavailable: #{inspect(reason)}"
    end
  end
end
