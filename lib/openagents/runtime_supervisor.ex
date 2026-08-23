defmodule OpenAgents.RuntimeSupervisor do
  @moduledoc """
  Supervisor for the integrated OpenAgents runtime subsystems.

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
    children =
      [
        {Horde.Registry,
         name: OpenAgents.HordeRegistry,
         keys: :unique,
         members: :auto,
         delta_crdt_options: [sync_interval: 150]},
        {Horde.DynamicSupervisor,
         name: OpenAgents.HordeSupervisor,
         strategy: :one_for_one,
         members: :auto,
         process_redistribution: :passive,
         delta_crdt_options: [sync_interval: 150]},
        {Registry, keys: :unique, name: OpenAgents.TurnRegistry},
        {Registry, keys: :unique, name: OpenAgents.Chat.RunRegistry},
        {DynamicSupervisor, strategy: :one_for_one, name: OpenAgents.TurnSupervisor},
        {Registry, keys: :unique, name: OpenAgents.VoiceSessionRegistry},
        {DynamicSupervisor, strategy: :one_for_one, name: OpenAgents.VoiceSessionSupervisor},
        {DynamicSupervisor, strategy: :one_for_one, name: OpenAgents.SCV.CodexRunSupervisor},
        OpenAgents.SCV.Activity,
        OpenAgents.Leaderboard.Server,
        {Task.Supervisor, name: OpenAgents.ProviderTaskSupervisor},
        {Task.Supervisor, name: OpenAgents.ToolTaskSupervisor},
        {Task.Supervisor, name: OpenAgents.ShadowProgramTaskSupervisor},
        # The fake provider's bookkeeping owns its tables from a supervised
        # process, so a worker crash cannot lose the record of what the
        # provider already did. It deploys nothing on its own.
        OpenAgents.Deployments.Providers.Fake
      ] ++
        maybe_scv_execution_reaper() ++
        maybe_forge() ++
        maybe_semantic_worker() ++
        maybe_turn_recovery() ++
        maybe_work_recovery() ++
        maybe_voice_recovery() ++
        maybe_voice_retention() ++
        maybe_deployment_control_plane() ++
        maybe_ra_bootstrap()

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp maybe_scv_execution_reaper do
    if Application.fetch_env!(:openagents, :scv_codex)[:execution_reaper_enabled] do
      [OpenAgents.SCV.ExecutionReaper]
    else
      []
    end
  end

  defp maybe_forge do
    if OpenAgents.RuntimeConfig.feature_enabled?(:forge) do
      [OpenAgents.Forge.Supervisor]
    else
      []
    end
  end

  # The control plane's API is always available; its executing worker is gated,
  # because a host that should not run tenant deployments must not claim a run.
  defp maybe_deployment_control_plane do
    if OpenAgents.RuntimeConfig.feature_enabled?(:deployment_control_plane) do
      [OpenAgents.Deployments.Worker]
    else
      []
    end
  end

  defp maybe_semantic_worker do
    if OpenAgents.RuntimeConfig.feature_enabled?(:semantic_memory) do
      [OpenAgents.Memory.SemanticWorker]
    else
      []
    end
  end

  defp maybe_turn_recovery do
    if OpenAgents.RuntimeConfig.feature_enabled?(:turn_recovery) do
      [OpenAgents.TurnRecovery]
    else
      []
    end
  end

  defp maybe_work_recovery do
    if OpenAgents.RuntimeConfig.feature_enabled?(:work_workers) do
      [OpenAgents.WorkRecovery]
    else
      []
    end
  end

  defp maybe_voice_recovery do
    if OpenAgents.RuntimeConfig.feature_enabled?(:voice_recovery) do
      [OpenAgents.VoiceRecovery]
    else
      []
    end
  end

  defp maybe_voice_retention do
    if OpenAgents.RuntimeConfig.feature_enabled?(:voice) and
         OpenAgents.RuntimeConfig.feature_enabled?(:voice_retention) do
      [OpenAgents.Voice.Retention]
    else
      []
    end
  end

  defp maybe_ra_bootstrap do
    if OpenAgents.RuntimeConfig.feature_enabled?(:ra) do
      [OpenAgents.Cluster.RaBootstrap]
    else
      []
    end
  end
end
