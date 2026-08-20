defmodule OpenAgents.ReleaseAssembler do
  @moduledoc false

  @doc false
  def pre_assemble(release), do: Forecastle.pre_assemble(release)

  @doc false
  def post_assemble(release) do
    release = Forecastle.post_assemble(release)

    case System.get_env("OPENAGENTS_RELUP_PATH") do
      nil ->
        release

      path ->
        source = Path.expand(path)

        if File.regular?(source) do
          File.cp!(source, Path.join(release.version_path, "relup"))
          release
        else
          raise "OPENAGENTS_RELUP_PATH must name a regular relup file"
        end
    end
  end
end
