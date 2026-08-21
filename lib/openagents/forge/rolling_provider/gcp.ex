defmodule OpenAgents.Forge.RollingProvider.Gcp do
  @moduledoc """
  Implements rolling replacement for the isolated Google Cloud staging fleet.

  Readiness, drain, and health checks use private Erlang distribution. Image
  replacement uses the Compute Engine API through a narrowly authorized
  staging deployer identity. The provider accepts only an exact node-to-instance
  map and refuses a project that matches the configured production project.
  """

  @behaviour OpenAgents.Forge.RollingProvider

  alias OpenAgents.Cluster.Admission
  alias OpenAgents.Cluster.Drain
  alias OpenAgents.Forge.RollingNodeProbe
  alias OpenAgents.Forge.RollingProvider.Gcp.Compute

  @impl true
  def members do
    with {:ok, config} <- config() do
      configured = config |> Keyword.fetch!(:instances) |> Map.keys() |> MapSet.new()

      config
      |> Keyword.get(:node_list, &connected_nodes/0)
      |> then(& &1.())
      |> Enum.filter(&MapSet.member?(configured, to_string(&1)))
      |> Enum.sort()
    else
      {:error, _reason} -> []
    end
  end

  @impl true
  def remove_readiness(node, _context) do
    with {:ok, config} <- config(),
         :ok <- rpc(config, node, Admission, :remove, []) do
      :ok
    end
  end

  @impl true
  def restore_readiness(node, _context) do
    with {:ok, config} <- config(),
         :ok <- rpc(config, node, Admission, :restore, []) do
      :ok
    end
  end

  @impl true
  def drain(node, _context) do
    with {:ok, config} <- config(),
         {:ok, count} <- rpc(config, node, Drain, :drain, []) do
      {:ok, count}
    end
  end

  @impl true
  def capacity(nodes, context) do
    with {:ok, config} <- config(),
         {:ok, probes} <- probes(config, nodes, length(context.expected_nodes)) do
      ready = Enum.count(probes, & &1.ready)
      majority = div(length(context.expected_nodes), 2) + 1
      ra_quorum? = Enum.any?(probes, & &1.ra_quorum)
      {:ok, %{ready: ready, quorum: ready >= majority and ra_quorum?}}
    end
  end

  @impl true
  def replace(node, digest, context) do
    with {:ok, config} <- config(),
         {:ok, instance} <- instance(config, node) do
      compute(config, instance, context.sha, digest)
    end
  end

  @impl true
  def status(node, context) do
    with {:ok, config} <- config(),
         {:ok, probe} <- probe(config, node, length(context.expected_nodes)) do
      {:ok,
       Map.take(probe, [:member, :ready, :boot_converged, :database_ready, :sha, :image_digest])}
    end
  end

  @impl true
  def rollback(node, digest, context) do
    with {:ok, config} <- config(),
         {:ok, instance} <- instance(config, node) do
      compute(config, instance, context.previous_sha, digest)
    end
  end

  @doc "Validate the content-free staging provider configuration."
  def validate_config(config) when is_list(config) do
    project_id = Keyword.get(config, :project_id)
    production_project_id = Keyword.get(config, :production_project_id)
    zone = Keyword.get(config, :zone)
    instances = Keyword.get(config, :instances)
    image_repository = Keyword.get(config, :image_repository)
    deployer_node = Keyword.get(config, :deployer_node)

    cond do
      not bounded_identifier?(project_id) -> {:error, :invalid_staging_project}
      project_id == production_project_id -> {:error, :staging_project_matches_production}
      not bounded_identifier?(production_project_id) -> {:error, :invalid_production_project}
      not bounded_identifier?(zone) -> {:error, :invalid_staging_zone}
      not valid_instances?(instances) -> {:error, :invalid_instance_map}
      not image_repository?(image_repository) -> {:error, :invalid_image_repository}
      not deployer_node?(deployer_node) -> {:error, :invalid_deployer_node}
      true -> :ok
    end
  end

  def validate_config(_config), do: {:error, :invalid_provider_config}

  defp probes(config, nodes, expected_fleet_size) do
    results =
      Task.async_stream(
        nodes,
        &probe(config, &1, expected_fleet_size),
        ordered: false,
        timeout: timeout(config)
      )
      |> Enum.to_list()

    case Enum.reduce_while(results, [], fn
           {:ok, {:ok, probe}}, acc -> {:cont, [probe | acc]}
           {:ok, {:error, reason}}, _acc -> {:halt, {:error, reason}}
           {:exit, reason}, _acc -> {:halt, {:error, {:probe_exit, reason}}}
         end) do
      {:error, reason} -> {:error, reason}
      probes -> {:ok, probes}
    end
  end

  defp probe(config, node, expected_fleet_size) do
    case rpc(config, node, RollingNodeProbe, :status, [expected_fleet_size]) do
      %{member: true} = result -> {:ok, result}
      {:error, :noconnection} -> {:ok, unavailable_probe()}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_node_probe, other}}
    end
  end

  defp unavailable_probe do
    %{
      member: false,
      ready: false,
      boot_converged: false,
      database_ready: false,
      sha: nil,
      image_digest: nil,
      ra_quorum: false
    }
  end

  defp rpc(config, node, module, function, arguments, call_timeout \\ nil) do
    rpc = Keyword.get(config, :rpc, &:erpc.call/5)

    case rpc.(node, module, function, arguments, call_timeout || timeout(config)) do
      {:error, _reason} = error -> error
      result -> result
    end
  catch
    :exit, reason -> {:error, {:rpc_exit, reason}}
    :error, {:erpc, :noconnection} -> {:error, :noconnection}
    :error, reason -> {:error, {:rpc_error, reason}}
  end

  defp instance(config, node) do
    case get_in(config, [:instances, to_string(node)]) do
      instance when is_binary(instance) and instance != "" -> {:ok, instance}
      _missing -> {:error, :node_instance_not_configured}
    end
  end

  defp driver(config), do: Keyword.get(config, :driver, Compute)
  defp connected_nodes, do: Enum.uniq(Node.list() ++ Node.list(:hidden))
  defp timeout(config), do: Keyword.get(config, :rpc_timeout_ms, 5_000)
  defp compute_timeout(config), do: Keyword.get(config, :compute_timeout_ms, 300_000)

  defp compute(config, instance, sha, digest) do
    arguments = [instance, sha, digest, compute_config(config)]

    rpc(
      config,
      Keyword.fetch!(config, :deployer_node),
      driver(config),
      :replace,
      arguments,
      compute_timeout(config)
    )
  end

  defp compute_config(config) do
    Keyword.take(config, [
      :project_id,
      :zone,
      :image_repository,
      :operation_attempts,
      :operation_interval_ms,
      :api_url
    ])
  end

  defp config do
    config = Application.get_env(:openagents, __MODULE__, [])

    case validate_config(config) do
      :ok -> {:ok, config}
      {:error, _reason} = error -> error
    end
  end

  defp valid_instances?(instances) when is_map(instances) and map_size(instances) == 3 do
    Enum.all?(instances, fn {node_name, instance_name} ->
      is_binary(node_name) and String.starts_with?(node_name, "openagents@") and
        bounded_identifier?(instance_name)
    end)
  end

  defp valid_instances?(_instances), do: false

  defp bounded_identifier?(value) when is_binary(value) do
    byte_size(value) in 1..63 and Regex.match?(~r/\A[a-z][a-z0-9-]*[a-z0-9]\z/, value)
  end

  defp bounded_identifier?(_value), do: false

  defp image_repository?(value) when is_binary(value) do
    byte_size(value) in 1..512 and
      Regex.match?(
        ~r/\A[a-z0-9.-]+-docker\.pkg\.dev\/[a-z0-9-]+\/[a-z0-9._-]+\/[a-z0-9._-]+\z/,
        value
      )
  end

  defp image_repository?(_value), do: false

  defp deployer_node?(:"openagents-deployer@openagents-deployer.staging.internal"), do: true
  defp deployer_node?(_node), do: false
end
