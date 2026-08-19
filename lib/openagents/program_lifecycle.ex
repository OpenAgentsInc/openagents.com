defmodule OpenAgents.ProgramLifecycle do
  @moduledoc false

  def capture(_ref) do
    %OpenAgents.ProgramArtifacts.Snapshot{
      artifact: nil,
      degraded?: false,
      receipt: nil
    }
  end
end
