defmodule OpenAgents.Providers.Request do
  @moduledoc "Provider-neutral input frozen for one Sarah inference."

  @enforce_keys [:model_id, :instructions, :input]
  defstruct @enforce_keys ++ [tool_definitions: [], tool_outputs: [], previous_response_id: nil]

  @typedoc """
  A prior tool call an assistant turn carried, so a continuation request can
  replay the call the outputs in `tool_outputs` answer. `arguments` is the raw
  JSON string the provider produced; it is replayed, never interpreted.
  """
  @type message_tool_call :: %{call_id: String.t(), name: String.t(), arguments: String.t()}

  @type message :: %{
          :role => String.t(),
          :content => String.t(),
          optional(:tool_calls) => [message_tool_call()]
        }
  @type t :: %__MODULE__{
          model_id: String.t(),
          instructions: String.t(),
          input: [message()],
          tool_definitions: [OpenAgents.Providers.ToolDefinition.t()],
          tool_outputs: [OpenAgents.Providers.ToolOutput.t()],
          previous_response_id: String.t() | nil
        }
end
