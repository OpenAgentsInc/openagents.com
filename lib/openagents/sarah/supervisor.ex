defmodule OpenAgents.Sarah.Supervisor do
  @moduledoc """
  Placeholder supervisor for the Sarah subsystems that are being lifted
  into OpenAgents. It starts empty until the conversation, memory, voice,
  and work contexts are ported in later phases.
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # Children are added phase by phase as the Sarah subsystems are lifted.
    # Keeping the supervisor empty keeps the foundation build green while the
    # chat, memory, voice, and work modules are re-namespaced and merged.
    Supervisor.init([], strategy: :one_for_one)
  end
end
