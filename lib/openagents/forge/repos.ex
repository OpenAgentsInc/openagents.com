defmodule OpenAgents.Forge.Repos do
  @moduledoc false

  def bare_path(_repo) do
    Path.join(System.tmp_dir!(), "openagents-forge-bare")
  end
end
