defmodule OpenAgents.ProgramArtifacts.Artifact do
  @moduledoc "Immutable, language-neutral typed model-program artifact."

  @enforce_keys [:id, :signature_id, :digest, :activation_status, :predecessor, :document]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          signature_id: String.t(),
          digest: String.t(),
          activation_status: String.t(),
          predecessor: String.t() | nil,
          document: map()
        }
end
