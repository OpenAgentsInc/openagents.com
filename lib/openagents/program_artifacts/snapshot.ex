defmodule OpenAgents.ProgramArtifacts.Snapshot do
  @moduledoc "Turn-start capture of one admitted artifact or deterministic baseline."

  @enforce_keys [:signature_id, :artifact, :degraded?, :reason, :receipt]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          signature_id: String.t(),
          artifact: OpenAgents.ProgramArtifacts.Artifact.t() | nil,
          degraded?: boolean(),
          reason: String.t(),
          receipt: map()
        }
end
