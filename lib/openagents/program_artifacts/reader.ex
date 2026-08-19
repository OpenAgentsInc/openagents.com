defmodule OpenAgents.ProgramArtifacts.Reader do
  @moduledoc false

  def digest(document) do
    :crypto.hash(:sha256, to_string(document))
  end
end
