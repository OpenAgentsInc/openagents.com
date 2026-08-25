# Runtime configuration

Date: 2026-08-22

Status: Current

`OpenAgents.RuntimeConfig` is the single typed boundary for behavior-changing
runtime settings. It runs before migrations, workers, or the endpoint. Invalid
configuration raises a diagnostic containing only the setting name and its
requirement; it never echoes a value.

Deployed releases require `OPENAGENTS_ENVIRONMENT=staging` or `production`.
Production startup fails closed unless
`OPENAGENTS_PRODUCTION_DEPLOY_ENABLED=true`. The production cutover recorded
that decision on 2026-08-21; a new environment must still set the value
explicitly and satisfy the rest of this contract.

## Readiness report

Print the report without starting the application:

```console
MIX_ENV=test mix openagents.config.readiness
```

For an assembled release, run:

```console
bin/config-readiness
```

The JSON report contains only the environment class, staging-gate number,
feature booleans, and ready status for the endpoint, database, GitHub,
providers, features, forge, and cluster groups. It never contains credentials,
URLs, hosts, repository paths, bucket names, node names, or tokens.

Application startup performs two additional behavioral checks before the
endpoint starts:

- If tools are enabled, the installed executable tool catalog must be nonempty.
- Every `forge_hot_load_examples` entry must produce its configured allow or
  deny result under the actual hot-load allowlist.

## Process roles

`OPENAGENTS_RUNTIME_ROLE` selects the supervision tree in an assembled release.
The setting accepts these values:

| Value | Behavior |
| --- | --- |
| `web` | Default. Validates the complete web release configuration and starts the endpoint, Repo, Forge, and enabled application services. |
| `scv` | Staging-only qualification role. Requires a provider credential and starts one temporary `OpenAgents.SCV.Worker` task. It starts no endpoint, Repo, Forge service, or deployment coordinator. |
| `builder` | Isolated Forge build-image role. Loads compiled modules for the queue worker without starting the application, endpoint, Repo, or deployment coordinator. |

The current SCV process role admits only the `opencode` driver,
`opencode-core` environment, and `read_only` permission profile. Configure one
run with these settings:

| Environment setting | Requirement |
| --- | --- |
| `SCV_REPOSITORY` | Absolute repository path inside the environment; defaults to `/workspace/openagents` in the first image |
| `SCV_OBJECTIVE` | Bounded objective for one run; required |
| `SCV_DRIVER` | `opencode` |
| `SCV_ENVIRONMENT` | `opencode-core` |
| `SCV_PERMISSION_PROFILE` | `read_only` |
| `SCV_MODEL` | Admitted OpenCode model identifier |
| `SCV_REASONING_EFFORT` | `low` by default; `none` is also admitted |
| `SCV_REPOSITORY_REVISION` | Exact 40-character lowercase Git SHA baked into the image |
| `SCV_RUN_ID` | Optional externally assigned UUID; the worker generates one when omitted |
| `SCV_TIMEOUT_MS` | Wall-clock limit for the OpenCode process |
| `SCV_HEARTBEAT_INTERVAL_MS` | Resource and liveness event interval |
| `SCV_DIAGNOSTIC_LOGS` | `true` to emit bounded redacted diagnostic records; otherwise `false` |

The process writes versioned SCV events and one terminal worker result as JSON
lines. Do not mount database, GitHub, Forge, release-cookie, deployment, or
general cloud credentials into this role. A provider key is a temporary
qualification mechanism; replace it with a run-scoped inference grant before
admitting repository writes.

## Operator Codex account settings

The web role can enable a restricted operator surface for connecting individual
Codex accounts. This surface starts a temporary Codex app-server only for the
device ceremony, verifies the admitted model and reasoning efforts, and writes
the resulting managed credential to a configured credential slot. It never
stores the credential value in PostgreSQL.

| Environment setting | Requirement |
| --- | --- |
| `OPENAGENTS_FEATURE_SCV_CODEX` | `true` to enable the operator connection surface; otherwise `false` or empty |
| `OPENAGENTS_SCV_CODEX_CREDENTIAL_STORE` | `gcp_secret_manager` in staging; `file` is allowed only for local development and tests |
| `OPENAGENTS_SCV_CODEX_CREDENTIAL_REFS` | Comma-separated, preallocated credential-slot references; required when the feature is enabled |
| `OPENAGENTS_SCV_CODEX_BIN` | Absolute path to the pinned Codex executable; the release image uses `/usr/local/bin/codex` |
| `OPENAGENTS_SCV_CODEX_FILE_ROOT` | Local credential directory used only with the `file` store |

