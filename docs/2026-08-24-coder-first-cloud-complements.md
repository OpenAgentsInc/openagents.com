# Coder first: the terminal agent and its cloud complements

Date: 2026-08-24

Status: product assessment

The go-to-market wedge is coding. This document makes `openagents coder`
and its web-based cloud complements — the thread UI, cloud computers, and
trace viewing — first-class, and grounds the plan in the teardown corpus,
especially T3 Code, whose ambitions are the closest to ours
(`openagents/docs/teardowns/2026-07-13-t3-code-teardown.md`, the 2026-07-27
projection-consistency architecture doc, the 2026-07-17 full-catalog
synthesis, and the 2026-08-23 Entire and coder-TUI docs). It composes with
`docs/2026-08-24-registry-network-strategy.md` (why the cloud is central)
and `docs/2026-08-24-triage-and-plugin-model-assessment.md` (the plugin
mechanism).

## 1. Summary

- The market has converged on one supervision shape: engine outside the
  renderer, a versioned event seam, worktree-parallel agents, desktop and
  mobile continuity, remote steering. The full-catalog synthesis's verdict
  stands: that shape is table stakes now, and "OpenAgents wins on the trust
  half or not at all."
- T3 Code shipped the supervision half — five wrapped harnesses, an
  event-sourced projection kernel, a full mobile controller — and left the
  authority half unclaimed: no receipts, default-YOLO execution,
  environment-local threads that can never move, best-effort effect
  delivery that can lose committed work.
- OpenAgents' structural position is the unclaimed middle on session
  identity: T3 threads are trapped in one environment, Cursor's continuity
  is their-cloud-only, Amp's transcripts are cloud-canonical. A
  forge-owned thread — durable, addressable at a URL, receipted,
  consent-tiered, and exportable operator-blind — is the thing no
  competitor is structurally able to copy.
- The plan: finish the thread plane with T3's projection protocol and a
  durable effect outbox T3 lacks; ship the web thread UI as a viewer
  first and a steering surface second; make cloud computers a second
  launcher behind the one delegation contract; and render traces from
  receipts, never from Git-branch transcripts.

## 2. The competitive read

Three sources, three conclusions.

**T3 Code** (pinned at `pingdotgg/t3code`, ~531k lines TS) is a
provider-neutral control plane over other vendors' coding agents: one
local server per environment, event-sourced CQRS in SQLite, web, Electron,
and Expo clients over one hand-written RPC contract. What it proves: the
demand for one durable server-owned model consumed by every client, a
worktree-parallel default, and a phone that is a full controller (files,
diffs, Git, PTY, approvals, durable outbox) rather than a status app. What
it refuses to build: any authority story. `DEFAULT_RUNTIME_MODE =
"full-access"` maps to approval policy `never`; there are no execution or
delivery receipts; its "cloud" deliberately cannot execute or store
content — identity, reachability, and push only; and threads bind to one
environment forever.

**Cursor** validated the market for most of the 2025 demand list and then
demonstrated the trust failures to position against: two pricing crises
(usage truth invisible before the bill), an undisclosed base-model
substitution users treated as a broken contract, defaults that evangelize,
and continuity that only works through their cloud. The teardown's
sequencing lesson: mobile and continuity turned out to be the
differentiating floor, not the marketplace.

**Entire** proves demand for "why does this commit exist" trace viewing —
and proves the storage anti-pattern. It writes agent transcripts to shadow
Git branches, default-public on GitHub. Harvest the join shape (a commit
trailer linking SHA to evidence), reject the store: transcripts belong in
the database under visibility policy, and the forge WAL already carries
push receipts.

## 3. The thread plane: adopt T3's kernel, fix its weak half

The Phoenix server already owns the right objects: `threads`,
append-only `thread_events`, grants fenced by generation, THREAD-001. The
T3 projection doc supplies the protocol to finish the plane, and its own
failure analysis supplies the half to do differently.

