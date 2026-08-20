import Config

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
  client_id: "test-client-id",
  client_secret: "test-client-secret",
  redirect_uri: "http://localhost:4002/auth/github/callback"

config :openagents,
       :github_token_encryption_key,
       Base.encode64("openagents-test-token-vault-key3")

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

config :openagents, :migrate_on_boot, false
config :openagents, :ra_enabled, false
