# Plugin harvest targets for the coder

**Date:** 2026-08-25
**Status:** Survey and backlog. Nothing here is committed work until it has an
issue and a Gym delta.
**Method:** direct reading of the reconstructed Grok CLI Rust workspace — the
`grok-build` clone in the workspace's external reference area,
`projects/repos/grok-build`, about 80 crates under `crates/codegen/` —,
the teardown of that codebase in the `openagents` monorepo
(`docs/teardowns/2026-07-15-grok-build-teardown.md`), the plugin model
assessment (`docs/2026-08-24-triage-and-plugin-model-assessment.md`), the
tool zero-base audit (`docs/2026-08-23-agent-tools-zero-base.md`), and the
Harbor Terminal-Bench plan (`docs/2026-08-24-harbor-terminal-bench-plan.md`).

## Why this document exists

The first two working coder plugins — `foreign_sessions` and
`read_conversation`, both live in the capability catalog today — were
harvested from Grok's session lineage: Grok ships `xai-grok-active-sessions`
and `xai-grok-session-search` crates for exactly the discover-and-read work
we rebuilt as sandboxed WASM guests. The harvest worked: one spoken request
in `openagents coder` now discovers, digest-verifies, loads, and runs both
plugins with no improvised shell in the loop.

Grok's workspace holds more of the same shape. This document names the next
targets, ties each to the Terminal-Bench task classes the Gym grades the
coder on, and says what each needs from the plugin host. The Gym rule from
the Harbor plan applies to every entry: a plugin lands with a before-and-after
suite score on the same recipe, and its ATIF-stamped `tool.ran` steps make
the delta attributable to the exact digest. A plugin that moves no score is
questioned.

## What makes a good harvest

The plugin model admits a narrow shape, on purpose:

- **Read-only or pure.** The sandbox grants read-only mounts and nothing
  else. Edits, writes, and process execution stay in the coder's core tools,
  where the permission profile governs them.
- **One-shot and bounded.** One packet in, one packet out, under a time and
  memory bound. Daemons, watchers, and anything that must outlive a call
  (`xai-fsnotify`, background tasks) do not fit until the host grows a
  lifecycle for them.
- **Typed and honest.** Input and output schemas in the manifest, and output
  that names its own truncation the way `read_conversation` reports
  `tail_only` and `dropped_leading_turns`.
- **Worth a catalog line.** The capability tool carries each installed
  plugin's name and first sentence in its standing description, capped at
  twelve. A plugin competes for that space with everything else installed.

Grok links these capabilities into one native process. We deliberately do
not: the WASM boundary is what makes a harvested capability reviewable,
priceable, and safe to auto-approve from a digest-pinned catalog.

## Targets from the Grok workspace

Ordered by expected Gym delta per unit of work.

### 1. `repo_map` — the codebase graph

**Source:** `xai-codebase-graph` (tree-sitter queries, go-to-definition,
go-to-references, full and incremental indexing).

The single largest gap between the coder and the agents it benchmarks
against is orientation speed on an unfamiliar repository. Terminal-Bench
fix-the-bug and implement-the-feature tasks begin with minutes of `ls`,
`grep`, and dead-end file reads. A `repo_map` plugin takes a workspace
mount and returns a bounded structural map: directories that matter, public
symbols per file, definition sites for a named symbol, reference counts.
Tree-sitter compiles to WASM cleanly, which is why this crate is the
highest-confidence port in the list. Start with the two or three grammars
the Gym suites actually hit (Python, TypeScript, Rust) rather than Grok's
full language set.

**Needs from the host:** a workspace mount. Today's manifests declare fixed
home-relative paths (`~/.claude`); this plugin needs the manifest to declare
a mount the host resolves to the session's working directory. That
parameterized mount is the one host change this whole document asks for, and
targets 2, 4, 5, and 6 reuse it.

### 2. `repo_tree` — gitignore-aware listing

**Source:** `xai-grok-tools/src/gitignore.rs`, `xai-file-utils`,
`xai-fuzzy-file-search`.

The first thing every benchmark run does is look around, and the coder does
it today with raw `ls` and `find` — unfiltered, unbounded, and re-sent to
the model every round it stays in context. A `repo_tree` plugin returns a
gitignore-filtered tree with per-entry size and kind, bounded by depth and
entry ceilings, plus a fuzzy name lookup (`"authcontroller"` finds
`auth_controller.ex`) so the model stops spending rounds guessing paths.
Pure listing over the workspace mount; small; probably the best
delta-per-effort in the list.