Each successful connection creates an immutable secret version and records only
its reference and numeric version. Grant the web identity version-add and
exact-version-read access only to the configured slots. Do not grant the web
identity access to unrelated SCV, Forge, or deployment credentials.

Implement ChatGPT service accounts after this individual operator flow passes
qualification. Service accounts are available only for pay-as-you-go plans.

## SCV deployment settings

The `scv_deploy` feature admits one bounded OpenCode run per SCV on OpenAgents
capacity, started only by an operator through `OpenAgents.SCV.Deployments`. See
INVARIANTS.md SCV-001. Bounds live in configuration rather than in a caller's
arguments, and the compiled defaults are the safe values.

| Environment setting | Requirement |
| --- | --- |
| `OPENAGENTS_FEATURE_SCV_DEPLOY` | `true` to admit the lane; otherwise `false` or empty |
| `OPENAGENTS_SCV_DEPLOY_MODEL` | Model slug as `provider/model`; defaults to the free OpenCode Zen model `opencode/x-preview-f-free` |
| `OPENAGENTS_SCV_DEPLOY_OPENCODE_BIN` | Absolute path to the pinned OpenCode executable; the release image uses `/usr/local/bin/opencode` |
| `OPENAGENTS_SCV_DEPLOY_OPENCODE_API_KEY` | Optional OpenCode gateway key; the default model runs without one |
| `OPENAGENTS_SCV_DEPLOY_OUTPUT_ROOT` | Durable directory for run artifacts; must not be under `/tmp` |
| `OPENAGENTS_SCV_TEMPORARY_ROOT` | Durable directory for SCV repository clones; must not be under `/tmp` when an SCV lane is enabled in staging or production |

The compiled defaults cap concurrency at two simultaneous SCVs, the wall clock
at 15 minutes, and captured output at 16 MB. The lane runs read-only against a
disposable clone of a forge repository at an exact revision.

## Required deployed-release settings

All settings in this section are mandatory in a staging or production release
unless marked conditional. An empty value is accepted only where the table
explicitly says "empty disables." Secrets come from the environment's secret
manager through the runtime identity; never put them in images, build
arguments, repository URLs, receipts, or checked-in environment files.

