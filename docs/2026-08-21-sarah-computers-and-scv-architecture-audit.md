# Sarah, connected computers, and SCVs

**Date:** 2026-08-21
**Commit measured:** `50b882b8d909` (origin/main)
**Question:** How does Sarah interact with connected computers, how is the SCV system implemented, are the two connected, and what stands between today's code and Sarah deploying SCVs that run on system capacity instead of a person's own machine?
**Method:** direct reading of `lib/openagents/computer.ex`, `lib/openagents/computer_agent_jobs.ex`, `lib/openagents/work/`, `lib/openagents_web/channels/`, `lib/openagents/machines*`, `lib/openagents/tools/`, the whole `lib/openagents/scv/` tree, `lib/openagents/application.ex`, `config/`, `priv/repo/migrations/`, `ops/scv/`, and `infra/staging/`, plus bidirectional reference searches between the two subsystems. Every architectural claim cites a file and line current at the measured commit. Claims that could not be established from code are collected in section 7 rather than guessed at. Where `docs/scv-planning.md` describes behavior the code does not implement, section 6 says so.

---

## 0. Verdict

Both systems exist, both work, and they share no module, schema, job kind, or receipt type.

The connected-computer path is a complete remote execution system: a paired machine holds an authenticated WebSocket to the fleet, Sarah addresses it by machine id through a cluster-wide registry, a durable `work_jobs` row survives node death and resumes the remote session, and output streams into chat while it runs. What it lacks is capacity of our own — every delegation ends on hardware the customer owns and powers.

The SCV system is a complete execution *contract*: a typed run, an admitted environment with declared capabilities, a permission profile, pluggable drivers, sanitized events, and a durable terminal row. What it lacks is a way in. It splits into two lanes that share a struct and share almost nothing else, and neither lane can be started by Sarah:

- **Lane A, OpenCode.** A separate BEAM release booted in `runtime_role: :scv` inside a container. Its objective arrives as `SCV_OBJECTIVE` in the process environment (`lib/openagents/scv/worker.ex:61`), so submitting work means launching a container. It writes no database rows at all.
- **Lane B, Codex app server.** Durable, fenced, leased, reaped — and it runs as a `Port` child of the *web* node (`lib/openagents/runtime_supervisor.ex:35`). Its dispatcher, `OpenAgents.SCV.CodexRuns.start/5` (`lib/openagents/scv/codex_runs.ex:13`), has no caller anywhere in `lib/`. Only tests call it.

So the two halves of the owner's goal are already built, in separate places, facing away from each other:

| Half the goal needs | Where it lives today | What it is missing |
|---|---|---|
| Remote dispatch, streaming, durable jobs, recovery | the connected-computer path | our own capacity to dispatch to |
| Bounded execution with capability admission and receipts | the SCV system | a runtime entry point Sarah can call |

Neither is missing machinery the other has not already solved once. The work is joining them, and the join has a named seam on each side: `OpenAgents.Work.Job`'s `kind` field (`lib/openagents/work/job.ex:18`), and the `OpenAgents.SCV.Runner` behaviour (`lib/openagents/scv/runner.ex:6`), which today has exactly one implementation and it is in-process (`lib/openagents/scv/runner/local.ex:18`).

The precedent for the whole shape already shipped. The `coding` job kind runs Sarah's own multi-step work on our fleet, on our capacity, with its own approval class, its own sandbox, and metering into the shared grant ledger (`lib/openagents/work/coding.ex:1`). Sarah-deployed SCVs are that pattern again with a different executor.

One caveat frames everything below: an SCV worker refuses to boot in production. `config/runtime.exs:418` raises `"an SCV worker is admitted only in staging"` unless `OPENAGENTS_ENVIRONMENT` is `staging`, and the Codex lane's feature flag defaults to `false` (`config/config.exs:57`). Today's SCV system is a staging capability, not a production one.

---

## 1. Sarah's connected-computer path

### 1.1 Pairing and identity

A computer becomes addressable through a three-legged, code-based, owner-approved pairing flow (`lib/openagents/machines.ex:2`): the CLI starts a pairing unauthenticated, the signed-in account owner approves it in the browser, and the CLI claims it once with a poll secret.

1. **Start.** `POST /controller/pairings` (`lib/openagents_web/router.ex:215`) generates an eight-character code from an ambiguity-free alphabet (`lib/openagents/machines.ex:18`) and a 32-byte poll secret, storing only SHA-256 digests of both (`lib/openagents/machines.ex:33`). The pairing lives 600 seconds (`lib/openagents/machines.ex:17`).
2. **Approve.** The owner approves at `/computers` (`lib/openagents_web/router.ex:105`). Inside one transaction, `do_approve_pairing/3` locks the pairing and user rows, enforces a cap of eight active machines (`lib/openagents/machines.ex:20`), mints a token `smct_` plus 32 random bytes (`lib/openagents/machines.ex:80`), seals the plaintext with AES-256-GCM (`lib/openagents/machines/token_vault.ex:13`), and stores only the digest.
3. **Claim.** `GET /controller/pairings/:id` with an `x-pairing-secret` header compares the poll-secret digest with `Plug.Crypto.secure_compare` (`lib/openagents/machines.ex:128`), returns the plaintext token once, and wipes the ciphertext (`lib/openagents/machines.ex:332`).

The durable identity is the `machines` table (`lib/openagents/machines/machine.ex:13`). Two of its fields carry authority rather than description:

- `tier`, a capability ladder validated against `probe`, `curated`, and `shell` (`lib/openagents/machines/machine.ex:11`) and re-checked by a database constraint (`priv/repo/migrations/20260817140345_create_machines.exs:25`).
- `roots`, the array of filesystem paths the owner admitted, capped at 16 entries of 512 bytes (`lib/openagents/machines/machine.ex:50`).

