defmodule OpenAgents.ProgramArtifacts.Snapshot do
  @moduledoc false

  defstruct [:artifact, :degraded?, :receipt, :signature_id, :digest, :id, :reason]
end
