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

if config_env() == :dev do
  config :openagents, :openai_api_key, optional_text.("OPENAI_API_KEY")
end

if config_env() == :prod do
  runtime_environment =
    case required_text.("OPENAGENTS_ENVIRONMENT") do
      "staging" -> :staging
      "production" -> :production
      _invalid -> raise "environment variable OPENAGENTS_ENVIRONMENT is not admitted"
    end

  staging_gate = parse_integer.("OPENAGENTS_STAGING_GATE", 0..16)
  production_deploy_enabled = parse_boolean.("OPENAGENTS_PRODUCTION_DEPLOY_ENABLED")
  secure_cookies = parse_boolean.("OPENAGENTS_SECURE_COOKIES")
  migrate_on_boot = parse_boolean.("OPENAGENTS_MIGRATE_ON_BOOT")
  host = required_text.("PHX_HOST")
  allowed_origins = parse_csv.("OPENAGENTS_ALLOWED_ORIGINS")
  https_aliases = parse_csv.("OPENAGENTS_HTTPS_ALIASES")
  ecto_ipv6? = parse_boolean.("OPENAGENTS_DATABASE_IPV6")
  pool_size = parse_integer.("POOL_SIZE", 1..200)

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
    production_deploy_enabled: production_deploy_enabled,
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
    semantic_index: semantic_index,
    experience_memory: experience_memory,
    graph_memory: graph_memory,
    memory_portability: memory_portability,
    shadow_programs: shadow_programs,
    tool_discovery: tool_discovery,
    computer_controller_enabled: computers_enabled,
    coding_jobs_dir: required_text.("OPENAGENTS_CODING_JOBS_DIR"),
    conversation_reset_enabled: conversation_reset_enabled,
    incident_fixer_enabled: incident_fixer_enabled,
    turn_recovery_enabled: turn_recovery_enabled,
    github_oauth_scopes: github_oauth_scopes,
    openai_api_key: required_text.("OPENAI_API_KEY"),
    inference_proxy_url: optional_text.("OPENAGENTS_INFERENCE_PROXY_URL"),
    forge_enabled: forge_enabled,
    forge_deploy_lane_enabled: forge_deploy_enabled,
    forge_boot_converge_enabled: boot_convergence_enabled,
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

  config :openagents, OpenAgents.Repo, repo_config

  config :openagents, OpenAgentsWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    check_origin: allowed_origins,
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: required_text.("SECRET_KEY_BASE")
end

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

valid_token_key? =
  is_binary(token_encryption_key) and
    match?({:ok, key} when byte_size(key) == 32, Base.decode64(token_encryption_key))

if config_env() == :prod and not valid_token_key? do
  raise "environment variable GITHUB_TOKEN_ENCRYPTION_KEY must be a base64-encoded 32-byte key"
end

if valid_token_key? do
  config :openagents, :github_token_encryption_key, token_encryption_key
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