This is unrelated to the `device_authorizations` table, which is a separate OAuth-device-style flow minting `forge:write` API tokens for the OpenAgents CLI (`lib/openagents/device_authorizations/device_authorization.ex:15`). No code path links the two.

### 1.2 Transport

The transport is a Phoenix socket mounted at `/controller/socket` (`lib/openagents_web/endpoint.ex:25`), serving one channel topic pattern, `computer:*` (`lib/openagents_web/channels/controller_socket.ex:15`).

Authentication happens in `connect/3`, which requires the feature flag and a machine token and assigns only identifiers (`lib/openagents_web/channels/controller_socket.ex:19`). `Machines.authenticate_token/1` requires the `smct_` prefix, a length under 128 bytes, a digest match, `status == "active"`, and an unexpired token (`lib/openagents/machines.ex:144`). The socket id is `controller_socket:#{machine_id}` (`lib/openagents_web/channels/controller_socket.ex:34`), so a single machine can be disconnected by id.

Joining re-authorizes three times over (`lib/openagents_web/channels/computer_channel.ex:22`): the topic's machine id must equal the socket's own, the machine must still resolve for that user, and its status must be `active`. A successful join registers the channel, subscribes to the machine's PubSub topic, records the sighting, schedules token expiry, and returns the protocol version `openagents.computer.v1`.

Message names are explicit in both directions. The server pushes `probe`, `cancel`, and the request kind stringified — `run`, `devin`, or `agent` (`lib/openagents_web/channels/computer_channel.ex:129`). The controller sends `hello`, `probe_result`, `probe_refused`, `chunk`, `session`, `exit`, and `refused` (`lib/openagents_web/channels/computer_channel.ex:50`–`110`); anything else is refused as `unknown_event` (`lib/openagents_web/channels/computer_channel.ex:117`). Every inbound payload is JSON-encoded and measured against a 64 KB ceiling (`lib/openagents_web/channels/computer_channel.ex:19`). Every request carries a server-minted `request_id`.

### 1.3 Addressing across the fleet

`OpenAgents.Computer` registers each connected machine's channel process under `{:machine, machine_id}` in the cluster-wide `OpenAgents.HordeRegistry` (`lib/openagents/computer.ex:2`). Channel pids are location-transparent, so any node can reach a controller whose WebSocket terminates elsewhere. Timeouts are tiered: 15 seconds for a probe, 120 seconds for a shell run, one hour for an agent delegation (`lib/openagents/computer.ex:24`).

### 1.4 How Sarah dispatches

Sarah reaches computers through five installed tools — `computer_list`, `computer_probe`, `computer_run`, `computer_devin`, and `computer_agent` — registered in the catalogue at `config/config.exs:138`. Three of them are always included when the person has a paired machine (`lib/openagents/tools/selector.ex:21`). All declare `required_scope: "browser_conversation"` and `required_authority: "computer.control"` (`lib/openagents/tools/computer_agent.ex:53`).

The durable coding delegation converges on one owner-scoped entry point, `OpenAgents.ComputerAgentJobs.start/5`, which both the `computer_agent` tool and the signed-in Computers API enter so that ownership, presence, probe evidence, and directory scope cannot drift between surfaces (`lib/openagents/computer_agent_jobs.ex:2`). It runs six checks before any work starts (`lib/openagents/computer_agent_jobs.ex:34`): the feature is enabled, the user owns both the machine and the conversation, the machine is `active` and online, the requested `agent_id` appears in the machine's last probe inventory, the prompt is within bounds, and the working directory sits inside an admitted root with no `..` segments (`lib/openagents/computer_agent_jobs.ex:133`).

Only then does it build the durable row, capturing three maps at start time (`lib/openagents/computer_agent_jobs.ex:42`): `delegation` (the request), `authority_snapshot` (machine tier, admitted roots, working directory, agent id, machine name), and `budget_snapshot` (one-hour wall clock, 8,000-byte prompt cap, 8,000-byte report cap).

The durable record is `OpenAgents.Work.Job`, table `work_jobs`. Its `kind` is validated against exactly three values (`lib/openagents/work/job.ex:18`):

```elixir
@kinds ~w(deep_work delegation coding)
```

and its `status` against seven (`lib/openagents/work/job.ex:15`): `queued`, `running`, `completed`, `failed`, `interrupted`, `budget_exhausted`, `cancelled`. The row also carries `owner_node` and `generation` (`lib/openagents/work/job.ex:50`), which are the fencing tokens for recovery.

Postgres enforces the invariants rather than trusting the application. A trigger makes identity immutable and status transitions forward-only (`priv/repo/migrations/20260818003358_create_work_jobs.exs:58`), a constraint requires terminal jobs to carry a report (`priv/repo/migrations/20260818003358_create_work_jobs.exs:53`), and a second trigger re-verifies on every write that the conversation owner matches, that the machine belongs to that owner through `visitors.user_id`, and that the authority snapshot equals the machine's live `tier`, `roots`, and `name` (`priv/repo/migrations/20260820085203_harden_async_runtime_boundaries.exs:83`).

Each job runs as a cluster-wide singleton under Horde, so the supervisor relocates it to a survivor when its node dies (`lib/openagents/work.ex:113`). A `delegation` job is driven by `OpenAgents.Work.DelegationServer`, a `:transient` GenServer that runs one `Computer.request_agent` call to completion in its own process so the requesting turn returns immediately and several delegations run at once (`lib/openagents/work/delegation_server.ex:1`).

### 1.5 Streaming back into chat

