# Backlog triage and the plugin model

Date: 2026-08-24

Status: initial assessment

This document records two things done together on 2026-08-24: a triage pass
over every open issue in `OpenAgentsInc/openagents.com` and
`OpenAgentsInc/openagents`, and an initial assessment of the plugin model —
how the coder loads capability it was not born with, how Rust code gets used
from the TypeScript CLI without a rewrite, and when a capability enters the
model's context. Sources: the open issue set as of this morning, episode
transcripts 270–275 plus the 2024 plugin-economy arc (episodes 048–102, 165),
`docs/2026-08-23-openagents-coder-cli-spec.md`,
`docs/2026-08-23-thread-primitive-audit.md`,
`docs/2026-08-24-coder-account-integration-audit.md`,
`docs/2026-08-23-agent-tools-zero-base.md`, and the Omega-era plugin tool
specification (`openagents/docs/omega-agent/2026-07-27-plugin-tool-spec.md`).

## 1. Summary

- **Triage.** 17 issues on `openagents.com` closed as not planned: the
  economy and payments cluster, the future fleet-and-verification governance
  program, and the Ox Alpha stress cluster. One monorepo issue closed as
  completed (#13, the named CLI command families, which shipped). The kept
  backlog is now dominated by the current push: coder thread persistence,
  forge integrity, and near-term product.
- **Rust from TypeScript: yes, and as WASM.** Where a tool already exists as
  a well-formed Rust crate (the #198 foreign-session scanners are the model
  case), compile it to a sandboxed WASM plugin rather than reimplementing it
  in TypeScript or binding it natively. The sandbox is not overhead; it is
  the product. It makes the approval ladder enforceable, the artifact
  portable and digest-addressable, and the plugin the future marketplace
  unit.
- **Loading discipline.** A plugin is installed, indexed, and dormant by
  default. Discovery is semantic (an embedding match over typed manifests,
  never keyword routing); invocation is by exact name from the installed
  catalog; nothing enters the standing system prompt. This is the zero-base
  tool lesson and the Blueprint selection law applied to plugins.
- **Payments stay deferred.** Per-use pricing, usage royalties, and
  settlement are reserved fields in the manifest, not build targets. The
  transcript record itself gives us usage counters for free the day
  settlement resumes.

## 2. Triage record

### 2.1 Closed as not planned on `openagents.com`

The current push is the coder thread and persistence model and the plugin
model. Episodes 270–275 also defer payments explicitly ("It's free. For
now… We'll do open source ones for free as long as we can", episode 274).
Each close carries a comment pointing back to this document.

| Cluster | Issues | Reason |
| --- | --- | --- |
| Economy and payments | #78 (sats bounties), #83 (outcomes per kWh), #84 (trace licensing), #90 (skill registry with usage counters), #91 (revenue share for paid skills) | The payments lane is deferred. The non-economic half of #90 — a typed, digest-pinned registry of capabilities — is carried forward by section 4 of this document and will produce its own issues. |
| Fleet and verification governance | #67 (coverage manifests), #68 (UX behavior contracts), #69 (receipts on issue timelines), #71 (release notes from receipts), #72 (QA fleet), #74 (between-turn guidance), #75 (FastFollow backlog refill) | A future program layered on receipts and fleets that do not exist yet. #10 remains open as the umbrella for issue-to-receipt linkage. |
| Executor standardization | #73 (ACP as the executor contract) | Deferred as written, but the boundary question returns inside the plugin model (section 4.5). |
| Ox Alpha stress program | #41 (parallel orchestrator), #42 (aim agents at backlog), #45 (findings), #56 (provider overflow routing) | The free-window stress program is not the current push. Delegation-driven backlog work continues as `OpenAgentsInc/openagents#22`. |

### 2.2 Closed as completed

| Issue | Evidence |
| --- | --- |
| `openagents#13` (named issue and project CLI commands) | Shipped on monorepo `main` (`b93309390b`) and live in the published CLI; verified against production during this triage. |

### 2.3 Kept open, by lane

- **Coder and threads:** `openagents.com` #132 (coder epic), #164 (thread
  turns show no reasoning, no tools), #160 (silent model substitution),
  #198 (foreign session resume — the plugin pilot, section 5);
  `openagents` #20 (scoped push credential), #22 (backlog delegation).
- **Forge integrity:** #151, #166, #178–#193, #197, #195. These are
  correctness and exit-honesty issues; deferring them would let the forge
  drift from its own claims.
- **Work system and product:** #2, #9, #10, #23, #77, #115, #141.
- **Cloud computer platform:** `openagents.com` #37–#38 and `openagents`
  #7–#11 stay open. This is a deliberate non-decision: the lane is two days
  old and feeds delegation, but it is not the current push. If it should
  pause too, close the project in one pass.

### 2.4 Flag

`openagents#19` reports that the pre-push ACP conformance gate fails closed
on clean `origin/main`, so nothing can be pushed to monorepo `main`. Every
coder and plugin change lands in that repository. This is the most urgent
open issue in either tracker.

## 3. Where the current push stands

The server half of thread persistence is done; the client half is not.

**Done (server):** the `threads` table with budget, generation fence, and
status; append-only `thread_events` as the authoritative transcript
(THREAD-001: a grant names a thread or a conversation, never both);
transcript routes `GET`/`POST /api/v3/threads/{id}/events` with an `:after`
cursor; the payload ceiling lifted so reasoning is recorded whole
(`cb4d5cc`). The decided event vocabulary is `turn.user`, `turn.reasoning`,
`tool.ran` (call and bounded result as one event), and `turn.assistant`.

**Open (client and joins):**

1. The CLI never posts to `thread_events`. `coder-thread.ts` opens and
   revokes threads but keeps its transcript in memory; on exit it is gone.
   The server copy is decided to be the only copy — the earlier local-JSONL
   plan is superseded.
2. No `--resume`. The Codex-style shape is decided (`--resume` picker
   filtered to the repository, `--resume <id>`, `--resume --last`) and
   unbuilt.
3. Thread spend does not reach the leaderboard (missing third union arm over
   `Inference.Grant.usage`), and the memory planes still hang off the
   conversation, not threads.

Plugin work lands inside this model, not beside it: a plugin run is a
`tool.ran` event on the thread transcript, carrying the plugin's digest.
That single decision is what lets usage counters, receipts, and eventual
settlement come later without a second record.

## 4. The plugin model

### 4.1 What history already settled

This is the second time OpenAgents builds this. The 2024 arc (episodes
048–102) ran a complete plugin economy — Extism-hosted WASM plugins,
per-use sats pricing set by the author, allowed-hosts declarations, a
community Nostr registry proposal (episode 066), and an agent store with
daily Bitcoin revenue sharing (episode 092). It failed on demand, not
supply: "we didn't really have the use case for which people were willing
to actually pay" (episode 165). The Omega plugin tool specification
(2026-07-27) already distilled the surviving laws, and this assessment
adopts them rather than restating them:

1. Plugins are WASM in a sandbox, not code in the host process.
2. A plugin declares typed input and output schemas, and the boundary
   validates both (the DSE/DSPy signature lineage).
3. An artifact is immutable and content-addressed; a stable digest names
   exactly what ran.
4. Plugin runs are decision evidence, not write authority.
5. No keyword routing: invocation is an exact name from the installed
   catalog.
6. A better version is a candidate until an explicit install pins it.

What is new since 2024: the coder exists, threads give every run a durable
transcript, and the forge gives plugins a home with receipts. The buyer
this time is the coder itself.

### 4.2 Rust from TypeScript: WASM, not bindings

Three ways to reach a Rust crate from the Effect TS CLI:

| Path | Verdict | Why |
| --- | --- | --- |
| WASM plugin | **Adopt** | One artifact for every platform and every host (Node CLI, BEAM server, browser). Sandboxed by construction: filesystem access is an explicit read-only mount, network access is an explicit host allowlist, so a plugin's declared capabilities are enforced, not trusted. Dynamically loadable, digest-addressable, and identical to the future marketplace unit. |
| napi-rs native addon | Reject for plugins | In-process with full ambient authority, per-platform prebuilds, no dynamic-load story, nothing enforceable to price or approve. Acceptable someday for a first-party hot path; none exists today. |
| Rust sidecar process | Reject | A second binary to distribute and supervise per platform; the coder CLI deliberately ships as one npm install. |

The precedent inside the codebase points the same way: the coder CLI spec
records that the `probe` runtime already ships a checked-in synchronous-ABI
WASM build precisely so consuming it is an `npm install`.

**Runtime recommendation: start with Extism.** Extism has first-class SDKs
for both hosts we own today — Node for the CLI and Elixir for the Phoenix
server — plus PDKs for authoring plugins from Rust with minimal ceremony,
and it supports WASI with `allowed_paths` (read-only mounts) and
`allowed_hosts`, which are exactly the 2024 upload form's fields and exactly
the #198 security constraints. The WebAssembly component model with WIT is
the better long-term ABI (real typed interfaces instead of bytes-plus-schema
convention), but its Elixir host story is still experimental. Track it;
do not wait for it. The typed boundary lives in the manifest schema either
way, so the ABI can migrate under a stable contract.

### 4.3 The manifest

Every plugin carries a manifest, and the manifest is the unit the registry
indexes, the selector embeds, and the approval ladder reads:

- **Identity:** name, semantic version, content digest of the WASM
  artifact, author.
- **Interface:** typed input and output schemas (JSON Schema on the wire,
  Effect Schema in the CLI), validated on both sides of every call.
- **Capabilities:** requested read-only path mounts, requested host
  allowlist, memory and time bounds. Absence means denial.
- **Discovery:** a description written for semantic matching — what it
  does, when to use it, and when not to (the zero-base re-admission
  criteria applied to third parties).
- **Surfaces:** slash commands the plugin contributes (`/resume`), and the
  tools it materializes when loaded.
- **Reserved, not implemented:** price per use in sats, license terms.
  These fields exist so the economy lane can resume without a schema
  migration, and stay empty until it does.

### 4.4 When a plugin enters context

The zero-base audit measured the cost of ignoring this: 57 percent of a
selection's tool-definition bytes went to tools that could not run. The
plugin model must not rebuild that. Three tiers:

1. **Core, always loaded.** The coder's built-in tools (today: `shell`,
   `delegate`, `skill`, `openagents`) plus one `capability` discovery tool.
   The standing prompt grows by one tool, ever.
