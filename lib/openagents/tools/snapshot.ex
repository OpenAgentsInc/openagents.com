defmodule OpenAgents.Tools.Snapshot do
  @moduledoc "Immutable catalog captured once for a Sarah turn."

  @enforce_keys [:schema, :digest, :tools, :all_tools, :modules]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          schema: String.t(),
          digest: String.t(),
          tools: %{String.t() => OpenAgents.Tools.Tool.t()},
          all_tools: %{String.t() => OpenAgents.Tools.Tool.t()},
          modules: %{{String.t(), pos_integer()} => OpenAgents.Modules.Artifact.t()}
        }
end