While a delegation runs, `OpenAgents.ComputerActivity` re-broadcasts a bounded projection on the owner's conversation topic, `computer_live:#{conversation_id}` (`lib/openagents/computer_activity.ex:44`), emitting four event types: started, chunk, truncated, and terminal. The module is explicit that this is a projection and never the authority — nothing broadcast is persisted, a missed broadcast loses nothing durable, and a reload mid-delegation degrades to status only (`lib/openagents/computer_activity.ex:9`). Caps are 16 KB per event, 64 KB cumulative, 512 chunk events (`lib/openagents/computer_activity.ex:33`).

`ChatLive` subscribes at mount and keeps one live panel at a time, superseding older delegations into a bounded summary list (`lib/openagents_web/live/chat_live.ex:269`). Chunk text never enters an assign; it is pushed to the client as a `delegation:chunk` event and rendered by a colocated hook (`lib/openagents_web/live/chat_live.ex:313`).

The durable report goes through `OpenAgents.Computer.AcpTranscript`, which decodes the controller's framed progress stream — record separator `0x1E`, fields split on unit separator `0x1F` — into readable prose and tool lines (`lib/openagents/computer/acp_transcript.ex:1`). Its moduledoc names the bug it exists to prevent: durable reports used to post the raw bytes, so a timeout wrote wire framing into the conversation. It labels eight tool kinds — `execute`, `read`, `edit`, `search`, `fetch`, `think`, `move`, `delete` (`lib/openagents/computer/acp_transcript.ex:16`) — and lists started-but-unfinished tools as in progress.

When the job finishes, `Work.finish_job/3` inserts an assistant `Message` carrying `work_job_id` inside the same transaction and links it back as `report_message_id` (`lib/openagents/work.ex:483`), so the report is a durable chat message rather than a broadcast.

### 1.6 Lifecycle and recovery

- **Cancel** is a first-class message. `ChatLive` calls `Work.cancel_active_delegations/2` (`lib/openagents_web/live/chat_live.ex:97`), which casts to the Horde singleton; the server kills the task, appends a cancellation note, and finishes the job `cancelled` (`lib/openagents/work/delegation_server.ex:59`).
- **Caller death** cancels the remote work: the channel monitors the requesting process and pushes `cancel` on `:DOWN` (`lib/openagents_web/channels/computer_channel.ex:144`).
- **Timeout** produces a synthetic terminal marked `truncated` and pushes a cancel rather than leaving the remote agent running (`lib/openagents/computer.ex:160`).
- **Revocation** is enforced live: a `machine_revoked` broadcast terminates the channel (`lib/openagents_web/channels/computer_channel.ex:155`), and token expiry is scheduled at join (`lib/openagents_web/channels/computer_channel.ex:30`).
- **Reconnect races** are refused rather than double-registered: a stale registration from a dead node yields `machine_reconnecting` and the controller's retry loop handles it (`lib/openagents_web/channels/computer_channel.ex:37`).
- **Node death** is survivable and, for delegations, *resumable*. `Work.recover_interrupted_jobs/0` runs at boot (`lib/openagents/work_recovery.ex:12`), records a `runtime_restarted` incident, and restarts each active job's worker with backoff, only marking a job `interrupted` after retries are exhausted (`lib/openagents/work.ex:566`). The restarted `DelegationServer` adopts the row through the generation fence and re-attaches the same session using a durably checkpointed session id held in both the job row and Ra (`lib/openagents/work.ex:645`), waiting up to 90 seconds for the controller to re-register (`lib/openagents/computer.ex:183`).

### 1.7 The trust boundary

The boundary is the person's explicit pairing, expressed as a receipt rather than a flag. `Machines.approval_receipts/2` mints one `sarah.module_approval.v1` receipt per active, unexpired machine per machine-effect module, with `approval_class` set to `explicit_operator_approval`, `actor_type` `operator`, and `receipt_ref` pointing at the machine (`lib/openagents/machines.ex:204`). The moduledoc is explicit that approving the pairing on `/computers` *is* the operator approval (`lib/openagents/machines.ex:196`).

Enforcement is real, not advisory. `OpenAgents.Modules.SurfacePolicy` requires a receipt whose schema, approval class, module id, version, scope ref, explicitness, and actor type all match the artifact, and returns `{:error, :module_approval_required}` otherwise (`lib/openagents/modules/surface_policy.ex:114`).

Two honest limits are worth recording:

- **Tier is carried but never enforced server-side.** `machine.tier` is snapshotted into `authority_snapshot` and cross-checked against the live row by a database trigger, but no code in `lib/` refuses a `run` or `agent` request because the tier is too low. Both tool moduledocs state that the machine's own policy decides and can return a typed refusal (`lib/openagents/tools/computer_agent.ex:8`). The final authority lives in the controller, which is a separate repository, `OpenAgentsInc/sarah-computer-controller` (`lib/openagents/tools/computer_agent.ex:63`), not in this codebase.
- **`computer_run` does not check `cwd` against `roots`.** Unlike `ComputerAgentJobs`, the synchronous run tool only bounds its argv (`lib/openagents/tools/computer_run.ex:91`); path scoping for that path is delegated entirely to the controller.

There is no per-delegation approval prompt anywhere in this repository. The one human approval is the one-time pairing.

---

## 2. The SCV system

### 2.1 What an SCV is

SCV means Space Construction Vehicle (`docs/scv-planning.md:17`). That expansion appears only in the planning document; no code carries it.

In code, an SCV is a bounded, single-objective execution of a coding agent against one repository under a declared capability set and permission profile. `OpenAgents.SCV` states the ownership directly (`lib/openagents/scv.ex:2`):

