defmodule OpenAgents.Voice.CallAdmission do
  @moduledoc "Provider-neutral result of admitting one browser WebRTC call."

  @enforce_keys [:provider_session_id, :answer_sdp]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          provider_session_id: String.t(),
          answer_sdp: String.t()
        }
end
