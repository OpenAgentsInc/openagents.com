# Runtime configuration

Date: 2026-08-20

Status: Current

`OpenAgents.RuntimeConfig` is the single typed boundary for behavior-changing
runtime settings. It runs before migrations, workers, or the endpoint. Invalid
configuration raises a diagnostic containing only the setting name and its
requirement; it never echoes a value.

Production releases require `OPENAGENTS_ENVIRONMENT=staging` or `production`.
Production remains locked: `OPENAGENTS_ENVIRONMENT=production` is refused while
`OPENAGENTS_PRODUCTION_DEPLOY_ENABLED=false`. Do not change that setting until
the staging matrix and soak in the hardening plan are complete and an operator
records a separate production decision.

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

## Required release settings

All settings in this section are mandatory in a production release unless
marked conditional. An empty value is accepted only where the table explicitly
says "empty disables." Secrets come from the staging secret manager through
the runtime identity; never put them in images, build arguments, repository
URLs, receipts, or checked-in environment files.

| Group | Environment setting | Requirement |
| --- | --- | --- |
| Release | `OPENAGENTS_ENVIRONMENT` | `staging`; `production` remains separately locked |
| Release | `OPENAGENTS_STAGING_GATE` | Integer `0` through `16`; feature admission is tied to it |
| Release | `OPENAGENTS_PRODUCTION_DEPLOY_ENABLED` | `false` until a later production decision |
| Endpoint | `PHX_HOST` | Exactly `stage.openagents.com` in staging |
| Endpoint | `OPENAGENTS_ALLOWED_ORIGINS` | Comma-separated exact HTTPS origins including `https://stage.openagents.com` |
| Endpoint | `OPENAGENTS_HTTPS_ALIASES` | Comma-separated hostnames; empty means no aliases |
| Endpoint | `OPENAGENTS_SECURE_COOKIES` | `true` in staging and production |
| Endpoint | `SECRET_KEY_BASE` | Staging-only secret |
| Endpoint | `PORT` | Port `1` through `65535` |
| Database | `OPENAGENTS_DATABASE_MODE` | `url` or `socket` |
| Database | `DATABASE_URL` | Required only in `url` mode |
| Database | `DB_USER`, `DB_PASSWORD`, `DB_NAME`, `INSTANCE_UNIX_SOCKET` | Required only in `socket` mode |
| Database | `OPENAGENTS_DATABASE_IPV6` | Explicit `true` or `false` |
| Database | `POOL_SIZE` | Integer `1` through `200` |
| Database | `OPENAGENTS_MIGRATE_ON_BOOT` | `true` in staging and production |
| GitHub | `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` | Staging OAuth application credentials |
| GitHub | `GITHUB_REDIRECT_URI` | Exact HTTPS callback on `PHX_HOST` |
| GitHub | `GITHUB_OAUTH_SCOPES` | Exactly `repo`; profile identity needs no additional scope |
| GitHub | `GITHUB_TOKEN_ENCRYPTION_KEY` | Base64-encoded 32-byte staging key |
| GitHub | `GITHUB_TOKEN_ENCRYPTION_KEY_ID` | Bounded active-key identifier prefixed with `development-`, `test-`, `staging-`, or `production-` to match the runtime |
| GitHub | `GITHUB_TOKEN_DECRYPTION_KEYS_JSON` | Optional map of at most 16 same-environment prior keys used only during rewrap; omit the active ID |
| Providers | `OPENAI_API_KEY` | Staging-only provider secret; required by the current text provider |
| Providers | `OPENAGENTS_INFERENCE_PROXY_URL` | HTTPS URL without credentials when computers are enabled; empty disables |
| Computers | `OPENAGENTS_MACHINE_TOKEN_TTL_SECONDS` | `300` through `2592000`; Gate 5 uses the 30-day maximum |
| Recording | `VOICE_RECORDING_ENCRYPTION_KEY` | Base64-encoded 32-byte key when recording is enabled; empty disables recording storage |

`PHX_SERVER` is optional for evaluation commands. If set, it must be exactly
`true` or `false`.

## Feature profile

Every feature flag is a required literal `true` or `false` in a release. The
compile-time default and the Gate 5 staging override are deliberately the same
safe value unless noted. Advancing `OPENAGENTS_STAGING_GATE` admits a feature;
it does not enable it automatically.

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
| Turn recovery | `OPENAGENTS_FEATURE_TURN_RECOVERY` | Off | Off | 8 |
| Forge Git service | `OPENAGENTS_FEATURE_FORGE` | Off | Off | 12 |
| Forge deployment | `OPENAGENTS_FEATURE_FORGE_DEPLOY` | Off | Off | 13 |
| Boot convergence | `OPENAGENTS_FEATURE_BOOT_CONVERGENCE` | Off | Off | 13 |
| Ra authority | `OPENAGENTS_FEATURE_RA` | Off | Off | 12 |
| Horde runtime | `OPENAGENTS_FEATURE_HORDE` | On | On | 5 |

Invalid combinations fail closed. Recording requires voice and its encryption
key; retention requires recording; work and its recovery worker move together;
the incident fixer requires computers; deployment requires the forge; boot
convergence requires deployment; and distributed features require Horde,
discovery, node identity, cookie, and bounded distribution ports.

## Forge, storage, and cluster settings

| Environment setting | Gate 5 staging value or rule |
| --- | --- |
| `OPENAGENTS_FORGE_REPOSITORIES` | Exactly `openagents.com` |
| `OPENAGENTS_FORGE_OWNER` | Exactly `OpenAgentsInc` |
| `OPENAGENTS_FORGE_INTERNAL_GIT_URL` | HTTP(S) service URL with no embedded credentials |
| `OPENAGENTS_FORGE_OPERATOR_TOKEN` | Secret required when the forge is enabled; empty while disabled |
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
| `OPENAGENTS_CODING_JOBS_DIR` | Absolute durable path outside `/tmp` when work or computers are enabled |
| `OPENAGENTS_RA_DATA_DIR` | Absolute durable path outside `/tmp` when Ra is enabled |
| `OPENAGENTS_RA_EXPECTED_SIZE` | At least `3` when Ra is enabled |
| `DNS_CLUSTER_QUERY` | Required when Ra or fleet deployment is enabled; empty otherwise |
| `OPENAGENTS_DIST_PORT_MIN`, `OPENAGENTS_DIST_PORT_MAX` | Bounded range; the release wrapper applies the same values |

Ra and fleet deployment additionally require a stable `RELEASE_NODE`, a
`RELEASE_COOKIE` of at least 32 bytes, and `RELEASE_DISTRIBUTION=name` or
`longnames`. The readiness report records only whether those settings passed;
it never prints their values.

## Local defaults

Development and test remain sanctioned degraded modes: the database may use a
loopback Unix socket, the endpoint may use loopback HTTP, external features are
off, and test fakes may replace provider modules. Runtime service fallbacks no
longer use inherited `/tmp/openagents_*` locations. Ra, forge data, forge WAL,
build queues, artifacts, and coding jobs default beneath `/var/lib/openagents`;
tests that exercise filesystem behavior provide their own disposable paths.