> The SCV owns the run contract. A driver supplies one coding implementation, such as OpenCode, and an environment supplies the admitted runtime capabilities. Callers deploy SCVs rather than deploying drivers directly.

The facade is one line of indirection (`lib/openagents/scv.ex:13`):

```elixir
def run(%Run{runner_module: runner} = run), do: runner.run(run)
```

The request struct is `OpenAgents.SCV.Run` (`lib/openagents/scv/run.ex:21`), requiring ten fields including `driver_module`, `environment`, `runner_module`, `runner_id`, `permission_profile`, and `capabilities`. `Run.new/3` performs capability admission: it computes `driver_module.required_capabilities(profile)` and rejects with `:capability_mismatch` if the environment does not cover it (`lib/openagents/scv/run.ex:71`). The objective and driver options are excluded from `Inspect` output (`lib/openagents/scv/run.ex:6`).

### 2.2 Environment and drivers: the capability contract

`OpenAgents.SCV.Environment` describes what an SCV may do, and is explicit that the environment id selects an immutable image at deployment time and does not identify the SCV or its driver (`lib/openagents/scv/environment.ex:2`). Two environments are admitted, and the pairing of each to an image is the clearest statement of where each lane runs:

| Environment | Image | Capabilities | Runtimes |
|---|---|---|---|
| `opencode-core` (`lib/openagents/scv/environment.ex:20`) | `scv-opencode-core` | inference, egress, execute, workspace read **and write** | elixir, git, node, bun, python |
| `codex-app-server` (`lib/openagents/scv/environment.ex:36`) | `openagents` | inference, egress, execute, workspace read | codex, git |

The second one names the *web* image. The Codex lane is not a separate container at all.

`OpenAgents.SCV.Driver` is a three-callback behaviour whose moduledoc sets the boundary: drivers may use different tool protocols, but every driver runs inside the same SCV lifecycle, capability, event, and receipt boundary (`lib/openagents/scv/driver.ex:2`). Selection is an allowlist returning `:driver_not_admitted` for anything else (`lib/openagents/scv/driver.ex:16`).

Both drivers spawn a local operating-system process with `Port.open` and `{:spawn_executable, …}` (`lib/openagents/scv/executor/open_code.ex:219`, `lib/openagents/scv/codex_app_server.ex:176`), and both scrub the inherited environment by mapping every existing variable to `false` before merging a small allowlist (`lib/openagents/scv/executor/open_code.ex:672`, `lib/openagents/scv/codex_app_server.ex:198`). **Neither driver has any remote dispatch.** An SCV always runs an OS process on the same host as the BEAM that called it.

Their sandboxes differ in kind:

- **OpenCode** runs a one-shot CLI and parses JSON lines from stdout, with a tool permission map that denies `bash`, `edit`, `external_directory`, `lsp`, `question`, `skill`, `task`, `webfetch`, and `websearch`, allowing only `glob`, `grep`, `list`, and `read` (`lib/openagents/scv/executor/open_code.ex:724`). The `:workspace_write` profile flips `edit` to allow (`lib/openagents/scv/executor/open_code.ex:742`). The process keeps network egress; only the tools are denied.
- **Codex app server** speaks bidirectional JSONL JSON-RPC over stdio, keeps stdout protocol-only, and rejects server requests it does not implement with `-32601` (`lib/openagents/scv/codex_app_server.ex:141`). It writes a per-run `config.toml` setting `approval_policy = "never"`, pinning the workspace root, and disabling network entirely (`lib/openagents/scv/executor/codex_app_server.ex:670`), then asserts the server echoed back the expected permission profile or fails (`lib/openagents/scv/executor/codex_app_server.ex:243`). It also enforces a structured `outputSchema` and re-validates the result locally (`lib/openagents/scv/executor/codex_app_server.ex:264`).

Credentials differ accordingly. OpenCode needs only `OPENAI_API_KEY` from the process environment, persisted nowhere. Codex needs a whole ChatGPT credential home, held behind the `OpenAgents.SCV.CodexCredentialStore` behaviour with two implementations: a `chmod 0600` local file (`lib/openagents/scv/codex_credential_store/file.ex:40`) and GCP Secret Manager, which pins reads to a stored integer version rather than `latest` (`lib/openagents/scv/codex_credential_store/gcp_secret_manager.ex:30`). Per run, the credential is materialized into an ephemeral `CODEX_HOME` and removed in an `after` block (`lib/openagents/scv/executor/codex_app_server.ex:27`), and its secrets are scraped into a redaction list applied to all report text (`lib/openagents/scv/executor/codex_app_server.ex:696`).

### 2.3 Lane A: the OpenCode container

`OpenAgents.Application.start/2` branches the *entire* boot on `:runtime_role`, defaulting to `:web` (`lib/openagents/application.ex:10`):

```elixir
case Application.get_env(:openagents, :runtime_role, :web) do
  :scv -> start_scv_worker()
```

The `:scv` role starts nothing else — no Repo, no Endpoint, no runtime supervisor. It starts one `:temporary` Task (`lib/openagents/application.ex:81`) that calls `SCV.Worker.run_from_env!()` (`lib/openagents/application.ex:118`) and then halts the VM with `System.stop/1` (`lib/openagents/application.ex:126`). The whole node exists to run one SCV and exit.

Its input is the process environment. `parse_environment/1` requires `SCV_REPOSITORY`, `SCV_OBJECTIVE`, and `OPENAI_API_KEY`, and allowlists `SCV_DRIVER` to `opencode` only, `SCV_ENVIRONMENT` to `opencode-core` only, and `SCV_PERMISSION_PROFILE` to `read_only` only (`lib/openagents/scv/worker.ex:60`). The container therefore cannot run the Codex driver or write to a workspace.

