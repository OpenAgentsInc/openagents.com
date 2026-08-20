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
    refute encoded =~ "stage.openagents.com"
    refute encoded =~ "ecto://"
  end

  test "staging gates refuse features before their admission gate" do
    settings = staging_settings() |> put_nested(:voice, :enabled, true)

    assert {:error, %{setting: :staging_gate}} = RuntimeConfig.validate(settings)
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
      url: [host: "stage.openagents.com", port: 443, scheme: "https"],
      check_origin: ["https://stage.openagents.com"]
    )
    |> update_oauth(:redirect_uri, "https://stage.openagents.com/auth/github/callback")
    |> put_nested(:voice, :enabled, false)
    |> put_nested(:voice_recording, :enabled, false)
    |> put_nested(:work, :enabled, false)
    |> put_nested(:semantic_index, :enabled, false)
    |> put_nested(:experience_memory, :enabled, false)
    |> put_nested(:graph_memory, :enabled, false)
    |> put_nested(:memory_portability, :enabled, false)
    |> put_nested(:shadow_programs, :enabled, false)
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
end
