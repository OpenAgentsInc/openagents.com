# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :openagents,
  namespace: OpenAgents,
  ecto_repos: [OpenAgents.Repo],
  generators: [timestamp_type: :utc_datetime],
  conversation_page_size: 25,
  maximum_message_bytes: 8192,
  turn_rate_limit: 50,
  admin_github_ids: [],
  computer_controller_enabled: false,
  work_workers_enabled: false,
  work: [enabled: false],
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
  voice_compaction_input_token_threshold: 16_000

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
