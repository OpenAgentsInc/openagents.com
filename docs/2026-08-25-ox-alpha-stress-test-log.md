# Ox Alpha Stress Test & High-Throughput Token Benchmark Log

Date: 2026-08-25
Status: In Progress
Author: OpenAgents Coder & Christopher David

## 1. Objectives & Context

As discussed in Episode 275 ("Parallelizing Ox Alpha Stress Testing"), the objective is to determine the maximum sustainable tokens per second (TPS) and parallel capacity of `stealth/ox-alpha` across available providers (OpenRouter, OpenCode Zen, Nous Portal, Venice) without degrading into rate limit errors (`429`), quota exhaustion, or merge conflicts.

Initial findings are collected and logged here before running live backlog burns on video.

---

## 2. Benchmark & Concurrency Ladder Run Receipts

### Baseline Probe (Concurrency = 2)
- **Model / Lane:** `ox-alpha` (via OpenAgents inference proxy -> OpenRouter `stealth/ox-alpha`)
- **Task:** 300-word architectural analysis of swarm scaling & token economics
- **Result:**
  - 2 of 2 workers completed cleanly.
  - Per-worker generation latency: ~18-22s.
  - Estimated output generation: ~800 tokens/worker (including hidden reasoning).
  - Effective aggregate generation rate: ~75–90 tokens/sec across 2 lanes.
  - HTTP status: 200 OK (no 429s).

### Concurrency Ladder Step 1 (Concurrency = 4)
- **Model / Lane:** `ox-alpha`
- **Task:** 250-word scaling analysis on generation ceilings, prompt caching, and throughput bottlenecks
- **Result:**
  - 4 of 4 workers completed concurrently without dropouts.
  - System load: 4.47 (16 idle CPU threads available, memory clean).
  - Effective aggregate generation rate: ~160–190 tokens/sec across 4 lanes.
  - Error rate: 0.0% (0 / 4 failed).

---

## 3. Key Lessons Learned & Bottleneck Hierarchy

1. **Output Generation vs. TPM/Context Prefill:**
   - Single-agent output decode rate sits comfortably around 20–30 TPS.
   - The primary bottleneck in agentic loops is **input token volume and TPM ceilings**, not output decode speed. A 50k-token repository context re-sent across 4 agents consumes 200k input tokens per step, rapidly hitting Free-tier TPM ceilings (e.g., Nous Free tier observed at 500k TPM = max 2–3 active heavy workers).

2. **Prompt Caching is Mandatory for Fan-Out:**
   - 80–90% of prefix data (system prompts, tool definitions, file headers) is static across sibling workers.
   - Seeding workers with shared context prefixes ensures cache hits, minimizing time-to-first-token (TTFT) and saving API quota.

3. **Rate Limits & Provider Topologies:**
   - **OpenRouter:** Free model pool has a documented 20 RPM limit, plus daily request quotas (50/day before $10 lifetime credit; 1,000/day after).
   - **Nous Portal:** Observed 50 RPM / 500K TPM on Free plan; paid tiers scale up to 1,600 RPM / 16M TPM.
   - **OpenCode Zen (`x-preview-f-free`):** Free Ox Alpha endpoint can be subject to upstream availability (`503` under load).

4. **Next Step for Cloud Computers / Box Infrastructure:**
   - To scale past 8 concurrent agents safely on complex repositories, tasks must be isolated to separate git worktrees or cloud sandbox containers (Box / Cloud Computer leases) to avoid workspace lock contention and serial merge bottlenecks.

---

## 4. Next Ladder Steps Planned

- [x] Concurrency 2: Verified (~80 TPS)
- [x] Concurrency 4: Verified (~180 TPS)
- [ ] Concurrency 8: Test short burst synthesis across 8 workers
- [ ] Concurrency 15: Maximum planned fan-out test with Box/worktree isolation

## 5. Box / Cloud Computer Fleet Integration Plan

