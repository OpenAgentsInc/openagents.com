defmodule OpenAgents.RuntimeConfigTest do
  use ExUnit.Case, async: true

  alias OpenAgents.RuntimeConfig
  alias OpenAgents.Tools.Snapshot

  test "the test runtime is valid and produces a content-free report" do
    config = RuntimeConfig.load!()
    report = RuntimeConfig.readiness_report(config)

    assert report["status"] == "ready"
    assert report["environment"] == "test"

    assert report["groups"] == %{
             "cluster" => "ready",
             "database" => "ready",
             "endpoint" => "ready",
             "features" => "ready",
             "forge" => "ready",
             "github" => "ready",
             "providers" => "ready"
           }

    assert is_boolean(report["features"]["voice"])
    assert is_boolean(report["features"]["forge_deploy"])
  end

  test "a Gate 5 staging profile is accepted and its secrets never enter the report" do
    secret = "openai-readiness-secret-sentinel"
    oauth_secret = "oauth-readiness-secret-sentinel"

    settings =
      staging_settings()
      |> Map.put(:openai_api_key, secret)
      |> update_oauth(:client_secret, oauth_secret)

    config = RuntimeConfig.load!(settings)
    encoded = config |> RuntimeConfig.readiness_report() |> Jason.encode!()

    assert config.environment == :staging
    assert config.staging_gate == 5
    refute encoded =~ secret
    refute encoded =~ oauth_secret
    refute encoded =~ "staging.openagents.com"
    refute encoded =~ "ecto://"
  end

  test "staging gates refuse features before their admission gate" do
    settings = staging_settings() |> put_nested(:voice, :enabled, true)

    assert {:error, %{setting: :staging_gate}} = RuntimeConfig.validate(settings)
  end

  test "Gate 12 requires exact packaged source and image identities" do
    settings = staging_settings() |> Map.put(:staging_gate, 12)

    assert {:error, %{setting: :build_revision}} = RuntimeConfig.validate(settings)

    settings = Map.put(settings, :build_revision, String.duplicate("a", 40))
    assert {:error, %{setting: :image_digest}} = RuntimeConfig.validate(settings)

    assert {:ok, _config} =
             settings
             |> Map.put(:image_digest, "sha256:" <> String.duplicate("b", 64))
             |> RuntimeConfig.validate()
  end

  test "staging cleanup is admitted only at Gate 12 or later" do
    exact_identity = %{
      build_revision: String.duplicate("a", 40),
      image_digest: "sha256:" <> String.duplicate("b", 64)
    }

    assert {:ok, _config} =
             staging_settings()
             |> Map.merge(exact_identity)
             |> Map.merge(%{staging_gate: 12, staging_cleanup_enabled: true})
             |> RuntimeConfig.validate()

    assert {:error, %{setting: :staging_cleanup_enabled}} =
             staging_settings()
             |> Map.merge(exact_identity)
             |> Map.merge(%{staging_gate: 11, staging_cleanup_enabled: true})
             |> RuntimeConfig.validate()

    assert {:error, %{setting: :staging_cleanup_enabled}} =
             staging_settings()
             |> Map.put(:staging_cleanup_enabled, "true")
             |> RuntimeConfig.validate()
  end

  test "fleet deployment requires the isolated GCP rolling provider" do
    settings =
      staging_settings()
      |> Map.merge(%{
        staging_gate: 13,
        build_revision: String.duplicate("a", 40),
        image_digest: "sha256:" <> String.duplicate("b", 64),
        forge_enabled: true,
        forge_deploy_lane_enabled: true,
        forge_boot_converge_enabled: true,
        forge_expected_fleet_size: 3,
        forge_operator_token: "staging-operator-token",
        forge_rolling_provider: OpenAgents.Forge.RollingProvider.Gcp,
        forge_wal_dir: "/var/lib/openagents/forge-wal",
        ra_enabled: true,
        dns_cluster_query: "openagents-fleet.staging.internal",
        distribution: [
          enabled: true,
          node_configured: true,
          cookie_configured: true,
          port_min: 9_100,
          port_max: 9_115
        ]
      })
      |> Map.put(OpenAgents.Forge.RollingProvider.Gcp, rolling_gcp_config())

    assert {:ok, _config} = RuntimeConfig.validate(settings)

    assert {:error, %{setting: :forge_rolling_provider}} =
             settings
             |> Map.put(
               OpenAgents.Forge.RollingProvider.Gcp,
               Keyword.put(rolling_gcp_config(), :project_id, "production-project")
             )
             |> RuntimeConfig.validate()
  end

  test "production admits direct deployment without an automatic rolling provider" do
    settings =
      staging_settings()
      |> Map.merge(%{
        runtime_environment: :production,
        staging_gate: 16,
        production_deploy_enabled: true,
        build_revision: String.duplicate("a", 40),
        image_digest: "sha256:" <> String.duplicate("b", 64),
        forge_enabled: true,
        forge_deploy_lane_enabled: true,
        forge_boot_converge_enabled: false,
        forge_expected_fleet_size: 3,
        forge_operator_token: "production-operator-token",
        forge_rolling_provider: nil,
        forge_wal_dir: "/var/lib/openagents/forge-wal",
        github_token_encryption_key_id: "production-2026-08",
        ra_enabled: true,
        dns_cluster_query: "openagents.fleet.internal",
        distribution: [
          enabled: true,
          node_configured: true,
          cookie_configured: true,
          port_min: 9_100,
          port_max: 9_115
        ]
      })
      |> Map.put(OpenAgentsWeb.Endpoint,
        url: [host: "openagents.com", port: 443, scheme: "https"],
        check_origin: ["https://openagents.com"]
      )
      |> update_oauth(:redirect_uri, "https://openagents.com/auth/github/callback")

    assert {:ok, _config} = RuntimeConfig.validate(settings)
  end

  test "enabled OpenAI features require the centralized provider secret" do
    settings =
      staging_settings()
      |> Map.put(:staging_gate, 14)
      |> put_nested(:voice, :enabled, true)
      |> Map.put(:openai_api_key, nil)

    assert {:error, %{setting: :openai_api_key}} = RuntimeConfig.validate(settings)
  end

  test "recording cannot start without its encryption key" do
    settings =
      staging_settings()
      |> Map.put(:staging_gate, 14)
      |> put_nested(:voice, :enabled, true)
      |> put_nested(:voice_recording, :enabled, true)
      |> Map.put(:voice_recording_encryption_key, nil)

    assert {:error, %{setting: :voice_recording_encryption_key}} =
             RuntimeConfig.validate(settings)
  end

  test "hot-load examples are executable startup policy, not prose" do
    settings =
      staging_settings()
      |> Map.put(:forge_hot_load_examples, %{
        "OpenAgentsWeb.ChatLive" => false,
        "OpenAgents.Accounts" => false
      })

    assert {:error, %{setting: :forge_hot_load_examples}} = RuntimeConfig.validate(settings)
  end

  test "production remains locked until an explicit later decision" do
    settings = staging_settings() |> Map.put(:runtime_environment, :production)

    assert {:error, %{setting: :production_deploy_enabled}} = RuntimeConfig.validate(settings)
  end

  test "validation diagnostics name settings without echoing their values" do
    sentinel = "secret-host-value.invalid/path"
    settings = staging_settings() |> put_endpoint(:url, host: sentinel)

    error =
      assert_raise ArgumentError, fn ->
        RuntimeConfig.load!(settings)
      end

    assert error.message =~ "endpoint_host"
    refute error.message =~ sentinel
  end

  test "GitHub keyring metadata and prior keys fail closed without entering readiness" do
    sentinel = Base.encode64(:crypto.strong_rand_bytes(32))

    settings =
      staging_settings()
      |> Map.put(:github_token_decryption_keys, %{"staging-prior-key" => sentinel})

    encoded =
      settings |> RuntimeConfig.load!() |> RuntimeConfig.readiness_report() |> Jason.encode!()

    refute encoded =~ sentinel
    refute encoded =~ "staging-prior-key"

    assert {:error, %{setting: :github_token_encryption_key_id}} =
             settings
             |> Map.put(:github_token_encryption_key_id, "production-wrong-environment")
             |> RuntimeConfig.validate()

    assert {:error, %{setting: :github_token_decryption_keys}} =
             settings
             |> Map.put(:github_token_decryption_keys, %{"prior" => "not-base64"})
             |> RuntimeConfig.validate()

    assert {:error, %{setting: :github_token_decryption_keys}} =
             settings
             |> Map.put(:github_token_decryption_keys, %{"production-prior" => sentinel})
             |> RuntimeConfig.validate()

    assert {:error, %{setting: :github_token_decryption_keys}} =
             settings
             |> Map.put(:github_token_decryption_keys, %{"staging-2026-08" => sentinel})
             |> RuntimeConfig.validate()
  end

  test "forge mirror remotes refuse credential-bearing URLs" do
    for url <- [
          "https://operator:secret@mirror.example/openagents.com.git",
          "ssh://operator:secret@mirror.example/openagents.com.git",
          "operator:secret@mirror.example:openagents.com.git"
        ] do
      settings =
        staging_settings()
        |> Map.put(:forge_mirror_urls, %{"openagents.com" => url})

      assert {:error, %{setting: :forge_mirror_urls}} = RuntimeConfig.validate(settings)
    end

    assert {:ok, _config} =
             staging_settings()
             |> Map.put(:forge_mirror_urls, %{"openagents.com" => "/var/lib/openagents/mirror"})
             |> RuntimeConfig.validate()

    assert {:ok, _config} =
             staging_settings()
             |> Map.put(:forge_mirror_urls, %{
               "openagents.com" => "ssh://git@github.com/OpenAgentsInc/openagents.com.git"
             })
             |> RuntimeConfig.validate()
  end

  test "startup refuses an empty tool catalog when tools are enabled" do
    config = RuntimeConfig.load!(staging_settings())

    snapshot = %Snapshot{
      schema: "test",
      digest: "test",
      tools: %{},
      all_tools: %{},
      modules: %{}
    }

    assert_raise ArgumentError, ~r/tools catalog is empty/, fn ->
      RuntimeConfig.verify_startup!(config, snapshot)
    end
  end

  test "an SCV lane refuses a clone root on the container layer" do
    # Gate 14 admits the lane; the clone root is what decides whether the
    # repository lands on the durable volume or on the boot disk.
    settings =
      staging_settings()
      |> Map.put(:staging_gate, 14)
      |> Map.put(:build_revision, String.duplicate("a", 40))
      |> Map.put(:image_digest, "sha256:" <> String.duplicate("b", 64))
      |> put_nested(:work, :enabled, true)
      |> Map.put(:work_workers_enabled, true)
      |> put_nested(:scv_deploy, :enabled, true)

    assert {:error, %{setting: :scv_temporary_root}} =
             settings
             |> put_nested(:scv_codex, :temporary_root, "/tmp")
             |> RuntimeConfig.validate()

    assert {:error, %{setting: :scv_temporary_root}} =
             settings
             |> put_nested(:scv_codex, :temporary_root, "/tmp/openagents-scv")
             |> RuntimeConfig.validate()

    assert {:ok, config} =
             settings
             |> put_nested(:scv_codex, :temporary_root, "/var/lib/openagents/workspace/scv")
             |> RuntimeConfig.validate()

    assert RuntimeConfig.feature_enabled?(config, :scv_deploy)
  end

  defp staging_settings do
    current = Map.new(Application.get_all_env(:openagents))

    current
    |> Map.merge(%{
      runtime_environment: :staging,
      staging_gate: 5,
      production_deploy_enabled: false,
      secure_cookies: true,
      https_aliases: [],
      migrate_on_boot: true,
      provider: OpenAgents.Providers.OpenAI,
      openai_api_key: "staging-openai-secret",
      forge_enabled: false,
      forge_deploy_lane_enabled: false,
      forge_boot_converge_enabled: false,
      turn_recovery_enabled: false,
      voice_retention_enabled: false,
      computer_controller_enabled: false,
      ra_enabled: false,
      forge_repos: ["openagents.com"],
      forge_repo_owners: %{"openagents.com" => "OpenAgentsInc"},
      forge_public_visibility: %{"openagents.com" => :l3},
      forge_public_paths: %{"openagents.com" => []},
      forge_operator_token: nil,
      github_token_encryption_key_id: "staging-2026-08",
      dns_cluster_query: nil,
      distribution: [
        enabled: false,
        node_configured: false,
        cookie_configured: false,
        port_min: 9_100,
        port_max: 9_115
      ]
    })
    |> Map.put(OpenAgents.Repo,
      url: "ecto://runtime-user:runtime-password@database/openagents",
      pool_size: 10
    )
    |> Map.put(OpenAgentsWeb.Endpoint,
      url: [host: "staging.openagents.com", port: 443, scheme: "https"],
      check_origin: ["https://staging.openagents.com"]
    )
    |> update_oauth(:redirect_uri, "https://staging.openagents.com/auth/github/callback")
    |> put_nested(:voice, :enabled, false)
    |> put_nested(:voice_recording, :enabled, false)
    |> put_nested(:work, :enabled, false)
    |> put_nested(:semantic_index, :enabled, false)
    |> put_nested(:experience_memory, :enabled, false)
    |> put_nested(:graph_memory, :enabled, false)
    |> put_nested(:memory_portability, :enabled, false)
    |> put_nested(:shadow_programs, :enabled, false)
    |> put_nested(:scv_codex, :enabled, false)
    |> put_nested(:scv_codex, :temporary_root, "/var/lib/openagents/workspace/scv")
  end

  defp rolling_gcp_config do
    [
      project_id: "staging-project",
      production_project_id: "production-project",
      zone: "us-central1-a",
      instances: %{
        "openagents@fleet-1.staging.internal" => "openagents-fleet-1",
        "openagents@fleet-2.staging.internal" => "openagents-fleet-2",
        "openagents@fleet-3.staging.internal" => "openagents-fleet-3"
      },
      image_repository: "us-central1-docker.pkg.dev/staging-project/openagents/app",
      deployer_node: :"openagents-deployer@openagents-deployer.staging.internal"
    ]
  end

  defp update_oauth(settings, key, value) do
    Map.update!(settings, :github_oauth, &Keyword.put(&1, key, value))
  end

  defp put_nested(settings, group, key, value) do
    Map.update!(settings, group, &Keyword.put(&1, key, value))
  end

  defp put_endpoint(settings, key, value) do
    Map.update!(settings, OpenAgentsWeb.Endpoint, &Keyword.put(&1, key, value))
  end

  describe "internal_surfaces_visible?/1" do
    test "production does not advertise the component library" do
      refute RuntimeConfig.internal_surfaces_visible?(%RuntimeConfig{
               environment: :production,
               staging_gate: 0,
               features: %{},
               groups: %{}
             })
    end

    test "every other environment does" do
      for environment <- [:development, :test, :staging] do
        assert RuntimeConfig.internal_surfaces_visible?(%RuntimeConfig{
                 environment: environment,
                 staging_gate: 0,
                 features: %{},
                 groups: %{}
               }),
               "expected #{environment} to advertise the component library"
      end
    end
  end
end
