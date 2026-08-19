defmodule OpenAgents.Voice.CallProvider do
  @moduledoc "Provider boundary for exchanging a browser SDP offer for an answer."

  alias OpenAgents.Voice.{CallAdmission, Config}

  @callback create(String.t(), String.t(), Config.t()) ::
              {:ok, CallAdmission.t()} | {:error, atom() | tuple()}
end
