defmodule OpenAgents.Forge.FakeBuildExecutor do
  @moduledoc """
  Test build executor: returns the scripted response from the
  `:fake_build_result` application env (`{:ok, build_result}` or
  `{:error, output}`).

  `beams_for/1` compiles real Elixir source so downstream tests (P4
  hot-load) get genuine loadable beams.
  """

  alias OpenAgents.Forge.BuildArtifact

  def build(repo, sha, opts) do
    case Application.get_env(:openagents, :fake_build_result) do
      {:ok, %{artifact_bytes: _bytes} = result} ->
        {:ok, result}

      {:ok, %{beams: beams} = scripted} ->
        toolchain = BuildArtifact.current_toolchain()
        baseline = Keyword.get(opts, :baseline_manifest) || synthetic_baseline(repo, toolchain)

        with {:ok, artifact} <-
               BuildArtifact.pack(repo, sha, Keyword.fetch!(opts, :build_id), beams,
                 baseline_manifest: baseline,
                 toolchain: toolchain
               ) do
          {:ok,
           %{
             artifact_bytes: artifact.bytes,
             artifact_digest: artifact.digest,
             manifest: artifact.manifest,
             beams: artifact.beams,
             warnings: Map.get(scripted, :warnings, ""),
             tests: Map.get(scripted, :tests),
             duration_ms: Map.get(scripted, :duration_ms, 1),
             output_digest: nil,
             output_ref: nil
           }}
        end

      {:error, _output} = error ->
        error

      nil ->
        {:error, "no :fake_build_result configured"}
    end
  end

  @doc "A full scripted `{:ok, build_result}` for `source` (compiled for real)."
  @spec result_for(String.t()) :: {:ok, OpenAgents.Forge.BuildExecutor.build_result()}
  def result_for(source) when is_binary(source) do
    {:ok, %{beams: beams_for(source), warnings: "", tests: nil, duration_ms: 1}}
  end

  @doc "Compile Elixir source and return `[%{module: \"Elixir...\", binary: beam}]`."
  @spec beams_for(String.t()) :: [OpenAgents.Forge.BuildExecutor.beam()]
  def beams_for(source) when is_binary(source) do
    source
    |> Code.compile_string()
    |> Enum.map(fn {module, binary} ->
      %{module: Atom.to_string(module), binary: binary}
    end)
  end

  defp synthetic_baseline(repo, toolchain) do
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
end
