defmodule OpenAgents.Sarah.Supervisor do
  @moduledoc """
  Supervisor for the ported Sarah subsystems.

  Starts the registries and supervisors used by turns, work, voice, and
  memory workers. Heavy recovery and retention workers are gated by feature
  flags so tests are not burdened by them by default.
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # The turn path and any tool-execution path require the host tool catalog
    # to be installed in :persistent_term before they run.
    _tool_snapshot =
      OpenAgents.Tools.Registry.install!(Application.fetch_env!(:openagents, :tools))

    children =
      [
        {Registry, keys: :unique, name: OpenAgents.HordeRegistry},
        {DynamicSupervisor, strategy: :one_for_one, name: OpenAgents.HordeSupervisor},
        {Registry, keys: :unique, name: OpenAgents.TurnRegistry},
        {DynamicSupervisor, strategy: :one_for_one, name: OpenAgents.TurnSupervisor},
        {Registry, keys: :unique, name: OpenAgents.VoiceSessionRegistry},
        {DynamicSupervisor, strategy: :one_for_one, name: OpenAgents.VoiceSessionSupervisor},
        OpenAgents.Leaderboard.Server,
        {Task.Supervisor, name: OpenAgents.ProviderTaskSupervisor},
        {Task.Supervisor, name: OpenAgents.ToolTaskSupervisor},
        {Task.Supervisor, name: OpenAgents.ShadowProgramTaskSupervisor},
        OpenAgents.Forge.BootConverge
      ] ++
        maybe_forge() ++
        maybe_semantic_worker() ++
        maybe_turn_recovery() ++
        maybe_work_recovery() ++
        maybe_voice_recovery() ++
        maybe_voice_retention() ++
        maybe_ra_bootstrap()

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp maybe_forge do
    if Application.get_env(:openagents, :forge_enabled, false) do
      [OpenAgents.Forge.Supervisor]
    else
      []
    end
  end

  defp maybe_semantic_worker do
    if Application.get_env(:openagents, :semantic_index, enabled: false)[:enabled] do
      [OpenAgents.Memory.SemanticWorker]
    else
      []
    end
  end

  defp maybe_turn_recovery do
    if Application.get_env(:openagents, :turn_recovery_enabled, false) do
      [OpenAgents.TurnRecovery]
    else
      []
    end
  end

  defp maybe_work_recovery do
    if Application.get_env(:openagents, :work, enabled: false)[:enabled] do
      [OpenAgents.WorkRecovery]
    else
      []
    end
  end

  defp maybe_voice_recovery do
    if Application.get_env(:openagents, :voice, enabled: false)[:enabled] do
      [OpenAgents.VoiceRecovery]
    else
      []
    end
  end

  defp maybe_voice_retention do
    if Application.get_env(:openagents, :voice, enabled: false)[:enabled] and
         Application.get_env(:openagents, :voice_retention_enabled, false) do
      [OpenAgents.Voice.Retention]
    else
      []
    end
  end

  defp maybe_ra_bootstrap do
    if Application.get_env(:openagents, :ra_enabled, false) do
      [OpenAgents.Cluster.RaBootstrap]
    else
      []
    end
  end
end
