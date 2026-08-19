defmodule OpenAgents.Providers.ToolOutput do
  @moduledoc "Provider-neutral committed tool outcome used for continuation."

  @enforce_keys [:call_id, :output]
  defstruct @enforce_keys

  @type t :: %__MODULE__{call_id: String.t(), output: map()}
end
