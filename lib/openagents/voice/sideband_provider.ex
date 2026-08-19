defmodule OpenAgents.Voice.SidebandProvider do
  @moduledoc "Server-side control-channel boundary for a live voice call."

  alias OpenAgents.Voice.{Config, Session}

  @callback start_link(pid(), Session.t(), Config.t()) :: {:ok, pid()} | {:error, term()}
  @callback send_event(pid(), map()) :: :ok | {:error, term()}
  @callback close(pid()) :: :ok
end
