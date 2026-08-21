defmodule OpenAgents.Forge.RollingProvider.Gcp.DeployerTest do
  use ExUnit.Case, async: false

  alias OpenAgents.Forge.RollingProvider.Gcp
  alias OpenAgents.Forge.RollingProvider.Gcp.Deployer

  @environment %{
    "OPENAGENTS_GCP_IMAGE_REPOSITORY" =>
      "us-central1-docker.pkg.dev/openagents-staging-project/openagents/openagents",
    "OPENAGENTS_GCP_ROLLING_INSTANCES_JSON" =>
      ~s({"openagents@10.42.0.11":"openagents-fleet-1","openagents@10.42.0.12":"openagents-fleet-2","openagents@10.42.0.13":"openagents-fleet-3"}),
    "OPENAGENTS_GCP_ROLLING_PROJECT_ID" => "openagents-staging-project",
    "OPENAGENTS_GCP_ROLLING_ZONE" => "us-central1-a",
    "OPENAGENTS_PRODUCTION_PROJECT_ID" => "production-project"
  }

  setup do
    previous = Application.get_env(:openagents, Gcp)
    on_exit(fn -> restore_config(previous) end)
    :ok
  end

  test "loads the bounded provider inventory for the minimal controller" do
    assert :ok = Deployer.configure_provider!(@environment)

    config = Application.fetch_env!(:openagents, Gcp)
    assert config[:project_id] == "openagents-staging-project"
    assert config[:production_project_id] == "production-project"
    assert config[:zone] == "us-central1-a"
    assert map_size(config[:instances]) == 3
    assert config[:deployer_node] == :"openagents-deployer@openagents-deployer.staging.internal"
  end

  test "refuses malformed controller inventory" do
    environment = Map.put(@environment, "OPENAGENTS_GCP_ROLLING_INSTANCES_JSON", "{}")

    assert_raise ArgumentError, "staging rolling-provider configuration is invalid", fn ->
      Deployer.configure_provider!(environment)
    end
  end

  defp restore_config(nil), do: Application.delete_env(:openagents, Gcp)
  defp restore_config(config), do: Application.put_env(:openagents, Gcp, config)
end
