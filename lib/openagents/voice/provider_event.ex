defmodule OpenAgents.Voice.ProviderEvent do
  @moduledoc "Provider-neutral Realtime event admitted by Sarah's voice adapter."

  @enforce_keys [:kind, :provider_event_id, :payload]
  defstruct @enforce_keys

  @type kind ::
          :session_created
          | :session_ready
          | :sideband_connected
          | :sideband_disconnected
          | :speech_started
          | :speech_stopped
          | :response_started
          | :response_cancelled
          | :user_transcript_delta
          | :user_transcript_final
          | :assistant_transcript_delta
          | :assistant_transcript_final
          | :tool_call_requested
          | :response_completed
          | :provider_error

  @type t :: %__MODULE__{
          kind: kind(),
          provider_event_id: String.t() | nil,
          payload: map()
        }
end
