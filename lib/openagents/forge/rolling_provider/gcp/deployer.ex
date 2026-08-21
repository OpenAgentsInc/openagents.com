defmodule OpenAgents.Forge.RollingProvider.Gcp.Deployer do
  @moduledoc """
  Starts the minimal private BEAM node used for Google Cloud replacement calls.

  The deployer container starts this module with the release's clean boot file.
  It does not start the OpenAgents application, join Ra, open an HTTP listener,
  or connect to PostgreSQL. It starts only the dependencies needed by `Req` and
  then waits for bounded `erpc` calls from the three-node staging fleet.
  """

  @sha_pattern ~r/\A[0-9a-f]{40}\z/
  @deployer_node :"openagents-deployer@openagents-deployer.staging.internal"

  @doc false
  def start do
    expected_revision = System.fetch_env!("OPENAGENTS_CONTROLLER_SHA")

    unless Regex.match?(@sha_pattern, expected_revision) and
             expected_revision == OpenAgents.BuildInfo.revision() do
      raise "deployer image revision does not match its assigned Git SHA"
    end

    :ok = configure_provider!()
    {:ok, _applications} = Application.ensure_all_started(:req)
    Process.sleep(:infinity)
  end

  @doc false
  def configure_provider!(environment \\ System.get_env()) when is_map(environment) do
    config = [
      project_id: fetch!(environment, "OPENAGENTS_GCP_ROLLING_PROJECT_ID"),
      production_project_id: fetch!(environment, "OPENAGENTS_PRODUCTION_PROJECT_ID"),
      zone: fetch!(environment, "OPENAGENTS_GCP_ROLLING_ZONE"),
      instances: decode_instances!(environment),
      image_repository: fetch!(environment, "OPENAGENTS_GCP_IMAGE_REPOSITORY"),
      deployer_node: @deployer_node,
      rpc_timeout_ms: 5_000,
      compute_timeout_ms: 300_000
    ]

    case OpenAgents.Forge.RollingProvider.Gcp.validate_config(config) do
      :ok ->
        Application.put_env(:openagents, OpenAgents.Forge.RollingProvider.Gcp, config)

      {:error, _reason} ->
        raise ArgumentError, "staging rolling-provider configuration is invalid"
    end
  end

  defp decode_instances!(environment) do
    environment
    |> fetch!("OPENAGENTS_GCP_ROLLING_INSTANCES_JSON")
    |> Jason.decode()
    |> case do
      {:ok, instances} when is_map(instances) -> instances
      _invalid -> raise ArgumentError, "staging rolling-provider configuration is invalid"
    end
  end

  defp fetch!(environment, name) do
    case Map.fetch(environment, name) do
      {:ok, value} when is_binary(value) and value != "" -> value
      _missing -> raise ArgumentError, "staging rolling-provider configuration is invalid"
    end
  end
end
