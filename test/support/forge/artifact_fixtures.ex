defmodule OpenAgents.Forge.ArtifactFixtures do
  @moduledoc false

  alias OpenAgents.Forge.BuildArtifact

  def create!(repo, sha, beams, opts \\ []) do
    toolchain = Keyword.get(opts, :toolchain, BuildArtifact.current_toolchain())
    baseline = Keyword.get(opts, :baseline_manifest, baseline!(repo, toolchain))
    build_id = Keyword.get(opts, :build_id, Ecto.UUID.generate())

    normalized_beams =
      Enum.map(beams, fn
        %{module: module, binary: binary} ->
          %{module: ensure_elixir_prefix(module), binary: binary}

        {module, binary} ->
          %{module: ensure_elixir_prefix(module), binary: binary}
      end)

    {:ok, artifact} =
      BuildArtifact.pack(repo, sha, build_id, normalized_beams,
        baseline_manifest: baseline,
        toolchain: toolchain,
        structural_reasons: Keyword.get(opts, :structural_reasons, [])
      )

    Map.put(artifact, :build_id, build_id)
  end

  def write!(artifact) do
    path =
      Path.join(
        System.tmp_dir!(),
        "forge-artifact-#{System.unique_integer([:positive])}-#{artifact.digest}.tar"
      )

    File.write!(path, artifact.bytes)
    path
  end

  defp baseline!(repo, toolchain) do
    {:ok, artifact} =
      BuildArtifact.pack(
        repo,
        String.duplicate("0", 40),
        Ecto.UUID.generate(),
        [],
        toolchain: toolchain
      )

    artifact.manifest
  end

  defp ensure_elixir_prefix("Elixir." <> _rest = module), do: module
  defp ensure_elixir_prefix(module), do: "Elixir." <> module
end
