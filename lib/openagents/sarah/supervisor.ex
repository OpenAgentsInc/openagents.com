defmodule OpenAgents.Sarah.Supervisor do
  @moduledoc """
  Supervisor for the ported Sarah subsystems.

  Currently starts the local cluster registry and supervisor used by work,
  computer, and memory workers. Voice and explicit memory workers are left
  disabled behind feature flags until they are fully wired.
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Registry, keys: :unique, name: OpenAgents.HordeRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: OpenAgents.HordeSupervisor},
      {Registry, keys: :unique, name: OpenAgents.TurnRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: OpenAgents.TurnSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
