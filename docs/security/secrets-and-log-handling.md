# Staging secrets and log handling

Date: 2026-08-20

Status: Gate 6 application controls implemented; staging rotation and exported-log proof required before admission

## Runtime identities

Use separate workload identities even when the first staging topology places
more than one role on a node:

| Runtime identity | Purpose | May read |
| --- | --- | --- |
| `openagents-staging-web` | Phoenix release and forge Git endpoint | Web, provider, OAuth, vault, recording, forge verification, database, and cluster secrets listed below |
| `openagents-staging-fleet` | Three-node distributed application lane | The application secrets required by the same candidate plus the cluster cookie; no Compute mutation permission |
| `openagents-staging-deployer` | Minimal private rolling-replacement controller | Cluster cookie only; Compute mutation comes from its bounded workload identity |
| `openagents-staging-migrator` | Release migration and token rewrap job | Database URL, active GitHub vault key, prior GitHub vault keyring |
| `openagents-staging-builder` | Isolated BEAM build sidecar | Forge operator token only; use an askpass helper, never a URL or argv value |
| `openagents-staging-operator` | Human-triggered staging operations | No application secrets by default; short-lived platform access to invoke jobs and read redacted logs |

Google Cloud workloads must use workload identity for Secret Manager, Cloud
SQL, object storage, and log access. Do not create or mount a service-account
JSON key. Grant each identity access to named secrets, not project-wide secret
access.

## Secret inventory

The names below are the required staging Secret Manager names. Production must
use distinct names and values and remains locked.

| Environment input | Staging secret name | Readers | Rotation trigger |
| --- | --- | --- | --- |
| `DATABASE_URL` | `openagents-staging-database-url` | web, fleet, migrator | Database credential rotation or suspected log/process exposure |
| `SECRET_KEY_BASE` | `openagents-staging-secret-key-base` | web, fleet | Suspected exposure; rotation invalidates browser sessions |
| `GITHUB_CLIENT_SECRET` | `openagents-staging-github-client-secret` | web, fleet | OAuth app rotation |
| `GITHUB_TOKEN_ENCRYPTION_KEY` | `openagents-staging-github-vault-active` | web, fleet, migrator | Scheduled vault rotation or suspected exposure |
| `GITHUB_TOKEN_DECRYPTION_KEYS_JSON` | `openagents-staging-github-vault-previous` | web, fleet, migrator, only during rewrap | Delete after every row uses the active key ID |
| `OPENAI_API_KEY` | `openagents-staging-openai-api-key` | web, fleet | Provider rotation or suspected prompt/log exposure |
| `VOICE_RECORDING_ENCRYPTION_KEY` | `openagents-staging-voice-recording-key` | web and fleet when recording is admitted | Scheduled recording-key procedure or suspected exposure |
| `OPENAGENTS_FORGE_OPERATOR_TOKEN` | `openagents-staging-forge-operator-token` | web, fleet, builder | Scheduled rotation, builder replacement, or suspected URL/argv/log exposure |
| `RELEASE_COOKIE` | `openagents-staging-release-cookie` | web, fleet, deployer | Fleet-wide coordinated rotation or suspected exposure |

`GITHUB_CLIENT_ID` and `GITHUB_TOKEN_ENCRYPTION_KEY_ID` are identifiers, not
secrets. `DB_PASSWORD` is not used by the admitted staging profile because it
uses `DATABASE_URL`; if socket mode is admitted later, give it its own named
secret and update this table first. First-party API tokens, machine tokens,
pairing secrets, inference grants, browser cookies, and OAuth codes are minted
credentials, never deployment configuration and never Secret Manager values.

## Handling rules

- Inject secrets at runtime. Never use Docker build arguments, image layers,
  repository files, release receipts, command arguments, or repository URLs.
- The build queue contains an uncredentialed internal repository URL. The
  builder reads its forge secret through its workload identity and supplies it
  through the absolute helper path in `OPENAGENTS_FORGE_GIT_ASKPASS`, with
  terminal prompting disabled. That environment value is a path, never the
  secret itself.
- Keep the OAuth callback route's Phoenix dispatch logging disabled. Configure
  the external HTTPS load balancer to omit query strings for
  `/auth/github/callback`; a path and status are sufficient.
- Keep the global Phoenix parameter filter. Do not add ad hoc logging of
  connection params, request bodies, LiveView event params, provider payloads,
  exception structs, or tool results.
- Operational events may contain bounded IDs, status codes, counts, timings,
  model IDs, and digests. They may not contain messages, prompts, transcripts,
  memory claims, raw tool arguments/results, SDP, headers, cookies, or tokens.
- Public status responses follow their documented bounded projections. They do
  not expose node names, hosts, paths, environment values, queue contents, or
  internal exception text.

## Rotation procedures

For the GitHub vault, put the old ID/key into
`GITHUB_TOKEN_DECRYPTION_KEYS_JSON`, activate a new key and ID, prove readiness,
then run:

```sh
bin/rotate-github-tokens
```

The command is transactional and prints only `github_tokens_rotated=N`. Verify
that no user row carries the old key ID before removing the prior-key secret.

Before the first Gate 15 deployment, treat every pre-gate staging credential as
potentially logged. Rotate the database credential, endpoint secret, OAuth
client secret, provider key, forge token, release cookie, and any enabled
recording/vault key. Record only secret resource version IDs and timestamps in
the evidence receipt—never values. A credential is not considered rotated
until every old version is disabled and the exact candidate has restarted
successfully.

## Staging log acceptance

Export application, load-balancer, release-job, builder, and database proxy
logs for the complete test window into one access-controlled local file. Scan
that file without printing matching lines:

```sh
MIX_ENV=test mix run --no-start ops/ci/private-log-scan.exs /path/to/staging.log
```

The command reports only finding type and line number. It fails on credential
prefixes or bearer values, OAuth callback query parameters, credential-bearing
URLs, and unfiltered private-content fields. Manually inspect a representative
sample for plain-language message or transcript content that has no field key.
Delete the local export after recording its SHA-256 digest, bounded time range,
source set, scan result, reviewer, and candidate Git SHA.

Any finding blocks the gate. Rotate the affected credential, remove or bound
the log source, redeploy the same corrected candidate, and scan a new clean
window. Never copy a leaked value into an issue or evidence receipt.