| Group | Environment setting | Requirement |
| --- | --- | --- |
| Release | `OPENAGENTS_ENVIRONMENT` | `staging` or `production` |
| Release | `OPENAGENTS_STAGING_GATE` | Integer `0` through `16`; feature admission is tied to it |
| Release | `OPENAGENTS_STAGING_CLEANUP_ENABLED` | `true` only at staging Gate 12 or later; always `false` elsewhere |
| Release | `OPENAGENTS_PRODUCTION_DEPLOY_ENABLED` | `true` only for an admitted production release; `false` in staging |
| Release | `OPENAGENTS_IMAGE_DIGEST` | Exact `sha256:` image digest in production and at staging Gate 12 or later; empty only before that staging gate |
| Endpoint | `PHX_HOST` | Exactly `staging.openagents.com` in staging; use the admitted public host in production |
| Endpoint | `OPENAGENTS_ALLOWED_ORIGINS` | Comma-separated exact HTTPS origins including the environment's `PHX_HOST` |
| Endpoint | `OPENAGENTS_HTTPS_ALIASES` | Comma-separated hostnames; empty means no aliases |
| Endpoint | `OPENAGENTS_SECURE_COOKIES` | `true` in staging and production |
| Endpoint | `SECRET_KEY_BASE` | Environment-specific secret |
| Endpoint | `PORT` | Port `1` through `65535` |
| Database | `OPENAGENTS_DATABASE_MODE` | `url` or `socket` |
| Database | `DATABASE_URL` | Required only in `url` mode |
| Database | `DB_USER`, `DB_PASSWORD`, `DB_NAME`, `INSTANCE_UNIX_SOCKET` | Required only in `socket` mode |
| Database | `OPENAGENTS_DATABASE_IPV6` | Explicit `true` or `false` |
| Database | `POOL_SIZE` | Integer `1` through `200` |
| Database | `OPENAGENTS_MIGRATE_ON_BOOT` | `true` in staging and production |
| GitHub | `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` | OAuth application credentials for the selected environment |
| GitHub | `GITHUB_REDIRECT_URI` | Exact HTTPS callback on `PHX_HOST` |
| GitHub | `GITHUB_OAUTH_SCOPES` | Exactly `repo,read:org`; repository import needs retained repository access and organization creation needs membership access |
| GitHub | `OPENAGENTS_ADMIN_GITHUB_IDS` | Comma-separated immutable numeric GitHub IDs allowed to use operator surfaces; never use logins |
| GitHub | `GITHUB_TOKEN_ENCRYPTION_KEY` | Base64-encoded 32-byte key for the selected environment |
| GitHub | `GITHUB_TOKEN_ENCRYPTION_KEY_ID` | Bounded active-key identifier prefixed with `development-`, `test-`, `staging-`, or `production-` to match the runtime |
| GitHub | `GITHUB_TOKEN_DECRYPTION_KEYS_JSON` | Optional map of at most 16 same-environment prior keys used only during rewrap; omit the active ID |
| Providers | `OPENAI_API_KEY` | Environment-specific provider secret; required by the current text provider |
| Providers | `OPENROUTER_API_KEY` | Environment-specific server-only credential for the `/chat` OpenRouter adapter; the `/chat` console requests `stealth/ox-alpha` only, so a turn fails rather than answering as another model; empty disables the adapter |
| Providers | `OPENAGENTS_INFERENCE_PROXY_URL` | HTTPS URL without credentials when computers are enabled; empty disables |
| Computers | `OPENAGENTS_MACHINE_TOKEN_TTL_SECONDS` | `300` through `2592000`; Gate 5 uses the 30-day maximum |
| Recording | `VOICE_RECORDING_ENCRYPTION_KEY` | Base64-encoded 32-byte key when recording is enabled; empty disables recording storage |
| Content | `CONTENT_ENCRYPTION_KEY` | Base64-encoded 32-byte key, required in staging and production. The content vault seals voice transcripts, in-call compaction summaries, preference observations, and project notes. It is the vault's own key: nothing bridges to it and nothing bridges from it (VAULT-001), so an unset value refuses the boot rather than borrowing another vault's key |

`PHX_SERVER` is optional for evaluation commands. If set, it must be exactly
`true` or `false`.

## Feature profile

Every feature flag is a required literal `true` or `false` in a release. The
compile-time default and the Gate 5 staging override are deliberately the same
safe value unless noted. Advancing `OPENAGENTS_STAGING_GATE` admits a feature;
it does not enable it automatically.

The table records compiled defaults and the Gate 5 staging template. It is not
a live production feature inventory. Run `bin/config-readiness` inside the
target release to inspect its redacted feature booleans.

| Feature | Environment setting | Default | Gate 5 staging | Earliest staging gate |
| --- | --- | --- | --- | --- |
| Tool catalog | `OPENAGENTS_FEATURE_TOOLS` | On | On | 5 |
| Voice | `OPENAGENTS_FEATURE_VOICE` | Off | Off | 14 |
| Voice recording | `OPENAGENTS_FEATURE_VOICE_RECORDING` | Off | Off | 14 |
| Voice retention | `OPENAGENTS_FEATURE_VOICE_RETENTION` | Off | Off | 14 |
| Work | `OPENAGENTS_FEATURE_WORK` | Off | Off | 14 |
| Computers | `OPENAGENTS_FEATURE_COMPUTERS` | Off | Off | 14 |
| Semantic memory | `OPENAGENTS_FEATURE_SEMANTIC_MEMORY` | Off | Off | 14 |
| Experience memory | `OPENAGENTS_FEATURE_EXPERIENCE_MEMORY` | Off | Off | 14 |
| Graph memory | `OPENAGENTS_FEATURE_GRAPH_MEMORY` | Off | Off | 14 |
| Memory portability | `OPENAGENTS_FEATURE_MEMORY_PORTABILITY` | Off | Off | 14 |
| Shadow programs | `OPENAGENTS_FEATURE_SHADOW_PROGRAMS` | Off | Off | 14 |
| Tool embeddings | `OPENAGENTS_FEATURE_TOOL_EMBEDDINGS` | Off | Off | 14 |
| Conversation reset | `OPENAGENTS_FEATURE_CONVERSATION_RESET` | Off | Off | 14 |
| Incident fixer | `OPENAGENTS_FEATURE_INCIDENT_FIXER` | Off | Off | 14 |
| SCV deployment | `OPENAGENTS_FEATURE_SCV_DEPLOY` | Off | Off | 14 |
| Turn recovery | `OPENAGENTS_FEATURE_TURN_RECOVERY` | Off | Off | 8 |
| Forge Git service | `OPENAGENTS_FEATURE_FORGE` | Off | Off | 12 |
| Forge deployment | `OPENAGENTS_FEATURE_FORGE_DEPLOY` | Off | Off | 13 |
| Deployment control plane | `OPENAGENTS_FEATURE_DEPLOYMENT_CONTROL_PLANE` | Off | Off | 13 |
| Boot convergence | `OPENAGENTS_FEATURE_BOOT_CONVERGENCE` | Off | Off | 13 |
| Ra authority | `OPENAGENTS_FEATURE_RA` | Off | Off | 12 |
| Horde runtime | `OPENAGENTS_FEATURE_HORDE` | On | On | 5 |

