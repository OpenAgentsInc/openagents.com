# SCV Codex app-server planning

Date: 2026-08-20

Status: individual operator connection and propose-only execution implemented;
staging qualification pending; service accounts remain second

## Outcome

Add a Codex-backed driver to the SCV runtime without making Codex the durable
SCV authority. The OpenAgents coordinator should continue to own the SCV
identity, work-item lease, policy, budget, event history, artifacts, candidate,
and Forge handoff. A local Codex app-server process should own one bounded Codex
execution session behind that contract.

Use the Codex app-server v2 protocol, not ACP, for the first integration. Start
the app-server as a supervised local child process and communicate over
standard input and output. This surface provides the account login, thread,
turn, approval, rate-limit, and live event operations that an SCV needs.

Support these credential paths:

- Implement ChatGPT device-code login first so an authenticated OpenAgents
  operator can connect an individual Codex account.
- Add ChatGPT service-account access tokens second, and only for a workspace
  on a pay-as-you-go plan. OpenAI does not make service accounts available on
  other plans.
- Support a personal Codex access token when an operator needs ChatGPT
  workspace attribution and device login is unavailable.
- Keep API-key authentication available for usage-based automation that does
  not need ChatGPT workspace entitlements.
- Do not use experimental `chatgptAuthTokens` in the first version.

Run one isolated Codex account runtime per connected credential. Start with one
active SCV run per account runtime. Never switch the account of a process that
has a loaded or running thread. A later measured release may allow several
threads for the same account in one process, but it must not combine different
accounts in that process.

The first Codex-backed SCV must remain propose-only. Native app-server events
observe command and file effects after Codex admits them, but they do not create
the durable effect barrier required for autonomous repository writes. Before a
Codex-backed SCV receives write or deployment authority, separate the
credential-bearing app-server from candidate command execution and prove that
candidate code cannot read its credential.

## Implementation checkpoint

The first individual-operator path now implements the following boundaries:

- `OpenAgents.SCV.CodexAppServer` owns one isolated app-server process and
  rejects every server-initiated request that the host does not implement.
- `OpenAgents.SCV.Driver.CodexAppServer` exposes Codex as the
  `codex_app_server` driver behind the common SCV contract.
- `OpenAgents.SCV.CodexRuns` claims one ready account for one active run and
  starts it under a local dynamic supervisor.
- `OpenAgents.SCV.Execution` stores the SCV principal, exact repository SHA,
  account generation, node owner, lease deadline, Codex thread and turn IDs,
  usage, resources, terminal report, and report digest.
- `OpenAgents.SCV.ExecutionEvent` stores only bounded, normalized,
  credential-free events. It excludes objectives, repository paths, commands,
  output, raw protocol payloads, and credentials.
- `OpenAgents.SCV.Workspace` clones the node-local Forge cache into a
  disposable workspace, checks out the admitted SHA, verifies a clean index
  and worktree, and deletes the workspace after the run.
- The driver fixes the model to `gpt-5.6-luna`, admits only `none` or `low`
  reasoning, sets `approvalPolicy` to `never`, and requires the
  repository-scoped `scv-read-only` permission profile.
- The driver streams normalized lifecycle, tool, usage, heartbeat, and
  terminal events through the common SCV telemetry event. `/status` projects
  those events without exposing protocol content.
- `/status` merges node-local live events with the durable active-run
  projection. You can observe an SCV from a different serving node without
  exposing its objective, repository path, output, account, or protocol IDs.
- A run cannot report success until PostgreSQL retains its terminal report and
  SHA-256 digest. An expired account lease becomes `uncertain` before another
  run can claim the account.
- A periodic reaper marks abandoned leases `uncertain` and releases their
  account capacity without waiting for a new claim.

The implementation does not yet admit repository writes, pushes, Forge
promotion, deployment, automatic issue closure, process recovery, or a
service-account credential. A node loss can leave a run active until its lease
expires; the reaper then fences the stale generation as `uncertain`. Complete
the staging procedure in
[Qualify an SCV in staging](operations/scv-staging-qualification.md) before you
call the driver qualified.

## Research basis

This plan uses two current sources:

- The official [Codex app-server documentation](https://learn.chatgpt.com/docs/app-server),
  [Codex SDK documentation](https://learn.chatgpt.com/docs/codex-sdk),
  [authentication guide](https://learn.chatgpt.com/docs/auth),
  [access-token guide](https://learn.chatgpt.com/docs/enterprise/access-tokens),
  [service-account guide](https://learn.chatgpt.com/docs/enterprise/service-accounts),
  and [configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)
  as retrieved on 2026-08-20.
- The local `openai/codex` checkout at commit
  `bf2aee99c58362d3f588d98432dcbc7adc371c73`, committed on 2026-08-20.

The local checkout is a moving development baseline. Its Python SDK manifest
pins `openai-codex-cli-bin` `0.147.0`, while the source checkout contains newer
protocol work. Do not build a production contract from the development checkout
alone. Pin a released Codex runtime, generate its schema, and retain the
checkout only as explanatory source.

The most relevant inspected paths are:

| Area | Local Codex path | Finding |
| --- | --- | --- |
| Protocol overview | `codex-rs/app-server/README.md` | App-server v2 provides JSON-RPC lifecycle, events, approvals, and account methods. |
| Account protocol | `codex-rs/app-server-protocol/src/protocol/v2/account.rs` | Managed browser login, device-code login, API-key login, and experimental external-token login are separate modes. |
| Account processor | `codex-rs/app-server/src/request_processors/account_processor.rs` | One processor has one active login slot and replaces an earlier pending login when a new login starts. |
| Device flow | `codex-rs/login/src/device_code_auth.rs` | Codex requests a one-time code, polls for completion, warns about login phishing, and expires the code after 15 minutes. |
| Authentication state | `codex-rs/login/src/auth/manager.rs` | One process shares one `AuthManager` and one current authentication snapshot across its thread manager. |
| Credential storage | `codex-rs/login/src/auth/storage.rs` | File storage writes `auth.json` with mode `0600`; managed tokens, refresh state, and other authentication material live in that record. |
| Process-wide thread state | `codex-rs/app-server/src/message_processor.rs` and `codex-rs/core/src/thread_manager.rs` | Threads in one process share the same authentication manager and process-scoped state stores. |
| Environment inheritance | `codex-rs/protocol/src/config_types.rs` and `codex-rs/protocol/src/shell_environment.rs` | The default shell policy inherits all variables and keeps names containing `KEY`, `SECRET`, or `TOKEN` unless the host changes the policy. |
| Python SDK | `sdk/python/src/openai_codex/client.py` and `sdk/python/src/openai_codex/_login.py` | The stable SDK starts app-server over standard input and output and exposes device-login handles, typed requests, notifications, and approvals. Its default approval callback accepts command and file requests, so an SCV must replace it if the SDK is used. |

The protocol source contains account-session data structures, but this checkout
does not register corresponding account-session requests or implement their
processor methods. Do not infer supported multi-account switching from unused
types.

## Decision

Treat Codex app-server as another SCV driver implementation:

```text
OpenAgents SCV coordinator
          |
          | durable run request, lease, policy, and budget
          v
SCV worker and Codex driver
          |
          | local JSONL JSON-RPC over an Erlang Port
          v
codex app-server --listen stdio://
          |
          | one credential and one isolated CODEX_HOME
          v
Codex thread and turns for one SCV run
```

Name the driver `codex_app_server` in durable SCV records. The name identifies
the implementation boundary; it does not create a second kind of SCV. Keep
OpenCode as a separate driver behind the same SCV run and event contracts.

Implement the first protocol client in Elixir as a supervised port adapter.
This preserves the Elixir-native coordinator, avoids placing Node.js or Python
in the control plane, and exposes the complete event and approval stream. Use
the official Python SDK as a conformance oracle and fallback packaging option,
not as the initial authority. If OpenAI requires the stable SDK for production
support, replace the port adapter with a narrow Python SDK bridge without
changing the outer SCV contract.

This decision carries a support gate. OpenAI describes app-server as the rich
product-integration surface, but its documentation also labels the app-server
command and WebSocket transport experimental and recommends the Codex SDK for
automated jobs. Do not call the driver production-ready until one of these is
true:

- OpenAI confirms that the pinned app-server use is supported for this
  integration.
- The driver uses a stable Codex SDK release that pins its Codex runtime.
- We explicitly accept the version-support risk and maintain the required
  compatibility matrix and rollback path.

## Why app-server is the appropriate surface

| Option | Useful capabilities | Decision |
| --- | --- | --- |
| Codex app-server v2 | Device login, account inspection, rate limits, threads, turns, approvals, live item events, cancellation, history, and output schemas | Use as the SCV driver protocol. |
| Codex Python SDK | Stable typed wrapper around a pinned local app-server runtime, including device login and streaming | Use for conformance and as the production fallback if direct protocol support is unacceptable. Always replace its permissive default approval handler. |
| Codex TypeScript SDK and `codex exec` | Strong batch automation, JSONL progress, resumable threads, and structured final output | Keep as a possible batch driver, but it does not provide the full operator account-connection and approval surface needed here. |
| Codex MCP server | Exposes `codex` and `codex-reply` tools to another MCP client | Do not use for the primary driver. It intentionally compresses Codex into tool calls and omits the account, rate-limit, approval, and detailed lifecycle control that the SCV coordinator needs. |
| ACP | No first-party ACP implementation or supported ACP surface appeared in the inspected checkout or official Codex app-server documentation | Do not design against ACP. Re-evaluate only if OpenAI publishes a supported surface. |
| Experimental `chatgptAuthTokens` | Lets a host that already owns the ChatGPT authentication lifecycle inject access tokens and answer refresh requests | Do not use. OpenAgents does not own a supported ChatGPT OAuth client lifecycle, the mode is experimental, and refresh responses have a short deadline. |

MCP remains useful when another general-purpose model uses Codex as one tool.
That is not the SCV topology. OpenAgents already owns durable orchestration and
needs Codex's lower-level run events.

## SCV authority boundary

The Codex thread is not the durable SCV. The Codex app-server process may exit,
its connection may close, or a thread may become unloadable without changing
the SCV's identity. The outer SCV record must remain authoritative for:

- the admitted work item and exact repository base SHA;
- the SCV ID, run ID, execution ID, lease generation, and driver revision;
- the account runtime selected for the run;
- the allowed repository, branch, paths, commands, network, and risk class;
- wall, token, cost, process, and storage budgets;
- cancellation and operator pause state;
- durable events, reports, artifacts, candidate commits, and Forge receipts;
- terminal status and recovery decisions.

Store the Codex thread ID and turn IDs as nested driver identifiers. Never use a
Codex thread ID as an SCV lease, authority token, or idempotency key.

The coordinator must still make every work-admission and Forge decision. Codex
may propose edits and produce evidence, but it must not receive promotion,
deployment, SCV-policy, account-management, or credential-management tools.

## Authentication strategy

### Credential choices

| Credential | Appropriate use | Persistence | Initial status |
| --- | --- | --- | --- |
| Managed ChatGPT device login | An authenticated operator connects an individual ChatGPT account and lets Codex own refresh and persistence | Preserve the account's updated `auth.json` across restarts under a single-writer lease. | Implement first. |
| ChatGPT service-account access token | Headless workspace automation that needs a non-human ChatGPT identity, governance, and attribution | Store the token in the platform secret manager and rotate it. Do not persist a login in the worker. | Implement second. Available only on pay-as-you-go plans. |
| Personal Codex access token | Trusted automation attributed to one workspace member | Store and rotate it like any other automation secret. | Allowed for a bounded pilot; prefer a service account for shared production work. |
| Platform API key | Usage-based Codex work that does not need ChatGPT plan limits or workspace identity | Use a scoped secret or existing inference grant. | Supported fallback. |
| Browser callback login | Interactive local clients where the browser can return to a localhost callback | Requires the app-server callback listener. | Do not use for the hosted admin interface; the device flow is less brittle. |
| Experimental external ChatGPT tokens | A host that already owns the complete ChatGPT token lifecycle | Host-managed access-token refresh. | Refused for the first implementation. |

[Codex access tokens](https://learn.chatgpt.com/docs/enterprise/access-tokens)
are available for ChatGPT Business and Enterprise workspaces. OpenAI documents
them for trusted non-interactive local workflows, including app-server-based
automation. [Service accounts](https://learn.chatgpt.com/docs/enterprise/service-accounts)
provide non-human workspace identities on eligible pay-as-you-go plans and
require Codex CLI `0.142.0` or later.

The first product path deliberately connects an individual operator account.
This order proves the account ceremony, app-server lifecycle, credential-home
persistence, rate-limit visibility, and account isolation before OpenAgents
adds non-human credentials. A Platform API key remains the right path for
usage-based work that does not need ChatGPT workspace attribution,
entitlements, limits, or governance.

### Second implementation: pay-as-you-go service accounts

Do not implement service accounts as an alternative first-login button. Add
them only after the individual operator flow passes staging qualification.
OpenAI states that service accounts are available only on pay-as-you-go plans.
OpenAgents must fail closed when the selected workspace does not meet that
requirement.

Use one ChatGPT service account per distinct SCV authority domain, not one
service account per short run and not one employee credential for the entire
company. Examples of distinct domains include staging source maintenance and
production source maintenance. Give each service account only the workspace
roles, groups, plugins, and connections required for that domain.

Create a finite-lived Codex-scoped access token and inject it as
`CODEX_ACCESS_TOKEN` only into the credential-bearing Codex runtime. OpenAI
documents that the same variable works for app-server. Do not persist the token
with `codex login --with-access-token` on an ephemeral worker, and do not reuse
it as a client-to-app-server transport token.

Use this rotation sequence:

1. Mark the account runtime as draining so it receives no new SCV runs.
2. Create a replacement token and store it as a new secret revision.
3. Start a fresh account runtime with the new revision.
4. Run an account-read and bounded read-only SCV smoke test.
5. Route new work to the fresh runtime.
6. Let old work finish or cancel it according to policy.
7. Revoke the old token and destroy the old runtime.

### Device-code connection flow

Use device code when a site administrator or operator explicitly connects a
ChatGPT account through OpenAgents. Device login must be enabled in the user's
ChatGPT security settings or by the ChatGPT workspace administrator.

1. Require an authenticated OpenAgents operator session with account-management
   authority and recent reauthentication.
2. Create a pending Codex account slot and a temporary, isolated account runtime
   with an empty `CODEX_HOME`.
3. Initialize app-server, then send `account/login/start` with
   `{ "type": "chatgptDeviceCode" }`.
4. Bind the returned `loginId`, `verificationUrl`, and `userCode` to the
   requesting operator session. Accept only the expected OpenAI verification
   origin.
5. Display the verification URL, one-time code, expiration, account slot, and
   this warning: Continue only if you started this Codex connection from this
   OpenAgents screen. Cancel if another site or person supplied the code.
6. Wait for the matching `account/login/completed` notification. Do not ask the
   browser to return an OAuth token to OpenAgents.
7. On success, call `account/read` and `account/rateLimits/read`. Record the
   returned account type, plan, operator-visible email, and initial health
   without copying access tokens into PostgreSQL.
8. Stop the temporary runtime, move the resulting credential home into the
   account's encrypted persistent store under a single-writer generation, then
   start its normal account runtime.
9. Delete the one-time code and temporary login record after success, failure,
   cancellation, or expiration.

The local Codex implementation polls for up to 15 minutes. Treat that value as
version-specific and store the actual UI expiration separately from the durable
account. A new login in the same app-server process cancels the prior active
login, so use one temporary process per pending connection attempt.

Do not expose device connection on a public or visitor route. Apply CSRF
protection, rate limits, audit logging, and an allowlist of operators. Never log
the user code, authentication notifications, access token, refresh token, or
raw `auth.json`.

### Managed credential persistence

Codex-managed ChatGPT login refreshes its tokens and writes updated state to
`auth.json`. The official [advanced CI/CD auth guide](https://learn.chatgpt.com/docs/auth/ci-cd-auth)
requires one serialized user of an auth file and preservation of the refreshed
file. An old bootstrap copy cannot safely overwrite the refreshed copy.

Use one of these storage patterns:

- Prefer a long-lived encrypted account volume with one account runtime as its
  only writer.
- If workers are ephemeral, restore one encrypted account blob under a database
  lease, run exactly one account runtime, and write the refreshed file back
  with a compare-and-swap generation before releasing the lease.
- If the refreshed file cannot be acknowledged durably, mark the account
  `reauthentication_required` and stop assigning work. Do not continue from a
  potentially stale seed.

Use `cli_auth_credentials_store = "file"` only inside this isolated account
home. Codex documents that `auth.json` contains access tokens and must be
treated like a password. A generic container keyring is not a durable
multi-worker account store.

## Multiple connected accounts

### Isolation rule

Use one account runtime per connected credential because the inspected Codex
process constructs one shared `AuthManager` and gives it to the process-wide
thread manager. `account/login/start`, `account/logout`, external authentication,
and file reloads change that shared snapshot. Switching it while several
threads run can change which identity later requests use.

Each account runtime needs distinct values for:

- `CODEX_HOME` and `CODEX_SQLITE_HOME`;
- authentication storage and secret revisions;
- configuration, logs, sessions, skills, plugin state, and MCP credentials;
- process user, PID namespace, temporary directory, and cache;
- SCV account-runtime ID, generation, health, and capacity;
- rate-limit and usage snapshots.

Never mount one account's Codex home into another account runtime. Never copy a
thread history between account homes. Never log out, log in, or replace the
credential on a runtime with active work.

Start with account capacity `1`. Codex can host several threads in one process,
but serialized capacity makes account pinning, refresh writes, cancellation,
and recovery auditable. Increase capacity only after tests prove that
concurrent threads preserve event routing, resource bounds, approval routing,
and account attribution.

### Account record

Plan for a durable `scv_driver_accounts` record with at least:

- opaque account ID, driver `codex_app_server`, label, and environment;
- credential kind and secret or encrypted-home reference;
- credential revision and storage generation;
- ChatGPT workspace account ID when available;
- operator-visible email and plan, stored as account metadata rather than run
  output;
- allowed repositories, SCV classes, and risk classes;
- capacity, weight, drain state, and disabled state;
- `connected`, `ready`, `degraded`, `rate_limited`, `draining`, `disabled`,
  `reauthentication_required`, and `revoked` lifecycle states;
- last verification, last successful run, last failure, and last rate-limit
  update;
- creating operator, rotating operator, and immutable audit refs.

Store secret references, not secret values, in PostgreSQL. Store only the
opaque account-runtime ID on ordinary SCV events. Keep email and workspace
metadata out of the public SCV stream.

### Account selection

Select an account before an SCV execution claim becomes runnable. The scheduler
should require all of these conditions:

- The account is enabled, ready, and authorized for the repository and SCV
  class.
- Its credential revision is active and its runtime generation is healthy.
- Its capacity has a free lease.
- Its current Codex model catalog contains the admitted model.
- Its rate-limit snapshot leaves the configured reserve.
- Its workspace and data-handling policy match the work item.

Pin the account for the complete SCV run. Do not move a live thread to another
account after a `401`, quota event, or model error. Pause or fail the run,
release its workspace according to policy, and require a new execution
generation if retry is safe.

Do not rotate across accounts to evade rate limits or contractual restrictions.
Multiple-account support exists to separate owners, workspaces, environments,
and capacity. It is not a quota-bypass mechanism.

## Runtime and secret isolation

### Required topology

The target topology separates the SCV control plane, Codex credential runtime,
and candidate execution:

```text
Phoenix and durable SCV coordinator
                |
                | authenticated worker protocol
                v
SCV worker supervisor
       |                          |
       | private JSONL            | typed, policy-checked effects
       v                          v
Codex credential compartment   candidate execution compartment
- codex app-server             - exact Forge checkout
- one account credential       - no CODEX_HOME
- private CODEX_HOME           - no provider credential
- OpenAI egress only           - bounded command and file tools
- no Forge operator token      - restricted network and cgroup
```

Run app-server on the same trusted worker as its Elixir supervisor and use
standard input and output. Do not expose a TCP port. A Unix socket is an
acceptable later local transport when several local clients need one runtime.
Do not use remote WebSocket transport for the first production version; OpenAI
labels it experimental and unsupported. If it is ever admitted, use TLS and a
dedicated capability or signed bearer token that is unrelated to the Codex
account credential.

### Credential exposure blocker

Codex app-server needs its ChatGPT or API credential while model-selected tools
can start child processes. The current Codex default shell environment policy
inherits all variables and, by default, does not remove names containing
`KEY`, `SECRET`, or `TOKEN`. Therefore, setting `CODEX_ACCESS_TOKEN` on an
app-server process without an explicit environment policy can expose it to a
model-reachable command.

For every Codex-backed SCV:

- Set shell environment inheritance to `core` or `none`.
- Set `shell_environment_policy.ignore_default_excludes = false`.
- Add explicit deny patterns for `CODEX_ACCESS_TOKEN`, OpenAI keys, cloud
  credentials, Forge credentials, database URLs, release cookies, and every
  worker control secret.
- Never allow repository configuration to override the host-owned environment
  policy.
- Deny reads of the account `CODEX_HOME`, secret mounts, worker control
  sockets, and host process metadata.
- Put candidate commands in a separate user, mount, PID, and network namespace
  so they cannot read the app-server process environment through `/proc`.
- Give the candidate compartment no OpenAI egress and no route to the account
  credential store.
- Run a canary test that searches environment variables, filesystem paths,
  process metadata, crash reports, and logs for a synthetic credential.

Environment filtering alone is not a security boundary. A same-user child may
read a parent process or a credential file even when the value is absent from
its immediate environment. The production gate requires operating-system or
remote-execution isolation.

Codex currently has evolving remote environment, permission-profile, dynamic
tool, and code-mode host surfaces that may help implement this split. Several
are experimental in the inspected revision. Do not base production authority
on them until their stable contract and failure behavior are proven. The
alternative is an SCV-owned effect sidecar that disables native command and
file effects and exposes only typed, durably persisted tools.

Until that boundary exists, allow only trusted-repository, read-only,
propose-only qualification with a disposable or narrowly scoped credential.
Do not execute candidate build scripts, dependency hooks, tests, or generated
binaries in the credential compartment.

## App-server lifecycle

### Process startup

For one admitted account runtime:

1. Resolve a digest-pinned worker image and complete Codex package. The package
   must include the app-server entry point, `codex-code-mode-host`, and its
   packaged `bwrap`, `rg`, and `zsh` resources. Installing only the `codex`
   binary disables code-mode tools and does not qualify an SCV runtime. Install
   the package under `/usr/local/lib/codex-package` so the `:minimal`
   filesystem policy can read the executable and its packaged resources.
2. Materialize the account secret or credential home into its isolated
   compartment.
3. Generate host-owned Codex configuration. Ignore repository-controlled user
   configuration for authentication, shell environment, sandbox, network,
   telemetry, plugins, and MCP servers.
4. Start `codex app-server --listen stdio://` under the SCV worker supervisor.
5. Send `initialize` once with a stable client name, title, and version, then
   send `initialized`.
6. Call `account/read`, `model/list`, and, for ChatGPT-backed accounts,
   `account/rateLimits/read` before marking the runtime ready.
7. Record the Codex binary digest, CLI version, generated protocol-schema
   digest, configuration digest, credential revision, and account-runtime
   generation.

Use `openagents_scv` as the proposed `clientInfo.name`. OpenAI asks enterprise
integrations to register a known client name for compliance logs. Contact
OpenAI before production enterprise use and record the accepted identifier.

Enable `initialize.capabilities.experimentalApi` for the pinned driver because
the repository-scoped permission-profile selector remains behind that protocol
gate. Admit only the `permissions` field and the returned
`activePermissionProfile` proof. Keep every other experimental request field
disabled unless a later driver revision adds protocol fixtures and downgrade
behavior for it. Refuse the run instead of falling back to the legacy
full-filesystem read-only sandbox when the pinned runtime cannot activate the
profile.

On Container-Optimized OS, Docker's default seccomp and AppArmor profiles block
the nested Bubblewrap user namespace. The staging fleet removes those two
Docker profiles from the application container without using `--privileged` or
adding Linux capabilities. Bubblewrap must still drop every capability, disable
network access, and mount only the minimal runtime paths plus the repository.
Treat these host settings as staging-specific. Do not carry them into a
production SCV runtime without a separate containment review.

### SCV run sequence

1. Claim one account-runtime capacity lease and bind it to the SCV run
   generation.
2. Prepare an exact-SHA disposable workspace outside `CODEX_HOME`.
3. Call `thread/start` with the exact `cwd`, admitted model, explicit sandbox,
   explicit approval policy, and host-owned developer instructions.
4. Store the returned Codex thread ID before starting the first turn.
5. Call `turn/start` with the bounded SCV objective, `low` or `none` reasoning,
   and an `openagents.scv.report.v1` output schema.
6. Persist and project every admitted notification while the turn runs. Handle
   server-initiated approval requests synchronously and fail closed.
7. On `turn/completed`, persist the final report, usage, changed-file evidence,
   event artifact, and terminal turn status before acknowledging the execution
   as successful.
8. Inspect the workspace independently. Codex output is evidence, not proof of
   its filesystem state.
9. Archive or retain the thread according to the SCV retention policy, release
   the account capacity, and destroy the disposable workspace.

Use `gpt-5.6-luna` with `low` reasoning by default. Allow `none` for a measured
latency-sensitive workload. Call `model/list` at runtime and refuse the claim if
the connected account cannot use the admitted model. Do not silently fall back
to GPT-5.4 or another model family.

Never call `thread/shellCommand` from the SCV driver. App-server documents that
this operation runs outside the thread sandbox.

### Recovery

Standard input and output provide one ordered, process-local control channel.
If the channel closes, treat the app-server process as failed. Preserve the SCV
run and account lease long enough to determine the recovery action.

For a durable thread, restart the same pinned runtime with the same account
home, initialize it, call `thread/read`, and use `thread/resume` only when the
persisted history and exact workspace generation still match. Do not resend a
turn merely because its terminal notification was lost.

If a command or file effect may have occurred but the outer SCV step has no
durable effect receipt, mark the step uncertain and discard or quarantine the
workspace. App-server history can help investigation, but it cannot replace a
pre-effect durable SCV record.

Do not share one managed `auth.json` between concurrently recovering processes.
The account-runtime generation fence must ensure that only one process can
refresh and write the credential home.

## Events and the public SCV stream

App-server already provides the live visibility required by an SCV. Normalize
its JSON-RPC notifications into the common `openagents.scv.event.v1` envelope
instead of exposing raw Codex payloads to `/status`.

| Codex signal | SCV event | Public projection |
| --- | --- | --- |
| Process start and `initialize` response | `driver_started` | SCV label, driver, runtime version, and start time |
| `thread/started` | `driver_session_started` | SCV phase and bounded session ID suffix |
| `turn/started` | `run_started` or `turn_started` | Objective summary, admitted model, reasoning effort, and elapsed time |
| `item/started` | `activity_started` | Normalized activity kind such as reading, searching, editing, testing, or reviewing |
| `item/agentMessage/delta` | `message_delta` | Bounded sanitized text suitable for the SCV stream |
| Reasoning deltas and raw model internals | Private diagnostic event | Do not publish raw reasoning. Show a normalized phase or summary only. |
| Command and file-change items | `tool_started`, `tool_progress`, and `tool_completed` | Sanitized command category, relative path, duration, status, and output byte count; omit raw secrets and unbounded output |
| Approval request | `approval_pending` | Reason, bounded action summary, and operator action state |
| `serverRequest/resolved` | `approval_resolved` | Decision, decision source, and resolution time |
| Token-usage updates | `usage_updated` | Input, cached input, output, reasoning, and total tokens when available |
| Rate-limit update | `account_capacity_updated` | Account-runtime health and available-capacity class; do not publish account identity |
| `turn/completed` | `turn_finished` | Terminal status, duration, report availability, changes, tests, and usage |
| Process exit | `driver_finished` | Exit classification, restart count, and terminal receipt status |

Persist a bounded private copy of raw protocol events for debugging and schema
replay. Store large command output, diffs, and traces as digest-addressed
artifacts. The public stream must use a normalized, redacted projection with
rate limits and byte limits.

Preserve unknown notification methods as bounded private events, increment a
schema-mismatch metric, and continue only when the unknown event is
observational. Fail closed on an unknown server-initiated request because it
may require a security decision.

The terminal report must be durable. A run is not successful merely because
Codex exited with `0` or emitted `turn/completed`. Persist and acknowledge the
bounded report, event artifact, workspace inspection, and their digests before
the SCV coordinator advances the work item.

## Approval handling

App-server sends command, file-change, permission, user-input, and MCP
elicitation requests from server to client. The Elixir client must route each
request by JSON-RPC ID and answer within a bounded deadline.

Use these rules:

- Default to decline or cancel for an unknown request, malformed payload,
  expired SCV lease, stale generation, disconnected operator, or policy error.
- Evaluate the SCV authority envelope before presenting or approving an action.
- Allow session-scoped approvals only when the SCV policy explicitly permits
  the exact reusable scope.
- Persist the request and decision before responding when the action can create
  an external effect.
- Pause the SCV and show the request to an operator when policy requires human
  review.
- Record the decision source as host policy, operator, Codex automatic review,
  or refusal.
- Do not let Codex automatic approval review widen the SCV's sandbox,
  repository, network, or Forge authority.

If the Python SDK becomes the implementation layer, always pass a custom
approval handler. Its inspected default handler accepts command and file-change
requests. That behavior is inappropriate for an SCV and must never reach
production configuration.

## Rate limits, usage, and scheduling

Use `account/rateLimits/read` and `account/rateLimits/updated` to maintain a
bounded account-capacity projection. Keep the backward-compatible primary
bucket and any `rateLimitsByLimitId` buckets. Record used percentage, window,
reset time, reached type, and plan without treating an absent field as zero.

Use turn token-usage notifications and `account/usage/read` as complementary
evidence:

- Turn usage binds tokens to one SCV run and remains the primary run ledger.
- Account usage reconciles lifetime and daily activity for ChatGPT-backed
  accounts.
- Host measurements record process CPU, memory, disk, event lag, and wall time.
- Provider or workspace billing remains external authority for charged usage.

The account scheduler should keep a reserve instead of dispatching until a
window reaches 100 percent. On a rate-limit event, stop new claims for that
account, let policy decide whether active work may finish, and wake the account
at the documented reset time plus jitter. Do not select another account merely
to bypass the same limit class.

Record these Codex-specific measurements:

- app-server cold-start and initialization time;
- account verification and model-list time;
- queue time waiting for account capacity;
- time to `thread/started`, `turn/started`, first item, first text delta, and
  terminal report;
- notification count, bytes, ingest lag, dropped projections, and unknown
  methods;
- command, file-change, approval, and tool counts and durations;
- input, cached input, output, and reasoning tokens;
- rate-limit snapshots before and after the run;
- process RSS, peak memory, CPU, disk, child count, restarts, and exit reason;
- recovery attempts, thread resume results, and uncertain effects;
- report, event, transcript, diff, and benchmark artifact digests.

## Version and schema policy

Pin the Codex runtime by image and binary digest. Do not install `latest` at
worker startup. For every admitted version:

1. Run `codex app-server generate-json-schema --out <directory>`.
2. Store the schema bundle and its digest with the SCV driver revision.
3. Generate or validate the Elixir request and response fixtures against that
   bundle.
4. Replay a recorded, redacted event corpus through the normalizer.
5. Run login, read-only turn, approval, cancellation, report, restart, and
   unknown-message tests.
6. Compare the direct Elixir client with the matching stable Python SDK where
   the SDK exposes the same operation.
7. Promote the version only after the worker image and rollback image both
   pass.

Prefer stable protocol fields. The first driver makes one narrow exception for
the released `permissions` and `activePermissionProfile` fields because the
legacy read-only sandbox can read unrelated filesystem paths, including the
credential home. App-server schemas are version-specific. Treat any other
method or field added on the development branch as unavailable until it appears
in the pinned released schema.

## Data retention and privacy

Codex threads may contain source, prompts, tool output, diffs, and account
metadata. Apply the same visibility classification as the SCV work item and
repository.

- Keep account credentials and raw authentication records out of PostgreSQL,
  logs, reports, events, and artifacts.
- Keep account email, workspace identifiers, and plan details on restricted
  account records.
- Redact secrets before event persistence, not only in the `/status`
  projection.
- Bound raw text deltas, command output, and diagnostic logs.
- Store transcripts and large outputs in encrypted, digest-addressed artifact
  storage with an explicit retention period.
- Allow an operator to drain, disconnect, revoke, and delete a connected
  account without deleting immutable run receipts required for audit.
- On disconnect, cancel pending login attempts, stop new claims, terminate the
  account runtime, revoke or delete the credential, and remove its private
  Codex home according to retention policy.

ChatGPT sign-in and API-key sign-in use different OpenAI data-handling and
workspace-control policies. Store the credential kind and workspace policy on
the account record so the scheduler can prevent a work item from using an
incompatible account.

## Implementation phases

### Phase 0: Runtime and policy confirmation

- Confirm device login is enabled for the individual operator account and
  record the admitted Codex runtime and protocol schema.
- Contact OpenAI about the `openagents_scv` client identifier and the supported
  app-server or SDK path.
- Decide which repositories may use ChatGPT credentials instead of Platform
  API keys.
- Admit the first Codex runtime and schema digests.

### Phase 1: Local protocol spike

- Build a supervised Elixir port client for initialization, account read,
  model list, thread start, turn start, notifications, approvals, cancellation,
  and process exit.
- Use an isolated disposable `CODEX_HOME` and a read-only repository.
- Normalize live notifications into `openagents.scv.event.v1` and persist an
  `openagents.scv.report.v1` terminal result.
- Compare behavior with the stable Python SDK and capture protocol fixtures.

### Phase 2: Individual operator account connection

- Add restricted account and login-attempt records.
- Implement the device-code ceremony with one temporary process per attempt.
- Register each temporary process through the cluster registry so a LiveView
  reconnect on another fleet node can recover the same ceremony. Limit an
  unclustered web lane to one instance while the ceremony remains in memory.
- Add account read, model, rate-limit, health, drain, disconnect, and audit
  operations.

### Phase 3: Pay-as-you-go service accounts

- Confirm the selected ChatGPT workspace uses a pay-as-you-go plan before
  presenting or accepting a service-account credential.
- Add service-account access-token secret references without showing saved
  token values after entry.
- Prove rotation by draining the old account runtime, starting a new runtime
  generation, and revoking the old token after the replacement passes a
  bounded smoke test.
- Keep personal access tokens as a separate operator-attributed fallback, not
  as a service-account substitute.

### Phase 4: Account runtime scheduler

- Add one runtime generation and one capacity lease per account.
- Bind every SCV execution to one account, credential revision, Codex version,
  schema digest, and thread ID.
- Add quota-aware admission, health backoff, restart limits, and reauthentication
  state.
- Add live public SCV projection and restricted driver diagnostics.

### Phase 5: Propose-only SCV qualification

- Run bounded read-only investigation and candidate proposal tasks.
- Prove cancellation, report durability, event continuity, exact-SHA binding,
  resource collection, and restart behavior.
- Keep repository writes, pushes, Forge promotion, and deployment disabled.

### Phase 6: Credential-free effect execution

- Separate app-server credentials from candidate command and file effects.
- Add a durable pre-effect receipt and idempotency boundary.
- Prove that a synthetic credential cannot be read from environment,
  filesystem, process metadata, sockets, logs, or artifacts.
- Run adversarial repository instructions and build scripts with network denied.

### Phase 7: Bounded write admission

- Enable only a repository-scoped propose branch and admitted path and command
  policy.
- Require exact-SHA tests, event and report artifacts, independent workspace
  inspection, and human promotion.
- Consider staging autonomy only after the general SCV and Forge gates in
  [SCV planning](scv-planning.md) pass.

## Qualification checklist

Do not call the Codex-backed driver ready until it proves all of these items:

- Two separately connected accounts run in different Codex homes and cannot
  see each other's identity, threads, history, credentials, plugins, or MCP
  state.
- A new device login cannot cancel another account's pending connection.
- Service-account token rotation drains the old generation without changing a
  running thread's identity.
- `gpt-5.6-luna` with `low` or `none` reasoning is verified through
  `model/list`; an unavailable model fails closed.
- A user can see bounded live SCV activity during the run.
- The complete final SCV report and event artifact survive app-server exit.
- Cancellation stops the turn, descendants, and account capacity lease.
- Restart recovery never repeats an uncertain command or file effect.
- Approval requests route to the correct SCV, turn, operator, and generation.
- Unknown server requests fail closed.
- Rate-limit updates stop new claims and never trigger quota-evasion routing.
- A synthetic credential is absent from command environments, filesystem
  reads, `/proc`, diagnostics, crash output, transcripts, and artifacts.
- Candidate code has no OpenAI, Forge operator, production database, release,
  or cloud credential.
- The pinned schema, stable Python SDK comparison, runtime digest, rollback
  image, and support decision are recorded.

## Open questions

- Will OpenAI support `openagents_scv` as a direct app-server client, or should
  production use the stable Python SDK bridge?
- After the individual operator path passes qualification, which ChatGPT
  workspace and pay-as-you-go plan will own the first SCV service account?
- Should staging and production use separate service accounts, separate
  workspaces, or both?
- Which encrypted persistent store will hold managed device-login homes with a
  single-writer compare-and-swap contract?
- Which stable Codex execution surface will provide the credential-free effect
  compartment: a remote environment, a code-mode host, dynamic tools, or an
  SCV-owned sidecar?
- What private transcript retention period satisfies repository and workspace
  policy?
- What account reserve and maximum concurrency should benchmarks admit?

These questions block production authority, but they do not block a local,
read-only protocol and device-login spike.
