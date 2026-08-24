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
  runtime_role: :web,
  staging_gate: 0,
  staging_cleanup_enabled: false,
  production_deploy_enabled: false,
  repository_provisioner_enabled: true,
  build_revision: "image",
  image_digest: nil,
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
  posthog_project_token: nil,
  posthog_api_host: "https://us.i.posthog.com",
  posthog_analytics: [
    personal_api_key: nil,
    project_id: nil,
    app_host: "https://us.posthog.com"
  ],
  work_workers_enabled: false,
  work: [enabled: false],
  scv_codex: [
    enabled: false,
    execution_reaper_enabled: false,
    executable: "/usr/local/bin/codex",
    credential_store: OpenAgents.SCV.CodexCredentialStore.File,
    credential_refs: ["file:operator-1"],
    file_root: "/var/lib/openagents/scv/codex-accounts",
    temporary_root: System.tmp_dir!(),
    client_options: []
  ],
  scv_deploy: [
    enabled: false,
    model: "opencode/x-preview-f-free",
    reasoning_effort: "low",
    opencode_api_key: nil,
    executable: nil,
    concurrency_limit: 2,
    wall_clock_ms: 900_000,
    maximum_output_bytes: 16_777_216,
    output_root: "/var/lib/openagents/scv/opencode-runs"
  ],
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
  openrouter_api_key: nil,
  openrouter_model: "stealth/ox-alpha",
  gemini_api_key: nil,
  gemini_model: "gemini-3.7-flash",
  box_api_key: nil,
  box_api: [
    base_url: "https://ascii.dev/api/box/v1",
    ownership_marker: nil,
    reconciliation_receive_timeout_ms: 15_000,
    maximum_active_boxes: 10,
    default_maximum_active_boxes: 2,
    maximum_active_boxes_per_owner: 4,
    maximum_active_boxes_global: 20,
    estimated_burn_rate_per_box_hour_microusd: 100_000,
    maximum_burn_rate_per_conversation_microusd: 1_000_000,
    maximum_burn_rate_per_owner_microusd: 5_000_000,
    ttl_seconds: 3_600,
    idle_timeout_seconds: 1_800,
    reconciliation_interval_ms: 60_000,
    poll_interval_ms: 1_000,
    poll_attempts: 60,
    run_poll_interval_ms: 1_000,
    run_max_duration_seconds: 1_800,
    run_create_rate_limit: 10,
    run_command_rate_limit: 30,
    rate_limit_window_seconds: 60,
    create_rate_limit: 10,
    command_rate_limit: 30
  ],
  # The provider does not report a context window, so the `/chat` console shows
  # a context meter only where a deployment states one.
  openrouter_context_window: nil,
  # An override for the `/chat` streaming function. Tests set it; nothing else
  # does, so the console reaches OpenRouter everywhere else.
  chat_console_streamer: nil,
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
  # The shipped tool catalog. It is a zero base, deliberately small.
  #
  # A tool ships only when it meets every admission criterion in
  # `docs/2026-08-23-agent-tools-zero-base.md`, section 6. The short form:
  # it is read-only, it works for every caller that can see it, its refusal
  # path has a test, its description says when not to use it, and it earns
  # its place in the prompt budget. `test/openagents/tools/shipped_catalog_test.exs`
  # enforces the mechanical half; the rest is review.
  #
  # Every other tool module stays in `lib/openagents/tools/` and stays under
  # test through the broader fixture catalog in `config/test.exs`. Unregistered
  # is not deleted. Adding a module back here is a policy change, not a
  # one-line edit.
  tools: [
    # Discovery. The escape hatch that lets the model see the catalog it was
    # given. Needs only the captured registry snapshot, so it never refuses.
    OpenAgents.Tools.ModuleDiscover,

    # Read this application's own source. `from: "image"` resolves to the
    # baked source root and needs no owner, workspace, or job, so these
    # answer "what does your code do" for every caller.
    OpenAgents.Tools.RepoRead,
    OpenAgents.Tools.RepoGrep,
    OpenAgents.Tools.RepoList,

    # Read a forge repository the signed-in person can see. These resolve
    # through `owner_user_id`, the one owner field every conversation caller
    # populates correctly today.
    OpenAgents.Tools.ConnectedRepositoryRead,
    OpenAgents.Tools.ConnectedRepositoryList
  ],
  conversation_reset_enabled: false,
  github_api: [
    base_url: "https://api.github.com",
    request_options: []
  ],
  github_oauth_scopes: ["repo", "read:org"],
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
  deployment_control_plane_enabled: false,
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
  # A thread's budget is not a delegation's budget, so it does not borrow one.
  # A delegation is a single bounded probe run the server admitted before it
  # minted anything; a thread is authority handed to a caller's own terminal on
  # request, and it lives as long as someone is working. It therefore gets more
  # calls and a longer life, and a lower token and cost ceiling, because
  # nothing on the server bounded the work first.
  #
  # `maximum_open_threads_per_account` is the admission cap. Eight open threads
  # is a person working several checkouts at once, and THREAD-001 admits at
  # most one live grant per open thread, so the account's concurrent
  # thread-scoped authority is bounded by eight of the ceilings below.
  maximum_open_threads_per_account: 8,
  thread_grant_max_total_tokens: 1_000_000,
  thread_grant_max_calls: 256,
  thread_grant_max_cost_microusd: 2_000_000,
  thread_grant_ttl_seconds: 3_600,
  inference_input_price_microusd_per_ktoken: 1_250,
  inference_output_price_microusd_per_ktoken: 10_000,
  forge_enabled: false,
  forge_boot_converge_enabled: false,
  forge_deploy_lane_enabled: false,
  forge_data_dir: "/var/lib/openagents/forge",
  forge_build_dir: "/var/lib/openagents/workspace/build",
  forge_build_queue_dir: "/var/lib/openagents/workspace/build-queue",
  forge_artifact_dir: "/var/lib/openagents/artifacts",
  forge_build_timeout_ms: 300_000,
  forge_build_output_retention_ms: 604_800_000,
  forge_deploy_timeout_ms: 15_000,
  forge_deploy_token_ttl_ms: 120_000,
  forge_boot_retry_min_ms: 1_000,
  forge_boot_retry_max_ms: 30_000,
  forge_artifact_store: :local,
  forge_build_executor: OpenAgents.Forge.BuildExecutor.Sidecar,
  forge_expected_fleet_size: 1,
  forge_repos: ["openagents.com"],
  forge_internal_git_url: "http://127.0.0.1:8080/OpenAgentsInc",
  forge_operator_token: nil,
  forge_mirror_urls: %{},
  forge_wal_adapter: OpenAgents.Forge.WAL.Local,
  # The published WAL anchor (EXIT-005, ADR 0008). The interval is also the
  # anchor's exposure window: everything pushed after the last anchor is
  # unanchored until the next one.
  forge_wal_anchor_enabled: true,
  forge_wal_anchor_interval_ms: 3_600_000,
  forge_wal_dir: nil,
  forge_wal_bucket: nil,
  forge_gcs_token_provider: nil,
  forge_rolling_provider: nil,
  # Hot-load allowlist: MODULE names, not repo paths. An entry ending in `.`
  # is a prefix; any other entry is an exact module name (see
  # `OpenAgents.Forge.HotLoader.allowlisted?/2`). The narrow list was never
  # the safety — the canary node + smoke check + revert is — so the code-only
  # web layer ships in seconds instead of a ~25 minute rolling replace.
  forge_hot_load_allowlist: [
    "OpenAgentsWeb.",
    "OpenAgents.Forge.Browse",
    "OpenAgents.Forge.MirrorWatch",
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

# Product analytics (docs/2026-08-21-posthog-integration-runbook.md). The
# default supervisor stays off; OpenAgents.Application starts PostHog.Supervisor
# only when a project token was configured at boot. Error tracking is a
# separate, unapproved decision, so exception capture is off.
config :posthog,
  enable: false,
  api_host: "https://us.i.posthog.com",
  api_key: nil,
  in_app_otp_apps: [:openagents],
  enable_error_tracking: false

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

# Forum tips are off until an operator admits a self-custodial payment service.
# Tipping stays unavailable rather than routing sats through hosted custody.
config :openagents, :forum_tips,
  enabled: false,
  adapter: OpenAgents.Forum.Tips.PaymentService.Unavailable

config :openagents, OpenAgents.Capacity,
  evidence_source: OpenAgents.Capacity.Broker,
  broker_url: nil,
  broker_token: nil,
  broker_timeout_ms: 2_000,
  maximum_evidence_age_seconds: 120,
  reserved_headroom_fraction: 0.25,
  class_ceilings: %{"standard" => 16, "strong" => 2, "batch" => 8},
  active_per_conversation: 4,
  logical_per_conversation: 30,
  unit_cost_usd_cents_per_hour: %{
    "standard" => 16,
    "strong" => 32,
    "batch" => 8,
    "connected" => 0
  },
  buyer: nil

# Continual learning is off until an operator admits the named buyer, the base
# models, and the exact training code digest. The lane refuses rather than
# training on data or a model nobody admitted.
config :openagents, OpenAgents.ContinualLearning,
  enabled: false,
  buyer_ref: nil,
  buyer_class: "openagents_training",
  runtime_classes: ["standard", "strong"],
  admitted_base_models: %{},
  admitted_custody: ["openagents_managed"],
  maximum_rounds: 8,
  maximum_datasets: 4,
  wall_clock_ms: 900_000,
  maximum_state_bytes: 65_536,
  concurrency_limit: 1,
  training_code_digest: nil,
  trainer: OpenAgents.ContinualLearning.Trainer.Reference,
  evaluator: OpenAgents.ContinualLearning.Evaluator.Reference,
  class_watts: %{"standard" => 350, "strong" => 700, "batch" => 250},
  round_cost_usd_cents: %{"standard" => 2, "strong" => 4, "batch" => 1},
  settlement_unit: "usd_cents",
  outcome_repository: "OpenAgentsInc/openagents.com",
  outcome_issue_number: 86

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
