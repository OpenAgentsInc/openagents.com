# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :phoenix,
  filter_parameters: [
    "authorization",
    "code",
    "content",
    "credential",
    "memory",
    "messages",
    "password",
    "poll_secret",
    "prompt",
    "raw_arguments",
    "sdp",
    "secret",
    "state",
    "token",
    "transcript",
    "verifier"
  ]

config :openagents,
  namespace: OpenAgents,
  ecto_repos: [OpenAgents.Repo],
  generators: [timestamp_type: :utc_datetime],
  runtime_environment: :development,
  staging_gate: 0,
  production_deploy_enabled: false,
  migrate_on_boot: false,
  secure_cookies: false,
  https_aliases: [],
  conversation_page_size: 40,
  maximum_message_bytes: 8_000,
  turn_rate_limit: 50,
  admin_github_ids: [],
  computer_controller_enabled: false,
  machine_token_ttl_seconds: 2_592_000,
  coding_jobs_dir: "/var/lib/openagents/coding-jobs",
  work_workers_enabled: false,
  work: [enabled: false],
  tools_enabled: true,
  voice: [
    enabled: false,
    architecture: :openai_realtime,
    provider: "openai",
    model: "gpt-realtime-2.1",
    voice: "marin",
    reasoning_effort: "low",
    maximum_session_seconds: 3_000
  ],
  voice_attempt_limit: 6,
  voice_attempt_window_seconds: 600,
  voice_maximum_concurrent_sessions: 8,
  voice_maximum_session_tokens: 5_000_000,
  voice_maximum_response_output_tokens: 4_096,
  voice_maximum_estimated_cost_microusd: 20_000_000,
  voice_operational_retention_days: 90,
  voice_compaction_input_token_threshold: 16_000,
  provider: OpenAgents.Providers.OpenAI,
  openai_model: "gpt-5.6-luna",
  openai_api_key: nil,
  shadow_programs: [
    enabled: false,
    provider: OpenAgents.ShadowPrograms.OpenAI,
    timeout_ms: 5_000
  ],
  voice_call_provider: OpenAgents.Voice.OpenAI.CallClient,
  voice_sideband_provider: OpenAgents.Voice.OpenAI.Sideband,
  recall_search_backend: OpenAgents.Memory.LexicalRecall,
  semantic_index: [
    enabled: false,
    provider: OpenAgents.Memory.OpenAIEmbeddings,
    model_id: "text-embedding-3-small",
    model_version: "2024-01",
    dimensions: 64,
    batch_size: 10,
    poll_interval_ms: 2_000,
    provider_timeout_ms: 15_000,
    lease_ms: 30_000
  ],
  experience_memory: [
    enabled: false,
    maximum_records: 6,
    maximum_patterns: 3,
    maximum_bytes: 4_000
  ],
  graph_memory: [
    enabled: false,
    maximum_nodes: 50,
    maximum_depth: 3,
    maximum_export_artifacts: 500
  ],
  memory_portability: [enabled: false],
  tool_discovery: [
    embeddings_enabled: false,
    provider: OpenAgents.Memory.OpenAIEmbeddings,
    model_id: "text-embedding-3-small",
    model_version: "2024-01",
    dimensions: 64,
    top_k: 12
  ],
  tools: [
    OpenAgents.Tools.ModuleDiscover,
    OpenAgents.Tools.GitHubRepoList,
    OpenAgents.Tools.GitHubRepoRead,
    OpenAgents.Tools.ConversationSearch,
    OpenAgents.Tools.ConversationRead,
    OpenAgents.Tools.MemoryList,
    OpenAgents.Tools.MemorySearch,
    OpenAgents.Tools.MemoryRemember,
    OpenAgents.Tools.MemoryCorrect,
    OpenAgents.Tools.MemoryForget,
    OpenAgents.Tools.ComputerList,
    OpenAgents.Tools.ComputerProbe,
    OpenAgents.Tools.ComputerRun,
    OpenAgents.Tools.ComputerDevin,
    OpenAgents.Tools.ComputerAgent,
    OpenAgents.Tools.DeepWork,
    OpenAgents.Tools.IncidentLookup,
    OpenAgents.Tools.RepoRead,
    OpenAgents.Tools.RepoGrep,
    OpenAgents.Tools.RepoList,
    OpenAgents.Tools.CodeCheck,
    OpenAgents.Tools.RepoEdit,
    OpenAgents.Tools.RepoWrite,
    OpenAgents.Tools.RepoCommitPush
  ],
  conversation_reset_enabled: false,
  github_api: [
    base_url: "https://api.github.com",
    request_options: []
  ],
  github_oauth_scopes: ["repo"],
  voice_recording: [
    enabled: false,
    timeslice_ms: 5_000,
    maximum_chunk_bytes: 1_048_576,
    maximum_chunks: 1_024,
    maximum_bytes: 25_165_824,
    late_chunk_grace_seconds: 120,
    retention_days: 30
  ],
  leaderboard_limit: 100,
  leaderboard_refresh_interval_ms: 1_000,
  leaderboard_auto_refresh_enabled: true,
  voice_recovery_worker_enabled: false,
  voice_retention_worker_enabled: false,
  turn_recovery_enabled: false,
  voice_retention_enabled: false,
  ra_enabled: false,
  ra_data_dir: "/var/lib/openagents/ra",
  ra_expected_size: 3,
  horde_enabled: true,
  distribution: [
    enabled: false,
    node_configured: false,
    cookie_configured: false,
    port_min: 9_100,
    port_max: 9_115
  ],
  incident_fixer_enabled: false,
  github_oauth: [
    client_id: nil,
    client_secret: nil,
    redirect_uri: "http://127.0.0.1:4000/auth/github/callback",
    attempt_ttl_seconds: 600,
    request_options: []
  ],
  github_token_encryption_key: nil,
  github_token_encryption_key_id: nil,
  github_token_decryption_keys: %{},
  voice_recording_encryption_key: nil,
  inference_proxy_url: nil,
  inference_grant_max_total_tokens: 2_000_000,
  inference_grant_max_calls: 64,
  inference_grant_max_cost_microusd: 5_000_000,
  inference_grant_ttl_seconds: 900,
  inference_input_price_microusd_per_ktoken: 1_250,
  inference_output_price_microusd_per_ktoken: 10_000,
  forge_enabled: false,
  forge_boot_converge_enabled: false,
  forge_deploy_lane_enabled: false,
  forge_data_dir: "/var/lib/openagents/forge",
  forge_build_dir: "/var/lib/openagents/workspace/build",
  forge_build_queue_dir: "/var/lib/openagents/workspace/build-queue",
  forge_artifact_dir: "/var/lib/openagents/artifacts",
  forge_artifact_store: :local,
  forge_build_executor: OpenAgents.Forge.BuildExecutor.Sidecar,
  forge_expected_fleet_size: 1,
  forge_repos: ["openagents.com"],
  forge_internal_git_url: "http://127.0.0.1:8080/git",
  forge_operator_token: nil,
  forge_mirror_urls: %{},
  forge_wal_adapter: OpenAgents.Forge.WAL.Local,
  forge_wal_dir: nil,
  forge_wal_bucket: nil,
  forge_gcs_token_provider: nil,
  # Hot-load allowlist: MODULE names, not repo paths. An entry ending in `.`
  # is a prefix; any other entry is an exact module name (see
  # `OpenAgents.Forge.HotLoader.allowlisted?/2`). The narrow list was never
  # the safety — the canary node + smoke check + revert is — so the code-only
  # web layer ships in seconds instead of a ~25 minute rolling replace.
  forge_hot_load_allowlist: [
    "OpenAgentsWeb.",
    "OpenAgents.Forge.Browse",
    "OpenAgents.Changelog",
    "OpenAgents.Scratch.",
    "OpenAgents.BuildInfo"
  ],
  forge_hot_load_examples: %{
    "OpenAgentsWeb.ChatLive" => true,
    "OpenAgents.Accounts" => false
  },
  forge_public_visibility: %{"openagents.com" => :l3},
  forge_repo_owners: %{"openagents.com" => "OpenAgentsInc"},
  forge_public_paths: %{"openagents.com" => []},
  dns_cluster_query: nil

# Configure the endpoint
config :openagents, OpenAgentsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: OpenAgentsWeb.ErrorHTML, json: OpenAgentsWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: OpenAgents.PubSub,
  live_view: [signing_salt: "VjtdwdCq"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :openagents, OpenAgents.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  openagents: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  openagents: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