**Adopt (T3's strong half):**

1. **One forge-owned model for every surface.** The doc's summary of its
   own strongest idea — "one environment-owned model for every client" —
   restated for us: CLI, web, and later mobile all consume the same thread
   projections. No second transcript store anywhere.
2. **The snapshot-to-live handoff.** Attach the live subscriber before
   reading the snapshot; read the snapshot and its sequence in one
   transaction; deliver snapshot, then buffered events, then an explicit
   synchronized marker, then live. Resume with `afterSequence`; overlap is
   resolved by monotonic-sequence dedup — possible duplication instead of
   possible loss. The thread events cursor that already shipped is the
   seed of this; the completion marker and the same-transaction snapshot
   are the parts to add.
3. **Shell/detail projection split.** Sidebar rows (status, latest turn,
   pending-approval count) as a denormalized shell projection so list
   surfaces never load transcripts; token streams must not starve shell
   updates.
4. **Durable admission with fingerprinted receipts.** Client-minted
   command ids recorded before execution make retries and offline outboxes
   honest — with the fix T3 skipped: a payload fingerprint, so a reused id
   with different content is rejected instead of silently answered with
   the first result.
5. **Steer, queue, and interrupt as three explicit verbs**, on the wire
   and in the composer. T3's implicit-steer keyboard seam is the named
   failure; Amp's gesture set and Codex's compare-and-set steer are the
   references.
6. **Client data states.** Connection health and data health are different
   things: `empty / cached / synchronizing / live`, cached state rendered
   during reconnect, session generations fencing stale sockets.

**Fix (T3's weak half):** provider effects in T3 ride a hot in-memory bus
with no durable cursor — a crash between "turn requested" committed and
the provider firing strands the turn forever; the teardown's verdict is
"best-effort live reactor system." The prescription, which Postgres and
OTP make natural for us: a **durable effect outbox committed in the same
transaction as the intent event** (effect id, source sequence, payload
digest, attempts, lease, status), leased workers with deterministic
idempotency keys, durable per-reactor cursors, and event schema versions
with upcasters instead of in-place event mutation. And the doc's deepest
rule, which maps directly onto receipts vocabulary: one sequence number
must never conflate the six milestones — command admitted, event
committed, effect claimed, effect completed, turn quiesced, work verified.
A `thread_events` sequence is a transcript position, not an execution
claim and not a completion claim.

## 4. The web complements, first-class

### 4.1 Thread UI

Every thread gets a URL on openagents.com, viewable live: transcript,
reasoning, tool calls, fleet state, budget. Read-only viewing ships first
— it exercises the whole projection protocol with no authority questions —
then steering (send, steer, queue, interrupt), then approvals from the
web with the same typed decision objects the CLI uses. The attention inbox
(what needs a human: approvals, questions, finished work) is the second
screen. Notifications are never completion authority.

This is the surface T3 cannot ship without ceasing to be local-only and
Cursor cannot ship without opening their cloud: a durable thread you can
open from any device *because the forge owns it*, under consent tiers
*because visibility policy already exists*, and exportable *because the
operator-blind export already ships*.

### 4.2 Trace viewing as the trust surface

The trace viewer renders receipts, not Git transcripts. Three joins make
it work: thread → issue (#10's linkage), commit → thread (an
`OpenAgents-Thread:` commit trailer, harvesting Entire's join shape onto
forge push receipts, so any SHA resolves to its evidence in one lookup),
and thread → plugin runs (digest-carrying `tool.ran` events feeding the
registry's usage counters). Public visibility follows the artifact's
transparency tier; the changelog's words-plus-receipts pattern extends to
threads. This is also where the usage-truth lesson from Cursor lands as
product: requested versus effective model rendered on every turn — #160
(silent model substitution) is not a bug fix, it is the trust surface's
first brick.

### 4.3 Cloud computers

A cloud computer is a second launcher behind the same delegation contract,
never a second work record. The coder TUI port plan's sequencing holds:
task registry, then fleet rendering, then tool renderers, with local
children first (they need no server change) and the sandbox-computer
launcher as the final slice, quota-accounted (the 275 broker shape:
leases, budgets, checkpoints, recoverable commands). The T3 projection
doc's cloud chapter names the two authority modes to keep distinct:
**owner-hosted** (the cloud stores links, grants, and awareness only —
T3 Connect's honest shape) and **managed cloud environment** (the cloud
is the environment authority owning the event log, receipts, and
workspace leases — what T3 never built and our cloud-computer lane is).
Workspace provisioning is fenced durable states, not a script.

The open architecture question the port plan already names must be
answered on the server, not worked around in the CLI: N delegated
children cannot share the account's single chat turn (TURN-001). The
durable answer is the nested-thread ledger — spawn, resume, cancel,
complete as thread-plane operations — which also gives delegation
receipts their home.

### 4.4 Onboarding and import

`npx` is the front door standard (T3's bar), and meeting users inside
their existing tool history is the import lane (Cursor's compiled-in
Claude Code import). For us that is #198 — foreign session resume — with
grok-build's caution made law: an import is a typed adapter with a source
digest and a loss report, never a skill prompt masquerading as lossless
resume, and it never activates foreign credentials or authority. As a
plugin, it is also the first proof of the registry.

## 5. Trust posture: the differentiators to ship early

From the synthesis's refusal list and Cursor's trust drops, the ones that
are cheap now and expensive to retrofit:

1. **Usage and model truth** on every surface: requested versus effective
   model, spend against grant ceilings, no silent substitution (#160).
2. **Fail-closed approvals** with typed decisions; no `/bypass/i`
   options; plugin capability declarations enforced by the sandbox
   (`docs/2026-08-24-triage-and-plugin-model-assessment.md` section 4.4).
3. **Receipts where competitors have none**: turn receipts, push
   receipts, plugin invocation receipts, and — once the outbox exists —
   effect receipts distinct from transcript events.
4. **Portable, exportable threads**: the forge owns the canonical copy,
   the owner can always take it out, and visibility is a dial, not a
   default.
5. **Signed releases with a public trust ledger** — four torn-down
   products ship broken signing; the forge's WAL anchoring work (#151) is
   the same instinct applied to ourselves.
6. **Subagent topology rendered, not hidden** — the synthesis calls the
   full agent tree "the cheapest large differentiator in the catalog";
   the coder's task registry and the web fleet view are the two renderers
   over one canonical graph.

## 6. Sequence

Ordered, composing with the strategy doc's priorities (its items 1–2
are this list's items 1 and 3):

1. **Thread persistence and resume in the CLI** — the client writes
   `turn.user`, `turn.reasoning`, `tool.ran`, `turn.assistant`; `--resume`
   replays through the cursor. (Unblock monorepo #19 first.)
2. **Web thread viewer** — read-only thread pages over the same
   projections, with the snapshot-to-live protocol and shell/detail
   split. Fixes #164's class of gap (reasoning and tools visible) on the
   web at the same time.
3. **Plugin contract v1 and pilot** — per the plugin assessment; runs
   land as receipted thread events feeding the trace viewer and registry.
4. **Durable effect outbox and the six milestones** — the thread plane's
   execution half, prerequisite for honest delegation receipts.
5. **Web steering and approvals** — the composer verbs (send, steer,
   queue, interrupt) and approval decisions from the browser.
6. **Nested-thread ledger** — server-side spawn/resume/cancel/complete;
   delegation receipts become real.
7. **Cloud computer launcher** — the port plan's final slice behind the
   delegation contract, quota-brokered, with the owner-hosted versus
   managed-environment authority split explicit.
8. **Trace viewer and commit-trailer join** — receipts rendered publicly
   under tiers; any SHA resolves to its thread.
9. **Mobile controller** — last, on the same projections and outbox
   pattern; T3's mobile teardown is the reference for breadth, our
   authority model for the difference.

## 7. Relation to other documents

- `docs/2026-08-24-registry-network-strategy.md` — why the centralized
  cloud and the registry are the strategic center this product plan feeds.
- `docs/2026-08-24-triage-and-plugin-model-assessment.md` — the plugin
  mechanism, the owned WASM host, and the 2026-08-24 backlog triage.
- `docs/2026-08-23-openagents-coder-cli-spec.md` and
  `docs/2026-08-24-coder-account-integration-audit.md` — the coder's
  architecture and the account-integration gaps this plan sequences.
- `openagents/docs/teardowns/2026-08-23-openagents-coder-tui-agent-fleet-port-plan.md`
  — the CLI-side fleet plan this document adopts and extends server-side.
