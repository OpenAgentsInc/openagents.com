defmodule OpenAgents.Providers.ToolDefinition do
  @moduledoc "Provider-neutral callable tool definition captured for one request."

  @enforce_keys [:name, :description, :input_schema, :strict]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          input_schema: map(),
          strict: boolean()
        }
end
