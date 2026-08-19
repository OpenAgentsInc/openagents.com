defmodule OpenAgents.ProgramLifecycle do
  @moduledoc false

  def capture(_ref) do
    %OpenAgents.ProgramArtifacts.Snapshot{
      signature_id: nil,
      artifact: nil,
      degraded?: false,
      reason: nil,
      receipt: nil
    }
  end
end
