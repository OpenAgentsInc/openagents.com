defmodule OpenAgents.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Releases migrate on boot (RELEASE-001): the schema must precede traffic.
    # Ecto.Migrator.with_repo takes the migration advisory lock, so concurrent
    # fleet nodes serialize safely and an already-migrated DB is a no-op.
    if Application.get_env(:openagents, :migrate_on_boot, false) do
      OpenAgents.Release.migrate()
    end

    # Install immutable release artifacts before any traffic can reach them.
    OpenAgents.Persona.install!(OpenAgents.Persona.SourceManifest.load!())
    OpenAgents.ProgramArtifacts.install!()

    children = [
      OpenAgentsWeb.Telemetry,
      OpenAgents.Repo,
      {DNSCluster, query: Application.get_env(:openagents, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: OpenAgents.PubSub},
      OpenAgents.Sarah.Supervisor,
      # Start a worker by calling: OpenAgents.Worker.start_link(arg)
      # {OpenAgents.Worker, arg},
      # Start to serve requests, typically the last entry
      OpenAgentsWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: OpenAgents.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    OpenAgentsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
