import Config

# Development may use a local, uncommitted dotenv file. Production and release
# configuration always comes from the deployment environment.
if config_env() == :dev do
  env_file = Path.expand("../.env", __DIR__)

  if File.regular?(env_file) do
    env_file
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.each(fn line ->
      case String.split(line, "=", parts: 2) do
        [key, value] when key != "" ->
          if System.get_env(key) == nil do
            System.put_env(key, String.trim(value, "\"'"))
          end

        _invalid ->
          :ok
      end
    end)
  end
end

fetch_raw = fn name ->
  case System.fetch_env(name) do
    {:ok, value} -> String.trim(value)
    :error -> raise "environment variable #{name} is required"
  end
end

required_text = fn name ->
  case fetch_raw.(name) do
    "" -> raise "environment variable #{name} must not be empty"
    value -> value
  end
end

optional_text = fn name ->
  case System.get_env(name) do
    nil -> nil
    value -> if String.trim(value) == "", do: nil, else: String.trim(value)
  end
end

parse_boolean = fn name ->
  case fetch_raw.(name) do
    "true" -> true
    "false" -> false
    _invalid -> raise "environment variable #{name} must be true or false"
  end
end

parse_optional_boolean = fn name ->
  case System.get_env(name) do
    nil -> false
    "true" -> true
    "false" -> false
    _invalid -> raise "environment variable #{name} must be true or false when set"
  end
end

parse_integer = fn name, range ->
  case Integer.parse(required_text.(name)) do
    {value, ""} ->
      if value in range,
        do: value,
        else: raise("environment variable #{name} is outside its admitted range")

    _invalid ->
      raise "environment variable #{name} must be an integer"
  end
end

parse_csv = fn name ->
  name
  |> fetch_raw.()
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))
end

runtime_role =
  case System.get_env("OPENAGENTS_RUNTIME_ROLE", "web") do
    "web" -> :web
    "scv" -> :scv
    "builder" -> :builder
    _invalid -> raise "environment variable OPENAGENTS_RUNTIME_ROLE is not admitted"
  end

config :openagents, :runtime_role, runtime_role

if config_env() == :dev do
  config :openagents, :openai_api_key, optional_text.("OPENAI_API_KEY")
end

# The changelog seed. Idempotent and off the boot path. It was gated behind a
# flag that nothing ever set, so the seed sat unused and the public page said
# "Nothing yet" from the day it shipped.
if config_env() == :prod do
  config :openagents, :changelog_backfill_on_boot, true
end

