defmodule OpenAgents.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    runtime_config = OpenAgents.RuntimeConfig.install!()

    # Releases migrate on boot (RELEASE-001): the schema must precede traffic.
    # Ecto.Migrator.with_repo takes the migration advisory lock, so concurrent
    # fleet nodes serialize safely and an already-migrated DB is a no-op.
    if Application.get_env(:openagents, :migrate_on_boot, false) do
      OpenAgents.Release.migrate()
    end

    # Install immutable release artifacts before any traffic can reach them.
    source_manifest = OpenAgents.Persona.SourceManifest.load!()
    _persona = OpenAgents.Persona.install!(source_manifest)
    _program_catalog = OpenAgents.ProgramArtifacts.install!()
    :ok = OpenAgents.Voice.Config.validate_boot!()

    # Build and install the tool catalog; this snapshot is passed to the
    # embedding warmer and the turn supervisor below.
    tool_modules =
      if OpenAgents.RuntimeConfig.feature_enabled?(runtime_config, :tools) do
        Application.fetch_env!(:openagents, :tools)
      else
        []
      end

    tool_snapshot = OpenAgents.Tools.Registry.install!(tool_modules)
    :ok = OpenAgents.RuntimeConfig.verify_startup!(runtime_config, tool_snapshot)

    children = [
      OpenAgentsWeb.Telemetry,
      OpenAgents.Repo,
      {DNSCluster, query: Application.get_env(:openagents, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: OpenAgents.PubSub},
      OpenAgents.RuntimeSupervisor,
      # Start a worker by calling: OpenAgents.Worker.start_link(arg)
      # {OpenAgents.Worker, arg},
      # Start to serve requests, typically the last entry
      OpenAgentsWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: OpenAgents.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Warm the tool-embedding index off the boot path: the HTTP client is up by
    # now, and if embeddings are disabled this is an immediate no-op. Tool
    # selection falls back to lexical until (and if) the index is warm, so a
    # cold or failed warm never blocks or breaks a turn.
    #
    # Changelog backfill is likewise idempotent and non-blocking.
    case result do
      {:ok, _pid} ->
        Task.start(fn -> OpenAgents.Tools.Embeddings.warm(tool_snapshot) end)
        Task.start(fn -> OpenAgents.Changelog.Backfill.boot() end)

      _error ->
        :ok
    end

    result
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    OpenAgentsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
