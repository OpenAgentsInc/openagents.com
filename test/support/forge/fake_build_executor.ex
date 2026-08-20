defmodule OpenAgents.Forge.FakeBuildExecutor do
  @moduledoc """
  Test build executor: returns the scripted response from the
  `:fake_build_result` application env (`{:ok, build_result}` or
  `{:error, output}`).

  `beams_for/1` compiles real Elixir source so downstream tests (P4
  hot-load) get genuine loadable beams.
  """

  def build(_repo, _sha, _opts) do
    Application.get_env(:openagents, :fake_build_result) ||
      {:error, "no :fake_build_result configured"}
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
end