### Architecture & Current Substrate
The backend in `openagents.com` already holds the complete Box runtime and delegation primitives:
1. **Core Client & Fleet (`OpenAgents.Box`, `OpenAgents.Box.Fleet`, `OpenAgents.Box.Fanout`):**
   - Implements bounded multi-box allocation with labels, queues, and cost ceilings (Issue #109).
   - Manages active box caps per conversation (default 2, budgeted grant up to 10/15).
2. **Durable Runs (`OpenAgents.BoxRuns`):**
   - Asynchronously runs OpenCode / Coder commands on remote sandboxes (Issue #107) with resumption and bounded output tailing.
3. **Forge Issue Assignment (`OpenAgents.Forge.Assignments`):**
   - Delivers short-lived, branch-scoped credentials to a box container (Issue #108) so a remote OpenCode harness can clone, implement, run checks, and push a branch.
4. **Unified Delegation Layer (`OpenAgents.Delegations`):**
   - Provides a single seam across local harnesses and remote Box targets (`target_type: "box"`).

### Next Steps for Fan-Out Execution
1. **Bridge Coder Session with Box Fleet Fan-out:**
   - File a dedicated issue in Project 6 to wire `openagents coder` delegation directly to the remote Box fan-out controller (`POST /api/v1/conversations/:id/boxes/fanout` and `POST /api/v1/delegations/dispatch`).
2. **Execute Multi-Box Ox Alpha Run:**
   - Request 4-8 cloud boxes in parallel, dispatching OpenCode with `stealth/ox-alpha` against distinct backlog issues.
   - Collect and compare end-to-end cloud latency, TPS, and receipt delivery against local runs.

### Concurrency Ladder Step 2 (Concurrency = 8)
- **Model / Lane:** `ox-alpha` (8 parallel child coding agents)
- **Task:** Prompt caching optimization and TTFT reduction analysis under multi-tenant load
- **Result:**
  - 8 of 8 children completed concurrently with zero dropouts.
  - Per-child generation: ~750–1,200 tokens (output + reasoning).
  - Effective aggregate generation rate: **~350–410 tokens/sec** across 8 parallel streams.
  - Machine state: Load average 4.75, memory healthy, zero HTTP 429s or rate limit errors.
  - Error rate: 0.0% (0 / 8 failed).

## 6. Cloud Box 2-way fan-out attempt (2026-08-25)

Live qualification of the new `openagents box` CLI (openagents monorepo commit
`6f575f466a`, issue OpenAgentsInc/openagents#58) against production, scoped to
the owner-directed maximum of 2 boxes. No live Box VM was provisioned. The
dispatch path is blocked by production credential and bootstrap configuration,
not by the CLI or the server substrate. This section records the exact
refusals as the current-state evidence for issue #255 acceptance criterion (a).

### Commands and observed behavior

The globally installed `openagents` binary predates the `box` subcommand, so
every invocation ran from monorepo source:
`tsx src/main.ts box ...` in `packages/openagents-cli` (read-only use of the
canonical checkout).

| Invocation | Result |
| --- | --- |
| `openagents box list` (no `--conversation`) | `api_error: Could not find an active conversation for this account.` The CLI resolves the default conversation from `GET /api/v1/user`, but production's `ForgeUserController` does not return a `conversation_id`, and no API route exposes one. |
| `openagents box list --conversation <uuid> --json` | HTTP `401`, request id `GM8i9RIHftp1gmgAAA7B` |
| `openagents box fanout --count 2 --labels ox-alpha-1,ox-alpha-2 --conversation <uuid> --json` | HTTP `401`, request id `GM8i9Tzl5IUatR8AABIx` |
| `GET /api/v1/conversations/<uuid>/boxes` (raw, via `openagents api`) | `401 {"error":{"code":"invalid_api_token"}}`, request id `GM8i9ohpRAEvOXYAAA8x` |
| `POST /api/v1/conversations/<uuid>/boxes/fanout` body `{"count":2,"labels":["ox-alpha-1","ox-alpha-2"]}` (raw) | `401 {"error":{"code":"invalid_api_token"}}`, request id `GM8i9-XmhZyTFNYAAAOC` |

The `401` is deterministic, not transient: every `/api/v1/conversations/:id/boxes*`
route sits behind the `box_control_api` pipeline
(`OpenAgentsWeb.Plugs.AssignmentControlAuth`, `scope: "box:control"`), and the
CLI session token carries only the sign-in defaults
(`OpenAgents.ApiTokens.default_scopes/0` = `["chat:account", "forge:write"]`).
A `box:control` token exists in `allowed_scopes` but is only mintable from the
browser-session `POST /api/tokens` route, not from the CLI session. The scope
gate refuses before conversation lookup, so the placeholder conversation UUID
in the requests above does not change the observed behavior.

### What this blocks and what it does not

Because authentication refuses before admission, none of the downstream
machinery was exercised live: no fanout plan row, no VM provisioning (so the
production `BOX_API_KEY` provider credential also remains unverified), no
isolated clone, no Ox Alpha turn on a box, and no server-side run output or
receipts. Tokens generated on boxes: 0. Wall time to refusal: sub-second per
request.

The substrate below the auth gate is verified by test evidence on the same
tree the site runs:

- Server: 80 tests, 0 failures across `box_test.exs`, `box_fanout_test.exs`,
  `box_fleet_test.exs`, `box_runs_test.exs`, `box_client_runs_test.exs`,
  `box_reconciler_test.exs`, and the `BoxController`, `BoxFanoutController`,
  and `BoxRunController` controller tests — covering the 2-box default cap
  admission, queueing beyond the cap, durable run lifecycle, bounded output,
  and cancellation.
- CLI: `test/box-command.test.ts` passes (4 tests) against the same
  request/response contract the live calls used.

### Acceptance criteria status for issue #255

1. Multi-box dispatch provisions/queues up to the cap: demonstrated at the
   contract level only (fanout controller tests admit up to the default cap of
   2 and queue the rest). Live dispatch refused with `401` as recorded above.
2. Isolated repo clones and asynchronous Ox Alpha turns per box: not
   demonstrated live; covered by `OpenAgents.Forge.Assignments` and
   `OpenAgents.BoxRuns` tests only.
3. Output logs, tokens, and push receipts on the server: not demonstrated
   live; run output and receipt persistence covered by tests only.

### Blockers (tracked in OpenAgentsInc/openagents#58 — do not duplicate)

1. `box:control` scope grant for CLI sessions (`openagents auth login` or
   `Agents.grant_box_control`).
2. Conversation discovery/bootstrap when `--conversation` is omitted
   (`GET /api/v1/user` returns no `conversation_id`).
3. `BOX_API_KEY` provider credential configuration in production, verifiable
   only after 1 and 2.

## 7. Cloud Box 2-way fan-out: live results (2026-08-25, after unblock)

The three blockers in section 6 were cleared the same day: the `BOX_API_KEY`
provider credential was set in production, a `box:control`-scoped API token
was minted from **Settings → API tokens**, and the owner's conversation UUID
was supplied directly. The CLI consumed the scoped token through its
`OPENAGENTS_TOKEN` environment override; all commands below are real
`openagents box` invocations run from monorepo source at `6f575f466a`.

### Fan-out and provisioning (criterion a: demonstrated live)

`openagents box fanout --count 2 --labels ox-alpha-1,ox-alpha-2
--conversation <uuid> --json` returned plan
`f6e8b333-0508-4615-825d-52df9dd2b59b`: 2 requested, 2 admitted, 0 queued,
`budgeted: false`, `effective_limits.conversation_active_limit: 2`. Both VMs
reached `idle` / setup `done` within ~10 seconds of the request. The plan is
durable: `GET .../boxes/fanout/f6e8b333-...` re-serves it after the boxes
stopped.

| Label | Box ID | Provider host | Admitted at |
| --- | --- | --- | --- |
| ox-alpha-1 | `bx_8af5ehkj` | `box-node-67cd03d983815f97` | 19:37:03Z |
| ox-alpha-2 | `bx_xsv6tr39` | `agents-server-one-1787686473-313447` | 19:37:08Z |

Distinct hostnames confirm the two sandboxes landed on different provider
hosts. Box images carry git 2.43, node v24.19, npm, bun, and codex on
Ubuntu (4 vCPU, 8 GB); `opencode` is not installed.

### Isolated clones and asynchronous runs (criterion b: partially demonstrated)

Each box ran a durable background run (`openagents box run <box_id>
--conversation <uuid> '<script>'`) that cloned the repository from the forge
(`git clone --depth 1 https://openagents.com/OpenAgentsInc/openagents.com.git`)
into its own sandbox and reported timings and the head revision. The two runs
executed concurrently (19:43:09.3–14.5Z and 19:43:10.3–16.2Z) and both
resolved `HEAD` to production main `40dbd832`, proving isolated per-box clones
served by the forge.

| Run ID | Box | State | Exit | Wall | Clone |
| --- | --- | --- | --- | --- | --- |
| `0c0f2de0-ce47-4377-a9fb-f0743d95d9d6` | bx_8af5ehkj | completed | 0 | 5 s | 5 s |
| `202d391c-77d6-4ba1-91fd-8b8063bc5db8` | bx_xsv6tr39 | completed | 0 | 6 s | 6 s |

Not demonstrated: an actual Ox Alpha model turn on a box. `opencode` is not in
the box image and no inference-credential lane exists for boxes yet; placing
the account token inside a run command would persist a secret in the durable
run record, so it was not attempted. Tokens generated on boxes: 0.

### Output logs and receipts (criterion c: output demonstrated; push receipts blocked)

Run output is durable server-side:
`GET .../boxes/:box_id/runs/:run_id/output` returns the full log (`box_host`,
timings, `head_revision`) with offsets after run completion, and `box runs
list` / `runs view` re-serve every run record, including the failed attempts
below.

Push receipts could not be exercised. The credentialed lane —
`POST .../boxes/:box_id/assignments` (`OpenAgents.Forge.Assignments`), which
injects a branch-scoped forge credential so the box can push — failed
deterministically on dispatch, twice per box (initial + one retry):

| Assignment | Branch | Run | Failure |
| --- | --- | --- | --- |
| `9c328eca` | `box/ox-alpha-1-issue-255` | `78bf8a79` | `box_response_invalid` |
| `1879b291` | `box/ox-alpha-2-issue-188` | `686c33be` | `box_response_invalid` |
| `e35d1c88` (retry) | `box/ox-alpha-1-issue-255` | `4c91167c` | `box_response_invalid` |
| `40392ea6` (retry) | `box/ox-alpha-2-issue-188` | `fc347327` | `box_response_invalid` |

Evidence points at the provider seam: the identical script dispatched without
a credential completes normally, but the credentialed dispatch — the only
variant that adds an `env` field (`OPENAGENTS_FORGE_TOKEN`) to the provider
`/commands` request and a credential-setup preamble to the wrapper — comes
back without a parseable PID (`Box.Client.dispatch_pid/1` refuses), and box
forensics show the run root directory was never created, so the wrapper never
executed. The likely cause is the provider command API not honoring the `env`
parameter. Follow-up belongs with openagents#58 / a provider-API check, not
with the fanout substrate.

One CLI defect surfaced: `openagents box runs output` prints an empty string
because `BoxClient.runOutput` reads the response's `output` key as text while
the server returns a nested object (`{"output": {"output": ...}}`). The raw
route returns the log correctly.

### Cleanup

Both boxes were stopped (`openagents box stop`), observed `archiving` with
slots released. Peak concurrent boxes: 2 of the 2-box cap; `--budgeted` never
used.

### Acceptance criteria after the live run

1. Multi-box dispatch provisions/queues up to the cap: **demonstrated live**
   (2 requested, 2 admitted, 0 queued, cap honored, durable plan).
2. Isolated repo clones and asynchronous execution per box: **demonstrated
   live** for clones and concurrent durable runs; **Ox Alpha model turns
   remain undemonstrated** (no `opencode`/inference lane in the box image).
3. Output logs, tokens, and push receipts on the server: **output logs
   demonstrated live**; tokens not applicable (no model turn); **push
   receipts blocked** by the credentialed-dispatch failure above.

## 8. Server-side Box fixes and live verification (2026-08-25)

Three defects named in §7 and in openagents#58 were fixed on the server. Boxes
`bx_732ts8jg` and `bx_se9xfq7q` on conversation `3dd6d813` carried the
verification; both were stopped afterwards, peak concurrency 2.

### Setup script: configuration first, pinned artifact, PATH the run sees

`OpenAgents.Box.setup_script/0` piped `https://opencode.ai/install` into bash.
That installer resolves its version through the unauthenticated GitHub API,
which answers 403 for the provider's shared egress IP, and the whole script
runs under `set -euo pipefail`, so one rate-limited lookup cost the box both
the binary and the `opencode.json` write that followed it.

The script now writes the configuration first, fetches a pinned release
tarball directly (`releases/download/v1.18.23/opencode-<target>.tar.gz`, arch
resolved from `uname -m`), retries a refused fetch twice before failing loudly,
and symlinks the binary into `$HOME/.local/bin` — already on the PATH a
non-interactive `sh -c` run gets, which the installer's
`$HOME/.opencode/bin` plus a shell-rc `export PATH` line never was.

Verified on `bx_se9xfq7q`: with `~/.opencode`, `~/.local/bin/opencode`, and
`~/.config/opencode` deleted, the rendered script exits 0 and
`sh -c 'command -v opencode && opencode --version'` answers
`/home/user/.local/bin/opencode` and `1.18.23`. An `opencode run` in that state
returns `> build · stealth/ox-alpha` and the model's reply, with
`OPENROUTER_API_KEY` supplied by the box environment as before.

Verified on `bx_732ts8jg`: the same script pointed at an unreachable release
tag retries twice, exits 1 — so `setup_status` still reports `failed` honestly
— and leaves `opencode.json` intact with no binary.

### Conversation bootstrap a box token can reach

`GET /api/v1/conversation` under the `box_control_api` pipeline answers
`conversation_id` for the calling account, creating the conversation when the
account has none. Confirmed against production that a `box:control`-only token
is refused `401` on `GET /api/v1/user`, which is why a route of its own exists
rather than a field added there.

The field is deliberately not on `/api/v1/user`. That response is
GitHub-shaped, and API-001 holds every OpenAgents field there to a namespaced
`openagents` object, which is not what `BoxClient.resolveConversationId` reads.
One canonical route carries it at the top level instead. The CLI change that
follows this is a one-line reader retarget in the `openagents` monorepo; the
body shape already matches what the probe expects.

### Credentialed dispatch: the provider command API has no `env`

The provider's published `CommandRequest` schema is `command`, `cwd`,
`timeoutSeconds`, and `detached`. There is no `env`, so
`OpenAgents.Box.Client.dispatch_run/5` sent a field that was accepted with the
request and dropped. The wrapper then read `$OPENAGENTS_FORGE_TOKEN` under
`set -u` and died on the unbound variable before printing a pid — the
`box_response_invalid` of §7. Reproduced exactly on `bx_732ts8jg`: the same
wrapper with the variable unset returns HTTP 2xx, `exit_code` 1, empty stdout,
and `bash: line 12: OPENAGENTS_FORGE_TOKEN: unbound variable`.

`env` on box *create* is a different endpoint and does work, which is how
`OPENROUTER_API_KEY` reaches a box. It is not available here: an assignment
credential is minted per attempt, long after its box exists, and
`PATCH /boxes/{id}` takes only `name`, `ttlSeconds`, and `subdomain`. So the
credential now travels inside the dispatch command, base64 only so a token
cannot break the surrounding shell quoting. The cost is explicit: the
credential is in the provider's request body and in whatever the provider logs
of it. It is not in `box_runs.command`, which holds the caller's script and
never sees this wrapper, and an assignment credential is short-lived and scoped
to one branch of one repository.

A 2xx that carries no pid now logs a bounded operational event — response keys,
exit code, output sizes, and one truncated stderr line with the credential
struck out by exact match — instead of a bare atom.

Verified on `bx_732ts8jg` with a stand-in credential: dispatch returns a
parseable pid, the run root is created, the detached child runs under
`GIT_CONFIG_GLOBAL` pointing at the run's own gitconfig, `git credential fill`
for `https://openagents.com` presents `username=x` and the password, the exit
sentinel is written, and `forge-credential` and `gitconfig` are removed when
the run ends.

A push receipt is still not demonstrated. It needs a real assignment
credential, which `Forge.Assignments.create/1` mints server-side and never
returns to an API caller, so it cannot be exercised until this change is
deployed. Every step before the authenticated git handshake is demonstrated
live above.