if config_env() == :prod and runtime_role == :web do
  runtime_environment =
    case required_text.("OPENAGENTS_ENVIRONMENT") do
      "staging" -> :staging
      "production" -> :production
      _invalid -> raise "environment variable OPENAGENTS_ENVIRONMENT is not admitted"
    end

  staging_gate = parse_integer.("OPENAGENTS_STAGING_GATE", 0..16)
  production_deploy_enabled = parse_boolean.("OPENAGENTS_PRODUCTION_DEPLOY_ENABLED")
  staging_cleanup_enabled = parse_boolean.("OPENAGENTS_STAGING_CLEANUP_ENABLED")
  secure_cookies = parse_boolean.("OPENAGENTS_SECURE_COOKIES")
  migrate_on_boot = parse_boolean.("OPENAGENTS_MIGRATE_ON_BOOT")
  host = required_text.("PHX_HOST")
  allowed_origins = parse_csv.("OPENAGENTS_ALLOWED_ORIGINS")
  https_aliases = parse_csv.("OPENAGENTS_HTTPS_ALIASES")
  ecto_ipv6? = parse_boolean.("OPENAGENTS_DATABASE_IPV6")
  pool_size = parse_integer.("POOL_SIZE", 1..200)

  admin_github_ids =
    "OPENAGENTS_ADMIN_GITHUB_IDS"
    |> optional_text.()
    |> OpenAgents.Accounts.OperatorConfig.parse_github_ids!()

  repo_config =
    case required_text.("OPENAGENTS_DATABASE_MODE") do
      "url" ->
        [
          url: required_text.("DATABASE_URL"),
          pool_size: pool_size,
          socket_options: if(ecto_ipv6?, do: [:inet6], else: [])
        ]

      "socket" ->
        [
          username: required_text.("DB_USER"),
          password: required_text.("DB_PASSWORD"),
          database: required_text.("DB_NAME"),
          socket_dir: required_text.("INSTANCE_UNIX_SOCKET"),
          pool_size: pool_size,
          socket_options: if(ecto_ipv6?, do: [:inet6], else: [])
        ]

      _invalid ->
        raise "environment variable OPENAGENTS_DATABASE_MODE must be url or socket"
    end

  feature = fn name -> parse_boolean.("OPENAGENTS_FEATURE_#{name}") end

  tools_enabled = feature.("TOOLS")
  voice_enabled = feature.("VOICE")
  recording_enabled = feature.("VOICE_RECORDING")
  work_enabled = feature.("WORK")
  semantic_enabled = feature.("SEMANTIC_MEMORY")
  experience_enabled = feature.("EXPERIENCE_MEMORY")
  graph_enabled = feature.("GRAPH_MEMORY")
  portability_enabled = feature.("MEMORY_PORTABILITY")
  shadow_enabled = feature.("SHADOW_PROGRAMS")
  tool_embeddings_enabled = feature.("TOOL_EMBEDDINGS")
  computers_enabled = feature.("COMPUTERS")
  conversation_reset_enabled = feature.("CONVERSATION_RESET")
  incident_fixer_enabled = feature.("INCIDENT_FIXER")
  turn_recovery_enabled = feature.("TURN_RECOVERY")
  voice_retention_enabled = feature.("VOICE_RETENTION")
  forge_enabled = feature.("FORGE")
  forge_deploy_enabled = feature.("FORGE_DEPLOY")
  boot_convergence_enabled = feature.("BOOT_CONVERGENCE")
  ra_enabled = feature.("RA")
  horde_enabled = feature.("HORDE")
  scv_codex_enabled = parse_optional_boolean.("OPENAGENTS_FEATURE_SCV_CODEX")

  scv_codex_credential_store =
    case optional_text.("OPENAGENTS_SCV_CODEX_CREDENTIAL_STORE") do
      nil ->
        OpenAgents.SCV.CodexCredentialStore.File

      "file" ->
        OpenAgents.SCV.CodexCredentialStore.File

      "gcp_secret_manager" ->
        OpenAgents.SCV.CodexCredentialStore.GcpSecretManager

      _invalid ->
        raise "environment variable OPENAGENTS_SCV_CODEX_CREDENTIAL_STORE is not admitted"
    end

  scv_codex_credential_refs =
    case optional_text.("OPENAGENTS_SCV_CODEX_CREDENTIAL_REFS") do
      nil -> []
      _configured -> parse_csv.("OPENAGENTS_SCV_CODEX_CREDENTIAL_REFS")
    end

  if scv_codex_enabled and scv_codex_credential_refs == [] do
    raise "environment variable OPENAGENTS_SCV_CODEX_CREDENTIAL_REFS is required when Codex SCV accounts are enabled"
  end

  scv_codex = [
    enabled: scv_codex_enabled,
    execution_reaper_enabled: scv_codex_enabled,
    executable:
      optional_text.("OPENAGENTS_SCV_CODEX_BIN") ||
        Application.fetch_env!(:openagents, :scv_codex)[:executable],
    credential_store: scv_codex_credential_store,
    credential_refs: scv_codex_credential_refs,
    file_root:
      optional_text.("OPENAGENTS_SCV_CODEX_FILE_ROOT") ||
        Application.fetch_env!(:openagents, :scv_codex)[:file_root],
    temporary_root: System.tmp_dir!(),
    client_options: []
  ]

  voice =
    :openagents
    |> Application.fetch_env!(:voice)
    |> Keyword.put(:enabled, voice_enabled)

  voice_recording =
    :openagents
    |> Application.fetch_env!(:voice_recording)
    |> Keyword.put(:enabled, recording_enabled)

  work =
    :openagents
    |> Application.fetch_env!(:work)
    |> Keyword.put(:enabled, work_enabled)

  semantic_index =
    :openagents
    |> Application.fetch_env!(:semantic_index)
    |> Keyword.put(:enabled, semantic_enabled)

  experience_memory =
    :openagents
    |> Application.fetch_env!(:experience_memory)
    |> Keyword.put(:enabled, experience_enabled)

  graph_memory =
    :openagents
    |> Application.fetch_env!(:graph_memory)
    |> Keyword.put(:enabled, graph_enabled)

  memory_portability =
    :openagents
    |> Application.fetch_env!(:memory_portability)
    |> Keyword.put(:enabled, portability_enabled)

  shadow_programs =
    :openagents
    |> Application.fetch_env!(:shadow_programs)
    |> Keyword.put(:enabled, shadow_enabled)

  tool_discovery =
    :openagents
    |> Application.fetch_env!(:tool_discovery)
    |> Keyword.put(:embeddings_enabled, tool_embeddings_enabled)

  forge_repos = parse_csv.("OPENAGENTS_FORGE_REPOSITORIES")
  forge_owner = required_text.("OPENAGENTS_FORGE_OWNER")
  github_oauth_scopes = parse_csv.("GITHUB_OAUTH_SCOPES")

  forge_wal_adapter =
    case required_text.("OPENAGENTS_FORGE_WAL_ADAPTER") do
      "local" -> OpenAgents.Forge.WAL.Local
      "gcs" -> OpenAgents.Forge.WAL.Gcs
      _invalid -> raise "environment variable OPENAGENTS_FORGE_WAL_ADAPTER is not admitted"
    end

  forge_artifact_store =
    case required_text.("OPENAGENTS_FORGE_ARTIFACT_STORE") do
      "local" -> :local
      "gcs" -> :gcs
      _invalid -> raise "environment variable OPENAGENTS_FORGE_ARTIFACT_STORE is not admitted"
    end

  forge_build_executor =
    case required_text.("OPENAGENTS_FORGE_BUILD_EXECUTOR") do
      "sidecar" -> OpenAgents.Forge.BuildExecutor.Sidecar
      _invalid -> raise "environment variable OPENAGENTS_FORGE_BUILD_EXECUTOR is not admitted"
    end

  forge_rolling_provider =
    case optional_text.("OPENAGENTS_FORGE_ROLLING_PROVIDER") do
      nil -> nil
      "gcp" -> OpenAgents.Forge.RollingProvider.Gcp
      _invalid -> raise "environment variable OPENAGENTS_FORGE_ROLLING_PROVIDER is not admitted"
    end

  rolling_instances =
    case optional_text.("OPENAGENTS_GCP_ROLLING_INSTANCES_JSON") do
      nil ->
        %{}

      encoded ->
        case Jason.decode(encoded) do
          {:ok, instances} when is_map(instances) ->
            instances

          _invalid ->
            raise "environment variable OPENAGENTS_GCP_ROLLING_INSTANCES_JSON must be a JSON object"
        end
    end

  distribution_enabled = System.get_env("RELEASE_DISTRIBUTION") in ["name", "longnames"]
  release_node = optional_text.("RELEASE_NODE")
  release_cookie = optional_text.("RELEASE_COOKIE")

  node_configured =
    is_binary(release_node) and
      Regex.match?(~r/\Aopenagents@[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}\z/, release_node)

  distribution = [
    enabled: distribution_enabled,
    node_configured: node_configured,
    cookie_configured: is_binary(release_cookie) and byte_size(release_cookie) >= 32,
    port_min: parse_integer.("OPENAGENTS_DIST_PORT_MIN", 1_024..65_535),
    port_max: parse_integer.("OPENAGENTS_DIST_PORT_MAX", 1_024..65_535)
  ]

  config :openagents,
    runtime_environment: runtime_environment,
    staging_gate: staging_gate,
    staging_cleanup_enabled: staging_cleanup_enabled,
    production_deploy_enabled: production_deploy_enabled,
    build_revision: OpenAgents.BuildInfo.revision(),
    admin_github_ids: admin_github_ids,
    image_digest: optional_text.("OPENAGENTS_IMAGE_DIGEST"),
    secure_cookies: secure_cookies,
    https_aliases: https_aliases,
    migrate_on_boot: migrate_on_boot,
    tools_enabled: tools_enabled,
    voice: voice,
    voice_recording: voice_recording,
    voice_recording_encryption_key: optional_text.("VOICE_RECORDING_ENCRYPTION_KEY"),
    voice_recovery_worker_enabled: voice_enabled,
    voice_retention_worker_enabled: voice_retention_enabled,
    voice_retention_enabled: voice_retention_enabled,
    work: work,
    work_workers_enabled: work_enabled,
    scv_codex: scv_codex,
    semantic_index: semantic_index,
    experience_memory: experience_memory,
    graph_memory: graph_memory,
    memory_portability: memory_portability,
    shadow_programs: shadow_programs,
    tool_discovery: tool_discovery,
    computer_controller_enabled: computers_enabled,
    machine_token_ttl_seconds:
      parse_integer.("OPENAGENTS_MACHINE_TOKEN_TTL_SECONDS", 300..2_592_000),
    coding_jobs_dir: required_text.("OPENAGENTS_CODING_JOBS_DIR"),
    conversation_reset_enabled: conversation_reset_enabled,
    incident_fixer_enabled: incident_fixer_enabled,
    turn_recovery_enabled: turn_recovery_enabled,
    github_oauth_scopes: github_oauth_scopes,
    openai_api_key: required_text.("OPENAI_API_KEY"),
    inference_proxy_url: optional_text.("OPENAGENTS_INFERENCE_PROXY_URL"),
    forge_enabled: forge_enabled,
    forge_deploy_lane_enabled: forge_deploy_enabled,
    repository_provisioner_enabled: forge_deploy_enabled,
    forge_boot_converge_enabled: boot_convergence_enabled,
    forge_rolling_provider: forge_rolling_provider,
    forge_repos: forge_repos,
    forge_repo_owners: Map.new(forge_repos, &{&1, forge_owner}),
    forge_public_visibility: Map.new(forge_repos, &{&1, :l3}),
    forge_public_paths: Map.new(forge_repos, &{&1, []}),
    forge_internal_git_url: required_text.("OPENAGENTS_FORGE_INTERNAL_GIT_URL"),
    forge_operator_token: optional_text.("OPENAGENTS_FORGE_OPERATOR_TOKEN"),
    forge_data_dir: required_text.("OPENAGENTS_FORGE_DATA_DIR"),
    forge_build_dir: required_text.("OPENAGENTS_FORGE_BUILD_DIR"),
    forge_build_queue_dir: required_text.("OPENAGENTS_FORGE_BUILD_QUEUE_DIR"),
    forge_artifact_dir: required_text.("OPENAGENTS_FORGE_ARTIFACT_DIR"),
    forge_build_timeout_ms:
      parse_integer.("OPENAGENTS_FORGE_BUILD_TIMEOUT_MS", 30_000..1_800_000),
    forge_build_output_retention_ms:
      parse_integer.("OPENAGENTS_FORGE_BUILD_OUTPUT_RETENTION_MS", 86_400_000..2_592_000_000),
    forge_deploy_timeout_ms: parse_integer.("OPENAGENTS_FORGE_DEPLOY_TIMEOUT_MS", 1_000..120_000),
    forge_deploy_token_ttl_ms:
      parse_integer.("OPENAGENTS_FORGE_DEPLOY_TOKEN_TTL_MS", 30_000..1_800_000),
    forge_boot_retry_min_ms: parse_integer.("OPENAGENTS_FORGE_BOOT_RETRY_MIN_MS", 100..60_000),
    forge_boot_retry_max_ms: parse_integer.("OPENAGENTS_FORGE_BOOT_RETRY_MAX_MS", 1_000..300_000),
    forge_artifact_store: forge_artifact_store,
    forge_build_executor: forge_build_executor,
    forge_expected_fleet_size: parse_integer.("OPENAGENTS_FORGE_EXPECTED_FLEET_SIZE", 1..100),
    forge_wal_adapter: forge_wal_adapter,
    forge_wal_dir: required_text.("OPENAGENTS_FORGE_WAL_DIR"),
    forge_wal_bucket: optional_text.("OPENAGENTS_FORGE_WAL_BUCKET"),
    ra_enabled: ra_enabled,
    ra_data_dir: required_text.("OPENAGENTS_RA_DATA_DIR"),
    ra_expected_size: parse_integer.("OPENAGENTS_RA_EXPECTED_SIZE", 1..100),
    horde_enabled: horde_enabled,
    dns_cluster_query: optional_text.("DNS_CLUSTER_QUERY"),
    distribution: distribution

  config :openagents, OpenAgents.Forge.RollingProvider.Gcp,
    project_id: optional_text.("OPENAGENTS_GCP_ROLLING_PROJECT_ID"),
    production_project_id: optional_text.("OPENAGENTS_PRODUCTION_PROJECT_ID"),
    zone: optional_text.("OPENAGENTS_GCP_ROLLING_ZONE"),
    instances: rolling_instances,
    image_repository: optional_text.("OPENAGENTS_GCP_IMAGE_REPOSITORY"),
    deployer_node: :"openagents-deployer@openagents-deployer.staging.internal",
    rpc_timeout_ms: parse_integer.("OPENAGENTS_GCP_ROLLING_RPC_TIMEOUT_MS", 1_000..120_000),
    compute_timeout_ms: parse_integer.("OPENAGENTS_GCP_COMPUTE_TIMEOUT_MS", 30_000..600_000)

  config :openagents, OpenAgents.Repo, repo_config

  config :openagents, OpenAgentsWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    check_origin: allowed_origins,
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: required_text.("SECRET_KEY_BASE")
end