The image bakes those values plus `OPENAGENTS_RUNTIME_ROLE=scv`, runs as uid 10001, and copies the repository into itself at `/workspace/openagents` with `SCV_REPOSITORY_REVISION` set to the build revision (`ops/scv/images/opencode-core/Dockerfile:164`). Base images are pinned by digest against a Debian snapshot (`ops/scv/images/versions.env`). `SCV_OBJECTIVE` and `OPENAI_API_KEY` are deliberately not baked in.

**This lane writes no database rows.** There is no `Repo.` call anywhere in `worker.ex`, `runner/local.ex`, `driver/open_code.ex`, `executor/open_code.ex`, `run.ex`, or `scv.ex`. Results are JSON lines on stdout: chunked report frames followed by one `openagents.scv.worker.result.v1` carrying status, duration, event count, tool calls, usage, resources, and a sha256 digest (`lib/openagents/scv/worker.ex:239`).

### 2.4 Lane B: the durable Codex path, and its missing caller

The second lane is where the durable design lives. `OpenAgents.SCV.Execution` is the "durable authority and terminal receipt for one Codex-backed SCV run" (`lib/openagents/scv/execution.ex:2`), stored in table `scv_runs` (`lib/openagents/scv/execution.ex:16`). Terminal statuses are `succeeded`, `failed`, `cancelled`, and `uncertain` (`lib/openagents/scv/execution.ex:14`) — note `uncertain`, which the job side has no equivalent of. There is no `queued` state; a row is inserted already `running` (`lib/openagents/scv/execution.ex:80`).

`OpenAgents.SCV.Executions` "claims, fences, records, and completes durable SCV executions" (`lib/openagents/scv/executions.ex:2`). `claim/4` takes `FOR UPDATE` on the driver account, computes a monotonically increasing `generation`, records `owner_node`, and sets a 120-second lease (`lib/openagents/scv/executions.ex:24`). Every persisted event renews the lease under a fence of id, status, owner node, and generation, rolling back with `:stale_execution_generation` if the fence does not match exactly one row (`lib/openagents/scv/executions.ex:229`). `OpenAgents.SCV.ExecutionReaper` sweeps expired leases to `uncertain` every 30 seconds (`lib/openagents/scv/execution_reaper.ex:2`), gated on its own flag (`lib/openagents/runtime_supervisor.ex:54`).

Where does it run? `OpenAgents.SCV.CodexRun` is a `:temporary` GenServer started under `OpenAgents.SCV.CodexRunSupervisor`, a plain node-local `DynamicSupervisor` in the *web* supervision tree (`lib/openagents/runtime_supervisor.ex:35`). The Codex binary is a `Port` child of that same BEAM. Its workspace is a fresh `git clone --no-local --no-checkout` with `core.hooksPath=/dev/null`, detached at the requested revision, verified clean, and destroyed in an `after` block (`lib/openagents/scv/workspace.ex:23`).

The dispatcher is `OpenAgents.SCV.CodexRuns.start/5` (`lib/openagents/scv/codex_runs.ex:13`). **It has no caller in `lib/`.** A search for `CodexRuns.` outside its own module returns only `test/openagents/scv/codex_runs_test.exs`.

The lane is hard-wired read-only. The claim changeset forces `driver`, `permission_profile: "read_only"`, `model`, and `status` regardless of what the caller passed (`lib/openagents/scv/execution.ex:77`), and a database constraint independently restricts `permission_profile` to `read_only` (`priv/repo/migrations/20260821082652_create_scv_runs.exs:50`). There is no code path to a writing Codex SCV.

The only SCV web surface is `/admin/scv/accounts` (`lib/openagents_web/router.ex:185`), behind an operator pipeline that requires an admin user (`lib/openagents_web/router.ex:60`). Its two events are `connect_account` and `cancel_login` (`lib/openagents_web/live/admin_scv_accounts_live.ex:30`). It manages credentials, not runs.

### 2.5 Receipts, quotas, and observability

The SCV side persists more per run than the job side does, and it sanitizes harder.

Every event is filtered before insert: the schema must be exactly `openagents.scv.event.v1`, and the payload is reduced to a fixed 20-key allowlist (`lib/openagents/scv/executions.ex:16`) and rejected above 16 KB, with the database enforcing the same bound (`priv/repo/migrations/20260821082652_create_scv_runs.exs:89`). No file paths, tool arguments, tool output, or report prose reach an event row; thread and turn identifiers are one-way hashed (`lib/openagents/scv/executor/codex_app_server.ex:762`). The terminal row holds `report`, `report_digest`, `usage`, and `resources`, each size-capped and degrading to `%{"truncated" => true}` rather than failing (`lib/openagents/scv/executions.ex:321`).

Two quotas exist, and both are structural rather than policy:

1. **One active run per driver account**, enforced by a unique partial index on `(driver_account_id) WHERE status = 'running'` (`priv/repo/migrations/20260821082652_create_scv_runs.exs:41`) and mirrored in the changeset (`lib/openagents/scv/execution.ex:83`).
2. **A fixed number of driver accounts**, since `credential_refs` is a static configuration list (`config/config.exs:61`), and creating an account rolls back with `:account_capacity_reached` when no slot is free (`lib/openagents/scv/codex_accounts.ex:236`).

There is no rate limit, no token budget, no cost cap, and no per-user quota. `scv_runs` has **no user foreign key**; its only principal is a synthesized string, `"scv:codex_app_server:#{account.id}"` (`lib/openagents/scv/executions.ex:37`). Isolation is per driver account, not per person. An `issue_id` foreign key was the only link to a work source, and nothing in `lib/` ever set it; #152 dropped it, leaving `forge_assignments` as the one record that binds an issue to an attempt.