Invalid combinations fail closed. Recording requires voice and its encryption
key; retention requires recording; work and its recovery worker move together;
the incident fixer requires computers; SCV deployment requires the work lane,
the tool catalog, and admitted bounds; deployment requires the forge; boot
convergence requires deployment; and distributed features require Horde,
discovery, node identity, cookie, and bounded distribution ports.

## Forge, storage, and cluster settings

| Environment setting | Gate 5 staging value or rule |
| --- | --- |
| `OPENAGENTS_FORGE_REPOSITORIES` | Exactly `openagents.com` |
| `OPENAGENTS_FORGE_OWNER` | Exactly `OpenAgentsInc` |
| `OPENAGENTS_FORGE_INTERNAL_GIT_URL` | Credential-free HTTP(S) owner root, such as `http://127.0.0.1:8080/OpenAgentsInc`; do not include the retired `/git` prefix |
| `OPENAGENTS_FORGE_OPERATOR_TOKEN` | Secret required when the forge is enabled; empty while disabled |
| `OPENAGENTS_FORGE_MIRROR_URLS_JSON` | Optional JSON object from repository name to credential-free git mirror URL; empty disables one-way GitHub mirroring |
| `OPENAGENTS_FORGE_BUILD_EXECUTOR` | `sidecar` |
| `OPENAGENTS_FORGE_ARTIFACT_STORE` | `local` until the durable store gate replaces it |
| `OPENAGENTS_FORGE_WAL_ADAPTER` | `local` or `gcs` |
| `OPENAGENTS_FORGE_WAL_BUCKET` | Required by the GCS WAL; empty for local |
| `OPENAGENTS_FORGE_EXPECTED_FLEET_SIZE` | `1` while deployment is disabled; at least `2` for deployment |
| `OPENAGENTS_FORGE_DATA_DIR` | Absolute durable path outside `/tmp` |
| `OPENAGENTS_FORGE_WAL_DIR` | Absolute durable path outside `/tmp` for the local WAL |
| `OPENAGENTS_FORGE_BUILD_DIR` | Absolute durable path outside `/tmp` |
| `OPENAGENTS_FORGE_BUILD_QUEUE_DIR` | Absolute durable path outside `/tmp` |
| `OPENAGENTS_FORGE_ARTIFACT_DIR` | Absolute durable path outside `/tmp` |
| `OPENAGENTS_FORGE_BUILD_TIMEOUT_MS` | `300000`; admitted range 30 seconds to 30 minutes |
| `OPENAGENTS_FORGE_BUILD_OUTPUT_RETENTION_MS` | `604800000` (seven days); admitted range one to 30 days |
| `OPENAGENTS_FORGE_DEPLOY_TIMEOUT_MS` | `15000`; admitted range one to 120 seconds |
| `OPENAGENTS_FORGE_DEPLOY_TOKEN_TTL_MS` | `120000`; admitted range 30 seconds to 30 minutes and at least eight deployment timeouts |
| `OPENAGENTS_FORGE_BOOT_RETRY_MIN_MS` | `1000`; admitted range 100 milliseconds to one minute |
| `OPENAGENTS_FORGE_BOOT_RETRY_MAX_MS` | `30000`; admitted range one to 300 seconds and not less than the minimum |
| `OPENAGENTS_FORGE_ROLLING_PROVIDER` | `gcp` for the automated staging fallback; production leaves it empty and uses an explicit operator-directed rollout when direct loading and relup cannot apply the candidate |
| `OPENAGENTS_GCP_ROLLING_PROJECT_ID` | Isolated staging project; must differ from `OPENAGENTS_PRODUCTION_PROJECT_ID` |
| `OPENAGENTS_PRODUCTION_PROJECT_ID` | Production project used only as a fail-closed comparison value |
| `OPENAGENTS_GCP_ROLLING_ZONE` | Zone that contains the three stable staging instances |
| `OPENAGENTS_GCP_ROLLING_INSTANCES_JSON` | Exact JSON map from three BEAM node names to three staging instance names |
| `OPENAGENTS_GCP_IMAGE_REPOSITORY` | Staging Artifact Registry repository and image path without a tag or digest |
| `OPENAGENTS_GCP_ROLLING_RPC_TIMEOUT_MS` | Bounded private node-probe timeout from one to 120 seconds |
| `OPENAGENTS_GCP_COMPUTE_TIMEOUT_MS` | Bounded private deployer call timeout from 30 seconds to 10 minutes |
| `OPENAGENTS_CODING_JOBS_DIR` | Absolute durable path outside `/tmp` when work or computers are enabled |
| `OPENAGENTS_RA_DATA_DIR` | Absolute durable path outside `/tmp` when Ra is enabled |
| `OPENAGENTS_RA_EXPECTED_SIZE` | At least `3` when Ra is enabled |
| `DNS_CLUSTER_QUERY` | Required when Ra or fleet deployment is enabled; empty otherwise |
| `OPENAGENTS_DIST_PORT_MIN`, `OPENAGENTS_DIST_PORT_MAX` | Bounded range; the release wrapper applies the same values |

