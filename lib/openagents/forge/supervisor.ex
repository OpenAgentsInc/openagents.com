defmodule OpenAgents.Forge.Supervisor do
  @moduledoc "The forge's own supervision subtree (bounded-context edge, audit A6)."

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children =
      [
        {Task.Supervisor, name: OpenAgents.Forge.TaskSupervisor},
        {OpenAgents.Forge.MirrorWatch, []}
      ] ++ repository_children() ++ deploy_lane_children()

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp repository_children do
    if Application.get_env(:openagents, :repository_provisioner_enabled, true) do
      [
        {OpenAgents.Repositories.Provisioner, []},
        {OpenAgents.Repositories.ImportWorkspaceJanitor, []}
      ]
    else
      []
    end
  end

  # The deploy lane (builder + hot loader) runs in the release; tests start
  # these under their own supervision with scripted executors.
  defp deploy_lane_children do
    if Application.get_env(:openagents, :forge_deploy_lane_enabled, true) do
      [
        {OpenAgents.Forge.Builder, []},
        {OpenAgents.Forge.HotLoader, []},
        {OpenAgents.Forge.Janitor, []}
      ]
    else
      []
    end
  end
end