Nothing meters an SCV against a grant or a ledger. `OpenAgents.SCV.OpenCodeEvents` accumulates token counts and a `cost_usd` figure read from OpenCode's own output (`lib/openagents/scv/open_code_events.ex:25`), and the mix task prints it, but no code posts it anywhere. `OpenAgents.SCV.ResourceSampler` shells out to `ps` for bounded RSS and CPU, noting that container workers would replace the adapter with cgroup measurements while preserving the result shape (`lib/openagents/scv/resource_sampler.ex:2`). "Receipt" appears in moduledocs (`lib/openagents/scv/execution.ex:2`), but there is no receipt type.

Public visibility is deliberately thin. `OpenAgents.SCV.Activity` keeps at most 32 live entries for 30 seconds each, replaces each run id with a truncated hash, allowlists tool names to ten values, and maps each event type to a fixed English sentence (`lib/openagents/scv/activity.ex:158`). `NetworkStatus` merges that with a database projection for `/status` and `/api/status` (`lib/openagents/network_status.ex:282`).

---

## 3. The two paths side by side

| Axis | Connected computer | SCV lane A (OpenCode) | SCV lane B (Codex) |
|---|---|---|---|
| Where compute runs | The person's own machine | A one-shot container, staging only | **The web BEAM node**, as a `Port` child |
| Who authorizes | The machine's owner, by pairing (`lib/openagents/machines.ex:204`) | Whoever launches the container | An admin who connected a driver account (`lib/openagents_web/router.ex:185`) |
| Authorization artifact | `sarah.module_approval.v1`, class `explicit_operator_approval` | None | None |
| Transport | Phoenix channel over WebSocket, topic `computer:*` | None; `Port` to a local process | None; `Port` to a local process |
| Protocol | `openagents.computer.v1` carrying framed ACP | JSON lines on stdout | JSONL JSON-RPC over stdio |
| Unit of work | `work_jobs` row, `kind: "delegation"` | `%SCV.Run{}` struct only | `%SCV.Run{}` plus a `scv_runs` row |
| Work identity | Job UUID, scoped to conversation and owner visitor | Run UUID, unpersisted | Run UUID, scoped to a driver account; **no user FK** |
| How work is submitted | A model tool call or the Computers API | `SCV_OBJECTIVE` at container boot (`lib/openagents/scv/worker.ex:61`) | `CodexRuns.start/5` — **no production caller** |
| Streaming | Live into chat via PubSub projection | JSON lines to stdout | Sanitized event rows plus the live `Activity` ring |
| Persistence | Job row, job steps, decoded report, chat message | **None** | Execution row, event rows, report plus digest |
| Failure and recovery | Horde relocation, generation fence, session resume | None; the container exits | Lease expiry swept to `uncertain`; no resume |
| Write access | Per the machine's own tier and roots | `read_only` only at this entry point | `read_only`, forced by changeset and constraint |
| Concurrency limit | Eight machines per account | Whatever is launched | One active run per driver account |
| Cost model | The customer's hardware | Our container | Our web node's CPU. Unmetered |
| Enabled by default | No (`lib/openagents/computer.ex:30`) | The image is the role | No (`config/config.exs:57`) |
| Production | Yes, when flagged on | **Refused at config load** (`config/runtime.exs:418`) | Flag-gated |

Two things stand out. First, the SCV side is *stronger* on sandboxing, payload sanitization, and per-run measurement; the computer side is stronger on dispatch, streaming, and recovery. Second, both independently implemented the same durable-worker pattern — `owner_node`, `generation`, and a lease or fence — in `work_jobs` (`lib/openagents/work/job.ex:50`) and in `scv_runs` (`lib/openagents/scv/execution.ex:27`), with no shared code.

---

## 4. Are they connected?

No. They share no module, no schema, no job kind, and no receipt type.

The evidence is a search in both directions at the measured commit:

- Searching `lib/openagents/scv/`, `lib/openagents/scv.ex`, and the SCV mix task for `computer`, `machine`, `device_auth`, `controller`, `acp`, `transcript`, `delegat`, `persona`, `sarah`, or `chat` returns ten hits, and every one of them is the substring `chatgpt` inside Codex login code. Nothing else.
- Searching the computer, machines, device-authorization, persona, tools, and conversations trees for `scv` returns nothing.
- No SCV migration references `machines`, `computers`, `device_authorizations`, or any controller table; no non-SCV migration references any `scv_*` table.

Outside its own tree, `OpenAgents.SCV` is referenced from exactly six files, none of which is a delegation path: `lib/openagents/application.ex`, `lib/openagents/runtime_supervisor.ex`, `lib/openagents/network_status.ex`, `lib/openagents_web/live/network_status_live.ex`, `lib/openagents_web/live/admin_scv_accounts_live.ex`, and `lib/mix/tasks/openagents.scv.opencode.ex`. There is no SCV controller and no SCV channel.

`NetworkStatus` is the only surface where both systems appear at once, and even there they are siblings rather than collaborators: it publishes SCV activity as a pseudonymous label with lifecycle state, and connected controller machines as a count only (`lib/openagents/network_status.ex:11`). Both are read-only projections. Nothing flows between them.

Sarah's installed tool catalogue confirms the same from her side (`config/config.exs:130`–`151`): the computer family, `deep_work`, the repository family, and the memory family. There is no SCV tool. **Sarah cannot start an SCV, list one, read one, or cancel one.**

Two couplings do exist and should be named honestly, because neither is a code dependency:

1. **A shared deployment surface.** The root `Dockerfile:170` installs the OpenAI `codex` binary into the web and fleet image, and `infra/staging/main.tf:404` grants the fleet service account read and add permissions on the SCV Codex credential secrets. The host that serves the web app carries the binary and the credentials. That is why lane B can run on the web node at all.
2. **A shared approval vocabulary.** `sarah.module_approval.v1` already carries two distinct classes — `explicit_operator_approval` for machine effects (`lib/openagents/machines.ex:204`) and `exact_current_user_consent` for coding-job repository writes (`lib/openagents/tools/repository.ex:169`) — both enforced at one choke point (`lib/openagents/modules/surface_policy.ex:114`). SCV uses neither, but that vocabulary is where a third class would go.

---

## 5. The gap to "Sarah deploys SCVs on system capacity"

### 5.1 What is actually missing

Five gaps. None requires inventing a pattern this codebase has not already used.

1. **No target concept.** `ComputerAgentJobs.start/5` takes a `%Machine{}` and nothing can stand in its place (`lib/openagents/computer_agent_jobs.ex:20`). "Where does this work run" is not a value anywhere; it is implied by which function you call.

2. **No remote runner.** `OpenAgents.SCV.Runner` is a two-callback behaviour that anticipates alternatives (`lib/openagents/scv/runner.ex:6`), and `Runner.Local` is careful to say that it describes the in-environment process boundary, not the host that scheduled the container (`lib/openagents/scv/runner/local.ex:2`). But `Run.new/3` admits only `Local` (`lib/openagents/scv/run.ex:117`), and it calls `driver.run(run)` in-process. Nothing can place a run on another host.

3. **No runtime entry point.** Lane A's objective arrives at container boot; lane B's dispatcher is uncalled outside tests. Something must accept a run request while the web node is already up.

4. **No tool, and no authority to attach to it.** Sarah's machine tools declare `side_effect: :external_effect` with `approval_class: "explicit_operator_approval"` (`lib/openagents/tools/computer_agent.ex:73`), backed by a receipt pointing at a machine the person paired. A system-capacity SCV has no machine to point at, so it cannot reuse that receipt, and `SurfacePolicy` will refuse it (`lib/openagents/modules/surface_policy.ex:114`).

5. **No meter and no per-user bound.** `scv_runs` records `usage` and `resources` but posts them nowhere, has no user foreign key, and is bounded only by one-run-per-account. Work on a customer's machine is free to us; work on our capacity is not.

Two of these are smaller than they look. Lane B already runs on our capacity today — it just runs on the web node, uncalled. And `Environment` already models the capability half of a placement decision (`lib/openagents/scv/environment.ex:2`); only the host half is absent.

### 5.2 The two seams worth using

**On the work side, `kind`.** `OpenAgents.Work.Job` validates `kind` against three values (`lib/openagents/work/job.ex:18`), and each kind answers the same lifecycle questions differently while sharing the row, the statuses, the Horde singleton, the generation fence, the recovery sweep, and the report-into-conversation ending. `OpenAgents.Work.Coding` is the model to copy: its moduledoc says the loop itself is the ordinary `JobServer` and the module "only answers the kind-specific questions it asks" (`lib/openagents/work/coding.ex:2`). An `scv` kind would answer them by handing off to `SCV.run/1` instead of to an LLM loop.

**On the SCV side, `Runner`.** Placement belongs behind `runner_module`, exactly where the struct already puts it (`lib/openagents/scv/run.ex:22`). A second runner is where "our fleet" becomes a value rather than a deployment fact.

### 5.3 New questions once the capacity is ours

Delegating to someone's laptop is bounded by a fact outside our control: they own the machine, so the worst case is bounded by what they admitted. Running on our capacity removes that bound.

- **What replaces the pairing receipt?** There is no `%Machine{}` to reference. A third approval class is needed, and the `coding` kind shows the reasoning to imitate: starting the job is the person's exact current consent for the reversible writes inside the job's own clone, while the one external effect stays operator-only under host policy (`lib/openagents/tools/repository.ex:155`).
- **Whose repository, and under what tenancy?** `Run.repository` is a filesystem path (`lib/openagents/scv/run.ex:23`) and `scv_runs` scopes to a driver account, never to a conversation or a visitor. Customer-initiated SCVs cross a tenancy boundary neither schema models, and the current per-account concurrency limit would make one customer's run block another's.
- **Who pays, and what stops a loop?** `Work.Coding` already meters inference into the shared `inference_grants` ledger (`lib/openagents/work/coding.ex:2`). An SCV kind should meter into the same ledger rather than grow a second one.
- **What does the network see?** `NetworkStatus` publishes SCV activity content-free (`lib/openagents/network_status.ex:11`). That shape has to hold even when the content belongs to a customer.
- **Which permission profile, and where?** Both SCV entry points force `read_only` — the worker by allowlist (`lib/openagents/scv/worker.ex:67`), lane B by changeset and database constraint (`lib/openagents/scv/execution.ex:78`). Sarah writing code on our capacity means opening that, which is the moment isolation stops being theoretical. Lane B currently runs on the web node, which is the wrong place to relax it.
- **Where does production come from?** Lane A refuses to boot outside staging (`config/runtime.exs:418`). Any plan that ends in customers using this has to pass through that guard deliberately.

### 5.4 A staged path

**Increment 1 — give lane B its first production caller, operator-only.**
Wire `CodexRuns.start/5` to the existing admin surface (`lib/openagents_web/live/admin_scv_accounts_live.ex`, route at `lib/openagents_web/router.ex:185`). No new authority model, no customer exposure, no new schema, no new table. This turns the durable Codex path from tested-but-dead into exercised, and answers empirically whether `claim/4`, the lease fence, the reaper, and the sanitized event stream hold up in real use. It also surfaces immediately whether running Codex as a `Port` child of the web node is acceptable, or whether increment 2 has to come sooner than planned.

