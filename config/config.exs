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
  # The durable effect outbox (EFFECT-001). The table is always written; the
  # worker that drains it is what this gates, because a host that should not
  # execute effects must not claim one.
  effects: [
    worker_enabled: false,
    interval_ms: 1_000,
    batch_limit: 20,
    lease_seconds: 120,
    backoff_base_ms: 1_000,
    backoff_ceiling_ms: 300_000
  ],
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
  openrouter_provider: OpenAgents.Providers.OpenRouter,
  vercel_gateway_provider: OpenAgents.Providers.VercelGateway,
  openai_model: "gpt-5.6-luna",
  openai_api_key: nil,
  openrouter_api_key: nil,
  # The OpenRouter spelling of GLM 5.3 Flash. `stealth/ox-alpha` was this same
  # model under its pre-launch name, and OpenRouter now answers that slug with
  # a 404 that says so. Note the hyphen: OpenRouter writes the creator
  # `z-ai`, the Vercel gateway writes it `zai`, and the two are not
  # interchangeable.
  openrouter_model: "z-ai/glm-5.3-flash",
  # The typed model catalog (`OpenAgents.Inference.Models`, PROVIDER-002):
  # every model this deployment serves, in the order a client should offer
  # them; the first entry is the default. `id` is the public name a caller
  # asks for, `provider_model` the string the vendor is called with, and
  # either may be `{:config, key}` to follow a runtime-configurable value.
  # `provider` names a lane whose adapter module and credential are configured
  # separately, so no secret lives here; a lane whose credential is absent is
  # listed as unavailable, never silently substituted. `max_output` is the
  # per-call output cap the proxy's adapters send for that model, and
  # `context_window` is the ceiling this deployment publishes for the lane.
  #
  # A model may declare a `pricing` map with `input_per_million_tokens`,
  # `output_per_million_tokens`, and optionally `cached_input_per_million_tokens`.
  # A pricing map also names itself: `id` is the rate table every usage record
  # priced against it stamps as `pricing_id`, and `source` is where the rates
  # came from — `:declared` for a provider's published rates, anything else
  # (including omitting it) for a working figure. `OpenAgents.Inference.Pricing`
  # reads that word, and only `:declared` is billable (METER-001).
  #
  # Every rate below is a placeholder: no operator has declared any of them, so
  # all of them say `:placeholder` and nothing may bill from a cost they
  # produced. Replacing them is an owner action: enter the provider's rates and
  # set `source: :declared` in the same edit.
  #
  # The GLM 5.3 Flash figures are the ones to be careful with. Its posted rates
  # on 2026-08-26 were $0.075 in, $0.25 out, and $0.015 cached in per million
  # tokens — a limited-time half-price offer that ends 2026-09-09 16:00 UTC,
  # after which list price is $0.15, $0.50, and $0.03. The entry carries list
  # price, because a figure that silently doubles in two weeks is worse than
  # one that is honestly high, and because neither figure is declared either
  # way. The Gemini figures were written to make the system run and were not
  # read off any price page.
  #
  # A model with no `pricing` key records no estimated cost at all — not a zero
  # — and its usage records stamp `pricing_id: "unpriced"`. No entry below is in
  # that state now that `gpt-5.6-luna` has been withdrawn, but the state is
  # still reached: a call the gateway's fallback chain rescues is answered by a
  # model this catalog does not admit and therefore has no rates. Every read
  # surface says `unpriced` rather than `$0.00`.
  #
  # This list is exactly three models, and a caller may spend nothing else. A
  # model absent from it cannot be minted a grant (`OpenAgents.Inference.mint/1`
  # refuses the name) and cannot be called on a grant minted before it was
  # withdrawn (`OpenAgentsWeb.InferenceProxyController` refuses
  # `model_unavailable`). Withdrawing an entry is therefore a real withdrawal
  # rather than a hidden one.
  #
  # GLM 5.3 Flash leads, so it is what a caller that names none gets: a million
  # tokens of context, and cheap enough per token to hold an ordinary
  # conversation on a model that reasons before it answers. Its thinking is
  # charged against `max_output` before a word of the answer is — a 256-token
  # allowance was spent 243 tokens deep in reasoning and the answer was cut off
  # mid-word on `finish_reason: "length"` — so the allowance below is the
  # ceiling the gateway publishes for the lane rather than a modest figure.
  #
  # `ox-alpha`, which used to be listed here on the OpenRouter lane, was this
  # same model under its pre-launch name. OpenRouter now answers
  # `stealth/ox-alpha` with a 404 saying so, which is why it is gone rather
  # than demoted: there was never a second model to keep. The old public id
  # deliberately does not resolve to the new entry — silently answering a
  # withdrawn name with a survivor is what PROVIDER-002 forbids.
  #
  # Gemini 3.7 Flash is second: fast, a million tokens of context, and steady
  # enough to hold a conversation. It led this list until GLM 5.3 Flash was
  # added.
  #
  # The first two entries are on `:vercel_gateway`. `openrouter/free` is the
  # independent Coder Free lane, and it remains available when the gateway is
  # unavailable. OpenRouter limits that router to free models, so its declared
  # per-token rates are zero even though the selected provider model can vary.
  #
  # `vercel_gateway_fallback_models` below is a different list and it still ends
  # with `openai/gpt-5.6-luna`, deliberately. That is the gateway's own ordered
  # chain, tried inside a single call when the requested model fails, and it is
  # not a menu: nobody selects a model from it. Luna sitting last in it is the
  # backstop of a backstop. Withdrawing Luna from this catalog means no caller
  # can choose it; it does not mean the gateway may never fall back to it.
  #
  # A call the chain rescues is still attributed honestly. The adapter reads the
  # serving model back off the response, so a call answered by a model this
  # catalog does not admit records no price at all — `pricing_id: "unpriced"` —
  # rather than being charged at the rates of the model that was asked for
  # (METER-001, PROVIDER-002).
  model_catalog: [
    %{
      id: "glm-5.3-flash",
      # Through the Vercel gateway, which resolves the slug to z.ai and calls
      # it with the BYOK z.ai credentials this account holds there. The
      # `providerOptions.gateway.order` pin below names Vertex, which does not
      # serve this model; the gateway reports `"planningReasoning":"BYOK
      # credentials available for: zai"` and routes to z.ai anyway, so the pin
      # costs this lane nothing.
      provider: :vercel_gateway,
      provider_model: "zai/glm-5.3-flash",
      # A million, per z.ai's listing and the gateway's. OpenRouter publishes
      # 1,048,576 for the same model; a million is the smaller of the two and
      # the number the serving lane states.
      context_window: 1_000_000,
      # The gateway's published ceiling for this lane. It has to be large: the
      # model reasons against this allowance, so a small one is spent thinking
      # and the caller is handed a truncated answer on a 200.
      max_output: 131_000,
      # The declared promotion makes this lane free until the exclusive UTC
      # cutoff, after which pricing automatically returns to the regular table
      # without another deployment.
      pricing: %{
        id: "declared.glm-5.3-flash.v1",
        source: :declared,
        input_per_million_tokens: 150_000,
        output_per_million_tokens: 500_000,
        cached_input_per_million_tokens: 30_000,
        promotion: %{
          id: "declared.glm-5.3-flash.free-through-2026-08-31.v1",
          source: :declared,
          ends_at: ~U[2026-09-01 00:00:00Z],
          input_per_million_tokens: 0,
          output_per_million_tokens: 0,
          cached_input_per_million_tokens: 0
        }
      }
    },
    %{
      id: "gemini-3.7-flash",
      # Through the Vercel gateway, pinned to Vertex, so the call lands on
      # Google's hardware and spends this account's Google credits. OpenRouter
      # serves the same model and that lane worked, but its credits are not
      # these credits.
      provider: :vercel_gateway,
      provider_model: "google/gemini-3.7-flash",
      context_window: 1_048_576,
      max_output: 65_536,
      # Placeholder: the operator must set real provider rates and flip `source`
      # to `:declared` before anything bills from this. The cached-input rate is
      # optional and should be omitted if the provider does not offer one.
      pricing: %{
        id: "placeholder.gemini-3.7-flash.v1",
        source: :placeholder,
        input_per_million_tokens: 1_250_000,
        output_per_million_tokens: 10_000_000,
        cached_input_per_million_tokens: 100_000
      }
    },
    %{
      # The Coder Free lane resolves this exact fallback after checking for a
      # deployment-specific preferred free model. OpenRouter selects a current
      # free model behind this router id, so callers cannot be promised one
      # vendor context window. Its route only selects zero-price models.
      id: "openrouter/free",
      provider: :openrouter,
      provider_model: "openrouter/free",
      context_window: 32_768,
      max_output: 8_192,
      pricing: %{
        id: "declared.openrouter-free.v1",
        source: :declared,
        input_per_million_tokens: 0,
        output_per_million_tokens: 0,
        cached_input_per_million_tokens: 0
      }
    }
  ],
  gemini_api_key: nil,
  vercel_gateway_api_key: nil,
  # Try Vertex first for every model it serves here. The same Gemini slug is
  # also served by `google` — the Generative Language endpoint, which is not
  # where this account's credits are — but the fallback models are not on
  # Vertex, so Vercel may try other providers for them.
  vercel_gateway_providers: ["vertex"],
  # The gateway's ordered fallback chain, tried within one call when the
  # requested model fails. `zai/glm-5.3-flash` leads it because it is the only
  # entry this deployment also admits in `:model_catalog`: a rescued call that
  # lands on an admitted model is priced and attributed normally, and every
  # other entry here records no price at all. `openai/gpt-5.6-luna` stays last
  # at owner direction — it is the backstop of a backstop, reachable only
  # automatically and selectable by nobody.
  vercel_gateway_fallback_models: [
    "zai/glm-5.3-flash",
    "zai/glm-5.3",
    "zai/glm-5.2",
    "openai/gpt-5.6-luna"
  ],
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
  # Cloud memories (`OpenAgents.Memories`). `embeddings_enabled` chooses the
  # target retrieval backend; with it off, recall runs on the lexical stand-in.
  # The three bounds are the store's ceiling per account and the per-turn
  # ceilings on how much memory may reach the model.
  #
  # `system_bucket_enabled` is the cross-account switch, and it is off here and
  # in production. With it off, recall reads the `user` and `learned` buckets
  # and nothing else, exactly as it did before the system bucket existed. With
  # it on, an admitted system memory written by one account reaches every
  # account's turn under the eligibility filter and the caps in
  # `OpenAgents.Memories.SystemRecall` (MEMORY-001, MEMORY-011).
  # `maximum_system_pool` bounds the ranked candidate pool the per-source cap
  # is a share of.
  memory_recall: [
    embeddings_enabled: false,
    system_bucket_enabled: false,
    maximum_system_pool: 40,
    provider: OpenAgents.Memory.OpenAIEmbeddings,
    model_id: "text-embedding-3-small",
    model_version: "2024-01",
    dimensions: 64,
    floor: 0.3,
    maximum_live_memories: 200,
    maximum_attached: 8,
    maximum_attached_characters: 2_000
  ],
  tool_discovery: [
    embeddings_enabled: false,
    provider: OpenAgents.Memory.OpenAIEmbeddings,
    model_id: "text-embedding-3-small",
    model_version: "2024-01",
    dimensions: 64,
    top_k: 12
  ],
  plugin_discovery: [
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
    OpenAgents.Tools.ConnectedRepositoryList,

    # File a request the person made in chat as an issue, in a repository they
    # can write to (#77). The one tool here that is not read-only, and the
    # reason TOOL-006 now says "read-only, or gated on a current consent
    # receipt" rather than "read-only". It declares `:external_effect` with
    # `approval_enforcement: "host_receipt"`, so `SurfacePolicy` demands an
    # explicit, current, person-signed receipt bound to this module, version,
    # and conversation — checked when the catalog is built as well as when the
    # tool runs. On a turn with no such receipt it is not offered, so it costs
    # nothing and never trains anyone to ignore a refusal. Authority stays the
    # caller's: it files under their own repository membership.
    OpenAgents.Tools.IssueCapture
  ],
  conversation_reset_enabled: false,
  github_api: [
    base_url: "https://api.github.com",
    request_options: []
  ],
  github_oauth_scopes: ["user:email"],
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
  machine_token_encryption_key: nil,
  voice_recording_encryption_key: nil,
  content_encryption_key: nil,
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
  # No cap. A coder session no longer revokes its thread when it exits — a
  # thread is durable and `--resume` is the whole point of that — so a count of
  # open threads is a count of every session the account has ever run, and
  # refusing the ninth would refuse the work rather than bound it. What bounds
  # an account is its credit.
  maximum_open_threads_per_account: nil,
  # Unbounded, all three. A coding session reached 256 calls, a million tokens,
  # and two dollars in an afternoon, and was told to start a new session — the
  # same interruption the clock below used to cause, by another route. A
  # thread is bounded by revocation and by the account's credit.
  thread_grant_max_total_tokens: nil,
  thread_grant_max_calls: nil,
  thread_grant_max_cost_microusd: nil,
  # No clock on a thread's authority. It expiring on a wall clock ended a
  # coding session mid-sentence and told the reader to start a new one, when
  # nothing had gone wrong except that an hour had passed. Budget and
  # revocation bound a thread; time does not.
  thread_grant_ttl_seconds: nil,
  # The inference credit an account draws its threads against. Signing in is
  # what raises it: a visitor holding only a browser key gets the same figure a
  # single thread used to get, and an account with a user behind it gets $20 to
  # spend across every thread it opens.
  #
  # This figure is the default a *new* account is created with, not the
  # allowance every account holds. The allowance lives on `users` as
  # `credit_allowance_microusd`, so lowering this number re-prices the next
  # signup rather than every account that already exists — the accounts created
  # while it read $100 still hold $100. `OpenAgents.Inference.Credit` reads the
  # column; only account creation reads this.
  account_credit_microusd: 20_000_000,
  visitor_credit_microusd: 2_000_000,
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
  # The bucket behind `/releases/<name>`. It grants every object to `allUsers`,
  # so the proxy needs no credential — the name is deployment policy, not a
  # secret, and it has a default so a development server serves the same
  # artifacts production does.
  releases_bucket: "openagentsgemini-cli-releases",
  # The seam `test/openagents_web/controllers/release_controller_test.exs`
  # stubs. Empty everywhere else, so the request options the controller builds
  # are the ones that reach the bucket.
  releases_request_options: [],
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

# The notification email channel (#141).
#
# `deliverable` is what the settings surface asks before it offers to take an
# address, and it is set here rather than inferred from the Swoosh adapter,
# because the adapter answers the question wrongly in both directions: the
# local adapter is real delivery in development, where the message lands in the
# mailbox preview at "/dev/mailbox", and it is a black hole in production.
# `config/prod.exs` turns it off, and `config/runtime.exs` turns it back on for
# a deployment that configured a provider.
config :openagents, OpenAgents.Notifications.EmailChannel,
  from: {"OpenAgents", "notifications@openagents.com"},
  deliverable: true

config :openagents, OpenAgents.Notifications.Delivery,
  adapter: OpenAgents.Notifications.Delivery.MailerAdapter

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
