defmodule OpenAgents.ShadowPrograms.Signature do
  @moduledoc "Typed, bounded signature for a no-effect shadow decision."

  @enforce_keys [:id, :version, :input_schema, :output_schema, :baseline]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          version: pos_integer(),
          input_schema: map(),
          output_schema: map(),
          baseline: map()
        }
end