2. **Installed, dormant.** An installed plugin is digest-pinned in a local
   catalog and indexed for semantic search. It costs zero prompt bytes. Its
   slash commands work immediately (a slash command is user-invoked and
   needs no model awareness). The model reaches it only through the
   `capability` tool: the request is embedded and matched against manifest
   descriptions — the workspace's semantic-routing invariant, and the same
   mechanism episode 102 shipped in 2024 ("based on a combination of chat
   context, plugin metadata, and input descriptions"). The tool returns
   candidate names; the model then invokes by exact name, satisfying the
   no-keyword-routing law. On selection, the plugin's tool definitions
   materialize for the remainder of the session only.
3. **Session-loaded.** The user can force a plugin in (`/plugin load`), and
   an agent proposal to load one rides the existing approval ladder.

The ladder gets sharper, not looser, because the sandbox makes declarations
enforceable: a plugin whose manifest requests no mounts and no hosts is
pure computation and can auto-run; read-only mounts inside the workspace or
the declared foreign roots are ask-once; any host access or anything
writable is ask-every-time. Approval attaches to the digest, so a version
bump re-asks.

This resolves the tension in the prompt that motivated this assessment: the
foreign-session-resume capability is *always there* (installed, indexed,
`/resume` works) and *never loaded* (zero standing prompt cost) until the
user asks for something it matches.

### 4.5 Relationship to skills, ACP, and the typed-program lineage

- **Skills versus plugins.** A skill (a `SKILL.md` under `.agents/skills/`)
  is instructions — it changes what the model knows. A plugin is
  capability — it changes what the model can do, deterministically, in a
  sandbox, with a receipt. The existing skill loader already proves the
  discovery pattern (catalog of names and descriptions, bodies on demand);
  the plugin catalog generalizes it. Keep the words separate per the
  taxonomy.
- **ACP.** Closing #73 defers ACP standardization across Work and SCV, but
  the boundary question it asked comes back here in a smaller form: the
  plugin ABI is the *function* contract (typed call, one result, a receipt)
  and ACP remains the *agent* contract (a session, turns, permission
  requests). `delegate` hands work to an agent; `plugin` calls a function.
  Do not blur them.
- **DSPy, DSE, Blueprint.** The manifest's typed interface is a signature
  in the DSE sense, and the Blueprint laws above are adopted wholesale.
  When optimization returns, the discovery layer is the natural place for
  it — which manifests get selected for which requests is a tunable,
  eval-scored policy — under the standing law that an optimizer output is a
  candidate, never a deployment.
- **Micropayments.** Deferred with the rest of the economy lane, by design
  rather than by omission: because every plugin run is a `tool.ran` thread
  event carrying a digest, usage attribution is already durable. Settlement
  (the closed #90/#91 territory) becomes a projection over records that
  will already exist, and the open-registry idea (episode 066's
  Nostr-signed listings) remains the preferred distribution shape when it
  resumes.

## 5. Pilot: foreign session resume as the first plugin

Issue #198 is the model case, and its body already states the preference
this assessment confirms: use the Rust crates. The `grok-build`
foreign-session scanners (bounded, read-only, `ApprovedRoot`-sandboxed
readers of `~/.claude` JSONL, `~/.codex` SQLite and zstd rollouts, and
Cursor state) are exactly the shape of code that should never be
reimplemented in TypeScript: parsing untrusted local state with bounded
reads is where Rust earns its keep and rewrites breed defects.

As a plugin: manifest requests read-only mounts of the three foreign roots
and nothing else — no hosts, no writes. Under the ladder that makes it
ask-once. It contributes `/resume` (a picker over recent sessions matching
the working directory) and a `foreign_sessions` tool the capability
selector surfaces when the user says "continue my Claude session." The
resumed conversation lands in a new thread whose transcript records the
import as events.

**Known risk to spike first:** SQLite and zstd inside `wasm32-wasip1`.
Both compile, but SQLite's VFS and file locking under WASI have friction.
Fallback that preserves the architecture: the host reads the raw bytes
through the same declared mounts and passes them in; the plugin keeps all
parsing. Decide in a one-day spike before committing the interface.

Second pilot candidate, deliberately trivial: wrap one pure function (for
example, the ATIF redaction pass) to prove the manifest, digest pinning,
and transcript receipt path with no filesystem story at all — the walking
skeleton before the real organ.

## 6. Proposed next issues

In order. The first three are the current push; the rest follow.

1. **Coder writes its transcript.** Post `thread_events` from the CLI turn
   loop (`turn.user`, `turn.reasoning`, `tool.ran`, `turn.assistant`);
   server copy is the only copy. Closes the client half of persistence.
2. **`openagents coder --resume`.** Picker over the account's threads
   filtered to the repository, plus `--last` and explicit id, replaying the
   transcript through the cursor.
3. **Fix the release gate freshness failure** (`openagents#19`) so 1 and 2
   can land.
4. **Plugin walking skeleton.** Extism host in the CLI, manifest schema,
   digest-pinned local catalog, one pure-function plugin, runs recorded as
   `tool.ran` events.
5. **Capability discovery tool.** The one standing `capability` tool with
   embedding-based manifest matching and exact-name invocation; approval
   ladder keyed to declared capabilities and digest.
6. **Foreign session resume as a plugin** (#198), starting with the
   SQLite-under-WASI spike.
7. **Leaderboard union arm** for thread grant usage, so coder work counts.

## 7. What this assessment does not decide

- Whether the cloud computer lane pauses with the rest of the deferred
  program (section 2.3) — owner call.
- The remote registry and its trust model (signed listings, review) — not
  needed until a plugin exists that anyone else wants.
- Component-model migration timing — revisit when the Elixir host story
  matures.
- Anything priced in sats.
