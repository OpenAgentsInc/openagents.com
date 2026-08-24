defmodule OpenAgents.Providers.ProviderEvent do
  @moduledoc "Provider-neutral lifecycle and content events consumed by Sarah's turn runtime."

  defmodule ToolCall do
    @moduledoc "A provider-requested function call awaiting host admission and validation."

    @enforce_keys [:item_id, :call_id, :name, :raw_arguments]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            item_id: String.t(),
            call_id: String.t(),
            name: String.t(),
            raw_arguments: String.t()
          }
  end

  @type failure_reason ::
          :cancelled
          | :invalid_provider_event
          | :missing_api_key
          | :missing_terminal_event
          | :truncated_stream
          | :unsupported_tool_call
          | {:http_status, pos_integer()}
          | {:provider_failed, String.t() | nil}
          | {:transport, atom()}
          | {:unexpected_provider_result, term()}

  @type t ::
          {:response_started, String.t()}
          | {:text_delta, String.t()}
          | {:reasoning_delta, String.t()}
          | {:tool_call, ToolCall.t()}
          | {:usage, map()}
          | {:response_completed, String.t()}
          | {:failed, failure_reason()}
          | :cancelled
end
