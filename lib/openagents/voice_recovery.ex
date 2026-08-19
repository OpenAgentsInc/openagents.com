defmodule OpenAgents.VoiceRecovery do
  @moduledoc false

  use GenServer

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(options) do
    recovery = Keyword.get(options, :recovery, &OpenAgents.Voice.recover_interrupted_sessions/0)
    :ok = recovery.()
    :ignore
  end
end
