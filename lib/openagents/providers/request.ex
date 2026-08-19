defmodule OpenAgents.Providers.Request do
  @moduledoc "Provider-neutral input frozen for one Sarah inference."

  @enforce_keys [:model_id, :instructions, :input]
  defstruct @enforce_keys ++ [tool_definitions: [], tool_outputs: [], previous_response_id: nil]

  @type message :: %{role: String.t(), content: String.t()}
  @type t :: %__MODULE__{
          model_id: String.t(),
          instructions: String.t(),
          input: [message()],
          tool_definitions: [OpenAgents.Providers.ToolDefinition.t()],
          tool_outputs: [OpenAgents.Providers.ToolOutput.t()],
          previous_response_id: String.t() | nil
        }
end