**Increment 2 — make placement a value.**
Add a second `OpenAgents.SCV.Runner` implementation that places a run on capacity separate from the web node, widen the `Run.new/3` runner allowlist (`lib/openagents/scv/run.ex:117`), and record the chosen runner on the durable row. This is where "system capacity" stops being a deployment fact and becomes a decision the code makes, and it is the increment that lets the write profile be opened safely later. Open design question, recorded in section 7: whether that runner launches a container per run or hands work to a warm pool. Nothing in the codebase decides this today.

**Increment 3 — give Sarah the tool, with its own approval class.**
Add an `scv` value to `@kinds` (`lib/openagents/work/job.ex:18`) and an `OpenAgents.Work.Scv` module shaped like `OpenAgents.Work.Coding` (`lib/openagents/work/coding.ex:1`), so an SCV job inherits the job row, the seven statuses, the Horde singleton, the generation fence, the recovery sweep, and the report-into-conversation ending. Then add one tool shaped like `deep_work`, which already returns a job reference immediately and lets multi-step work run server-side (`lib/openagents/tools/deep_work.ex:2`), carrying a third `approval_class` and metering into `inference_grants` alongside the coding kind. Sarah's live rail needs no new machinery if SCV events are projected through `ComputerActivity`'s existing contract (`lib/openagents/computer_activity.ex:1`); whether that module should then be renamed is a judgment call, not a technical one.

**The smallest honest first increment is increment 1.** It is the only one that adds no abstraction, and it converts the largest unknown in this audit — whether the durable Codex SCV path works outside its test suite — into a fact. Increments 2 and 3 are both cheaper once that is known, and riskier before.

---

## 6. Where the planning documents describe more than the code does

`docs/scv-planning.md` and `docs/scv-codex-app-server-planning.md` are design documents, and a reader who takes them as descriptions of the running system will be wrong about several things. Recorded here so this audit is not misread the same way:

- **Ten of the thirteen documented tables do not exist.** `docs/scv-planning.md:1110` specifies `scvs`, `scv_work_items`, `scv_steps`, `scv_workers`, `scv_worker_images`, `scv_executions`, benchmark tables, `scv_resource_samples`, and `scv_candidates`. Only `scv_runs` was built, alongside three tables the document never names: `scv_run_events`, `scv_driver_accounts`, and `scv_driver_login_attempts`.
- **The worker pool and capability-routing scheduler do not exist** (`docs/scv-planning.md:766`). No module, no table, no Terraform.
- **The states `idle`, `paused`, `circuit_open`, and `disabled`** appear in the UI component's attribute validation (`lib/openagents_web/components/graph.ex:122`) but in no schema. The live surface collapses everything to running or idle (`lib/openagents_web/live/network_status_live.ex:148`).
- **Nothing runs continuously.** There is no loop, poller, queue, or work-discovery module. Every run is one-shot and externally triggered.
- **The staging Cloud Run job is not in Terraform.** `infra/staging/` declares SCV as two Secret Manager slots and four IAM bindings (`infra/staging/main.tf:46`, `:388`) and nothing more. The job, the Artifact Registry repository, and the service account are created by hand per `docs/operations/scv-staging-qualification.md:16`.
- **"No network by default"** (`docs/scv-planning.md:492`) holds only for Codex, which disables it in `config.toml` (`lib/openagents/scv/executor/codex_app_server.ex:688`). The OpenCode process keeps egress; only its `webfetch` and `websearch` tools are denied, and `Environment` declares `:network_egress` for both environments (`lib/openagents/scv/environment.ex:27`).

---

## 7. Open questions

These could not be settled from the code and should not be assumed either way.

1. **Whether `CodexRuns.start/5` has ever run outside tests.** The path is complete and tested, but with no production caller there is no evidence of it running against a real Codex account.
2. **What launches the staging SCV container.** `ops/scv/images/` builds the image and `infra/staging/main.tf` provisions the credential secrets, but this audit found no component that decides to start an SCV container and sets `SCV_OBJECTIVE`. `rel/` contains no SCV reference at all. It appears to be manual.
3. **Whether lane B running on the web node is intentional.** `Environment` gives the `codex-app-server` environment the image name `openagents` (`lib/openagents/scv/environment.ex:40`), which reads as deliberate, but nothing records whether that was a staging convenience or the intended end state.
4. **Whether `Runner` was designed for host placement or only for in-container process shape.** `Runner.Local` explicitly disclaims the scheduling host (`lib/openagents/scv/runner/local.ex:2`), which reads as either "placement lives elsewhere by design" or "placement is not built yet". The distinction changes whether increment 2 extends the seam or repurposes it.
5. **Whether the two lanes are meant to converge.** They share `Run`, `Environment`, `Driver`, and the event schema name, but differ on persistence, host, and permission ceiling. No document records whether lane A is expected to gain durable rows or lane B to gain a container.
6. **Whether machine `tier` is meant to be enforced server-side.** It is snapshotted and trigger-checked for consistency but never branched on in `lib/`. If the controller is the only enforcement point, that is a defensible design; no comment or document says so.
7. **Whether the two durable-worker implementations should converge.** Both `work_jobs` and `scv_runs` carry `owner_node` and `generation`, but the job side resumes interrupted work while the SCV side only reaps expired leases to `uncertain`. Whether that difference is intentional — a delegation can re-attach a session, a dead container genuinely cannot — or accidental duplication is a decision no document in `docs/` currently records.