### 3. `session_search` — search what any agent already learned

**Source:** `xai-grok-session-search` (the other half of the lineage
`foreign_sessions` came from), `xai-sqlite-journal` for Grok's own store.

`read_conversation` reads one session; this searches all of them.
Terminal-Bench aside, this is the memory primitive the fleet keeps
reinventing: "have I — or any agent on this machine — hit this error
before?" Input is a query string and the same source/cwd filters the
scanner takes; output is matching sessions with bounded surrounding
context per hit. Same two mounts the existing pair already declares, so it
ships with no host changes at all. Plain substring and identifier matching
first; ranking can come later without a schema change.

### 4. `git_facts` — structured status, log, and blame

**Source:** `xai-gix-status` (gitoxide status), `xai-hunk-tracker`
(hunk-level change tracking), `xai-fast-worktree` for the read side.

The coder answers "what changed?" by shelling `git` and re-reading prose.
Benchmark tasks that hand the agent a dirty repository — and the coder's own
verify-before-claim discipline — want typed answers: current branch, staged
and unstaged paths with hunk counts, the last N commits touching a path,
who last changed a line. Gitoxide is pure Rust and compiles to WASM;
`.git` is just files under the workspace mount. Read-only by construction —
commits and pushes stay in core, where the push guards live.

### 5. `test_report` — parse the test run the shell just did

**Source:** none — this one is ours, but it earns its place here because
Grok's `tool_taxonomy` treats "run" and "understand the run" as one native
step, and a sandboxed coder cannot. The shell tool runs `pytest`, `cargo
test`, `mix test`, or `jest`; this pure plugin parses the captured output
into typed failures: file, test name, assertion, the relevant traceback
lines. Terminal-Bench grades on making tests pass, and today the model
re-reads the same 300-line dump every round it iterates. A pure text-in,
JSON-out plugin, no mounts at all — the cheapest kind the ABI supports —
and likely the largest single Gym delta on the fix-the-tests task class.

### 6. `patch_check` — validate a diff before claiming it

**Source:** `xai-hunk-tracker`, and Grok's edit-tool normalization
(`xai-grok-tools/src/normalization.rs`).

A pure plugin that takes a unified diff plus the target file's current
content and answers: does this hunk apply, where does it drift, what would
the file look like after. The coder's edit loop occasionally emits patches
that no longer apply after an earlier edit; today that surfaces as a shell
round-trip and a confused retry. Validation as a capability keeps the write
itself in core while making the check free.

### 7. `token_count` — budget arithmetic for context planning

**Source:** `xai-token-estimation`.

Pure computation: text or file-listing in, token estimates per item out.
Long Gym runs die of context exhaustion mid-task; a model that can ask
"which of these five files fits my remaining budget" plans instead of
truncating. Pairs with `xai-compaction-transcript`'s idea — a
`compact_notes` plugin that reduces a long tool transcript to a bounded
structured summary — but token counting alone is an afternoon of work and
immediately measurable.

## Explicitly not harvested

Named so the next reader does not re-derive the refusals:

- **Subagents, background tasks, worktree checkpoints, rewind**
  (`xai-workflow`, `xai-fast-worktree`'s write side, section 9 of the
  teardown): lifecycle features, not one-shot capabilities. The coder's
  delegation and thread lanes own this ground.
- **Web search and fetch:** need host allowlists, which the approval
  posture currently auto-approves nothing for. A capability with network
  reach is a different trust conversation, deliberately deferred.
- **LSP integration** (`ToolKind::Lsp`): a long-lived server per language,
  wrong shape for the sandbox. `repo_map` covers the read-only half of what
  the benchmarks need from it.
- **Media generation, deploy, voice** (`ImageGen`, `DeployApp`,
  `xai-grok-voice`): not coding-agent work; no Gym suite grades them.
- **Grok's plugin marketplace** (`xai-grok-plugin-marketplace`): the
  registry lane already exists here (forge-hosted, issue #206 closed);
  what to harvest is their manifest fields, not their store.

## Sequencing

`repo_tree` and `test_report` first — no host changes, small crates, both
sit directly under the Terminal-Bench task classes the Gym already grades.
The parameterized workspace mount lands with `repo_tree`'s successor
`repo_map`, and `git_facts` follows it on the same mount. `session_search`
can land any time; it needs nothing new. Every landing follows the Gym
rule: same recipe, score before, score after, delta attributed to the
digest.
