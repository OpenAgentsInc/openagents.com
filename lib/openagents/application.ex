defmodule OpenAgents.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
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