if config_env() == :prod and runtime_role == :scv do
  runtime_environment =
    case required_text.("OPENAGENTS_ENVIRONMENT") do
      "staging" -> :staging
      _invalid -> raise "an SCV worker is admitted only in staging"
    end

  config :openagents,
    runtime_environment: runtime_environment,
    openai_api_key: required_text.("OPENAI_API_KEY")
end

if runtime_role == :web do
  github_oauth = Application.get_env(:openagents, :github_oauth, [])

  github_oauth =
    github_oauth
    |> Keyword.merge(
      client_id: System.get_env("GITHUB_CLIENT_ID") || github_oauth[:client_id],
      client_secret: System.get_env("GITHUB_CLIENT_SECRET") || github_oauth[:client_secret],
      redirect_uri: System.get_env("GITHUB_REDIRECT_URI") || github_oauth[:redirect_uri]
    )
    |> OpenAgents.GitHubOAuth.RuntimeConfig.load!(config_env(),
      public_host: System.get_env("PHX_HOST")
    )

  config :openagents, :github_oauth, github_oauth

  token_encryption_key = optional_text.("GITHUB_TOKEN_ENCRYPTION_KEY")
  token_encryption_key_id = optional_text.("GITHUB_TOKEN_ENCRYPTION_KEY_ID")

  token_decryption_keys =
    case optional_text.("GITHUB_TOKEN_DECRYPTION_KEYS_JSON") do
      nil ->
        %{}

      encoded ->
        case Jason.decode(encoded) do
          {:ok, keys} when is_map(keys) ->
            keys

          _invalid ->
            raise "environment variable GITHUB_TOKEN_DECRYPTION_KEYS_JSON must be a JSON object"
        end
    end

  valid_token_key? =
    is_binary(token_encryption_key) and
      match?({:ok, key} when byte_size(key) == 32, Base.decode64(token_encryption_key))

  valid_token_key_id? =
    is_binary(token_encryption_key_id) and
      String.match?(token_encryption_key_id, ~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}\z/)

  valid_decryption_keys? =
    map_size(token_decryption_keys) <= 16 and
      not Map.has_key?(token_decryption_keys, token_encryption_key_id) and
      Enum.all?(token_decryption_keys, fn {key_id, encoded_key} ->
        is_binary(key_id) and String.match?(key_id, ~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}\z/) and
          is_binary(encoded_key) and
          match?({:ok, key} when byte_size(key) == 32, Base.decode64(encoded_key))
      end)

  if config_env() == :prod and
       not (valid_token_key? and valid_token_key_id? and valid_decryption_keys?) do
    raise "GitHub token keyring environment variables are invalid"
  end

  if valid_token_key? and valid_token_key_id? and valid_decryption_keys? do
    config :openagents,
      github_token_encryption_key: token_encryption_key,
      github_token_encryption_key_id: token_encryption_key_id,
      github_token_decryption_keys: token_decryption_keys
  end
end

if parse_optional_boolean.("PHX_SERVER") do
  config :openagents, OpenAgentsWeb.Endpoint, server: true
end

port =
  case Integer.parse(System.get_env("PORT", "4000")) do
    {value, ""} when value in 1..65_535 -> value
    _invalid -> raise "environment variable PORT must be a valid port"
  end

config :openagents, OpenAgentsWeb.Endpoint, http: [port: port]

if config_env() == :dev do
  config :openagents, OpenAgentsWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        ~r"priv/gettext/.*\.po$"E,
        ~r"lib/openagents_web/router\.ex$"E,
        ~r"lib/openagents_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end
