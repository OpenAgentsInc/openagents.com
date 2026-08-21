import Config

config :openagents, :repository_provisioner_enabled, false

config :openagents, :runtime_environment, :test

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :openagents, OpenAgents.Repo,
  username: System.get_env("USER") || "christopherdavid",
  password: "",
  socket_dir: "/tmp",
  database: "openagents_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Test-only GitHub OAuth and vault keys. GitHub is mocked in tests.
config :openagents, :github_oauth,
  client_id: "test-github-client-id",
  client_secret: "test-github-client-secret",
  redirect_uri: "http://127.0.0.1:4002/auth/github/callback"

config :openagents,
       :github_token_encryption_key,
       Base.encode64("openagents-test-token-vault-key3")

config :openagents, :github_token_encryption_key_id, "test-2026-08"
config :openagents, :github_token_decryption_keys, %{}

# Test fakes for providers and voice sideband so the suite never reaches the network.
config :openagents, :provider, OpenAgents.Providers.Test
config :openagents, :voice_call_provider, OpenAgents.Voice.TestCallProvider
config :openagents, :voice_sideband_provider, OpenAgents.Voice.TestSidebandProvider

# No project token is configured in tests, so OpenAgents.Analytics is a no-op.
# test_mode additionally drops any event that reaches the package directly.
config :posthog, test_mode: true

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :openagents, OpenAgentsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Qg1oZEw1M0GnySDRZ1qJJRZltEFZUQGzBDGsfaLxgKA1EowbYm9EDSYYznEsY8KE",
  server: false

# In test we don't send emails
config :openagents, OpenAgents.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# The forge runs for real in the test suite — real git over real HTTP against
# a temporary data dir — so the pipeline is proven end to end without a network
# or a hosted git server. `demo` is the throwaway repo the e2e tests push to.
# The deploy lane is off by default: the tests that exercise it start
# `OpenAgents.Forge.HotLoader` themselves.
config :openagents,
  forge_enabled: true,
  forge_repos: ["openagents.com", "demo"],
  forge_operator_token: "forge_test_operator_token_0123456789",
  forge_deploy_lane_enabled: false,
  forge_repo_owners: %{"openagents.com" => "OpenAgentsInc", "demo" => "OpenAgentsInc"}

config :openagents, :migrate_on_boot, false
config :openagents, :ra_enabled, false

config :openagents, :computer_controller_enabled, true

config :openagents, :scv_codex,
  enabled: true,
  execution_reaper_enabled: false,
  executable: Path.expand("../test/support/fake_codex_app_server.sh", __DIR__),
  credential_store: OpenAgents.SCV.CodexCredentialStore.File,
  credential_refs: ["file:test-operator-1", "file:test-operator-2"],
  file_root: Path.join(System.tmp_dir!(), "openagents-codex-test-credentials"),
  temporary_root: System.tmp_dir!(),
  client_options: []

config :openagents, :voice_recording_encryption_key, Base.encode64(:crypto.strong_rand_bytes(32))

config :openagents, :voice_recording,
  enabled: true,
  timeslice_ms: 5_000,
  maximum_chunk_bytes: 1_048_576,
  maximum_chunks: 1_024,
  maximum_bytes: 25_165_824,
  late_chunk_grace_seconds: 120,
  retention_days: 30

config :openagents, :tools, [
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
  OpenAgents.Tools.RepoCommitPush,
  OpenAgents.Tools.TestRecall
]