Ra and fleet deployment additionally require a stable `RELEASE_NODE`, a
`RELEASE_COOKIE` of at least 32 bytes, and `RELEASE_DISTRIBUTION=name` or
`longnames`. In staging, each fleet node uses its reserved private IP in
`RELEASE_NODE` because `DNSCluster` constructs peer identities from the A
records returned by `DNS_CLUSTER_QUERY`. The readiness report records only
whether those settings passed; it never prints their values.

### Forge GitHub mirroring

Setting `OPENAGENTS_FORGE_MIRROR_URLS_JSON` turns on one-way mirroring: every
accepted forge push is followed by a best-effort `git push --mirror` to the
configured URL. `OpenAgents.Forge.MirrorWatch` compares refs immediately after
process startup and every five minutes afterward, retries drift, and raises
one `forge_mirror_lagging` incident per lag episode past fifteen minutes.
Mirror freshness appears on the public status page as `current` or `lagging`;
with no URLs configured it reads `off`.

Two rules are load-bearing:

1. **The URL carries no credential.** RuntimeConfig refuses mirror URLs that
   embed userinfo. Authentication belongs to the nodes: give each fleet node
   a read-write GitHub credential through a git credential helper or an SSH
   deploy key for the target repository. The mirror push runs as the same
   user as the release.
2. **The mirror is force-pushed.** `--mirror` makes the configured remote
   exactly match the forge. Configure it only on a repository you accept
   being overwritten by forge state — for this project, GitHub's
   `OpenAgentsInc/openagents.com`.

Staging receives the value through the optional
`forge_mirror_urls_json` Terraform variable; production sets the environment
variable directly in its fleet configuration.

## Local defaults

Development and test remain sanctioned degraded modes: the database may use a
loopback Unix socket, the endpoint may use loopback HTTP, external features are
off, and test fakes may replace provider modules. Runtime service fallbacks no
longer use inherited `/tmp/openagents_*` locations. Ra, forge data, forge WAL,
build queues, artifacts, and coding jobs default beneath `/var/lib/openagents`;
tests that exercise filesystem behavior provide their own disposable paths.
