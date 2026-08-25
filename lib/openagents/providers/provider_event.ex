defmodule OpenAgents.Providers.ProviderEvent do
  @moduledoc """
  Provider-neutral lifecycle and content events consumed by Sarah's turn runtime.

  `{:model_served, name}` is what the provider said answered, read back off the
  response rather than assumed from the request. It exists because a request
  and its answer can name different models: the Vercel AI Gateway is configured
  with a fallback list, and a primary that fails is replaced by another model
  without the request being refused. An adapter that can be substituted for
  emits this so the host prices and attributes the call against the model that
  actually served it (METER-001, PROVIDER-002).
  """

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
          | {:model_served, String.t()}
          | {:text_delta, String.t()}
          | {:reasoning_delta, String.t()}
          | {:tool_call, ToolCall.t()}
          | {:usage, map()}
          | {:response_completed, String.t()}
          | {:failed, failure_reason()}
          | :cancelled
end
