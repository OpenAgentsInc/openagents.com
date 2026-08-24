# Coder push handoff

Date: 2026-08-24

Status: handoff. Written when the session that landed the work below paused.
The next agent should read this first, then the three planning documents it
points at.

## 1. Read these first

| Document | What it decides |
| --- | --- |
| `docs/2026-08-24-registry-network-strategy.md` | Why the plugin registry is the network, why the cloud is centralized, why consent is load-bearing. |
| `docs/2026-08-24-coder-first-cloud-complements.md` | The product plan: the coder wedge, the three-lane compute mix, the T3-derived thread-plane protocol, the delivery sequence with issue numbers. |
| `docs/2026-08-24-triage-and-plugin-model-assessment.md` | The plugin contract (packet ABI, manifest, capability tiers) and the 2026-08-24 backlog triage. |
| `docs/2026-08-24-api-v1-rename-audit.md` | The `/api/v3` → `/api/v1` inventory and sequencing. |
| `docs/plugins/...` in the monorepo | `2026-08-24-coder-plugin-demo-shape.md`, the plugin host's own shape notes. |

Boards: [Coder v1](https://openagents.com/OpenAgentsInc/openagents.com/projects/12)
(project 12) and [Plugin registry](https://openagents.com/OpenAgentsInc/openagents.com/projects/13)
(project 13). Both carry cross-repository items; `openagents` numbers in this
document are the monorepo, unprefixed numbers are `openagents.com`.

## 2. What landed

Server (`openagents.com`, through `7b8f939`):

- Thread plane: web viewer at `/threads` and `/threads/{id}` with the
  attach-before-snapshot live protocol (#201); events API returning the
  created event with machine codes and atomic batch append (#208); grant
  re-mint at `POST /api/v3/threads/{id}/grants`; an optional bounded
  `repository` on threads with API filtering (#210); admission and mint
  serialized on the owner row (#195).
- Providers: reasoning as a first-class `ProviderEvent` member and faithful
  tool-call replay through the inference proxy (#164 server half); a typed
  model catalog at `GET /api/v3/models` with loud refusal of unserved or
  mismatched models and effective-model attribution (#199, closing #160's
  defect class) under the new `PROVIDER-002` invariant.
- Integrity: thread grant usage on the leaderboard (#204); issuer-key
  retirement refused when it would unverify signed history (#191); the
  machine pairing vault given its own key under `VAULT-001` (#192); the
  runbook `rebuild/1` correction plus a test that fails when any doc names a
  function that does not exist (#189).

CLI (`openagents` monorepo, through `38625181fc` plus later commits from a
concurrent session):

- The coder writes its transcript to `thread_events` as the turn loop runs
  (#23) and resumes a thread with `--resume` (#24), replaying both the UI
  transcript and the model wire history.
- Reasoning is parsed and rendered, and the client tool loop replays faithful
  `tool_calls` history (#31, completing #164 in code).
- Plugins: a working `/plugin load` path, then the walking skeleton — an
  owned Rust PDK, an engine abstraction, enforced read-only mounts, and
  `packet-v0` ABI pinning (#26, partially done). ATIF exports carry plugin
  lifecycle and per-call provenance (#32).
- `openagents trace` discovers, summarizes, and redacts local traces; upload
  refuses honestly until the server route exists (#14).

## 3. Where to pick up

In order. The first three are the Coder v1 critical path.

1. **Finish #26** (monorepo): both-sides schema validation, the `tool.ran`
   receipt event on plugin runs, `/plugin list` and `/plugin unload`, and
   memory-ceiling enforcement (declared-only until a wasmtime engine sits
   behind the seam).
2. **#206** — the registry on the forge: plugins as repositories with typed
   manifests and digest-pinned releases, a typed index, and the capability
   gap loop that files issues when a search finds nothing.
3. **#217** — `POST /api/v3/traces`, the ingest route `openagents trace
   upload` already names in its refusal.
4. **#212–#216** — the `/api/v1` rename. #212 (rename plus a transparent
   `/api/v3` rewrite plug) wants a solo window: it touches roughly 1,530
   lines across the server and should not race other branches. #215 (the gh
   posture decision) gates #216.
5. **#202, #205, #77** — durable effect outbox, consent tiers, chat-to-issue
   capture. Each had an agent in flight at pause; check for an unmerged
   branch before restarting one (section 5).
6. **#28** (monorepo) — fleet rendering over the task registry. A concurrent
   session was actively building `coder-tasks.ts`; coordinate before touching
   it.
7. **#197** — the load-sensitive flaky tests. Run this alone on a quiet
   machine; its whole method is hammering tests that fail under parallel
   load, so it poisons other agents' runs.

Owner decisions blocking work, not agent work: **#209** (thread lifecycle —
the CLI revokes on clean exit, so resume serves only crashes and other
machines today), **#193** (no encrypted Ecto columns), **#29** (the wallet
rail), **#207** (the settlement proof's treasury spend), **#215** (gh
posture).

## 4. How to work here

- **Push to the forge, never GitHub**: `git push openagents HEAD:main`. Both
  repositories.
- **Use worktrees.** The monorepo checkout is frequently dirty with another
  session's work. Branch from `origin/main` into a worktree, rebase there,
  and push from the worktree if the main checkout is busy. Never stash or
  reset someone else's work.
- **The monorepo's pre-push gate regenerates artifacts.** After adding files,
  run `pnpm run generate:assure-repo` and `pnpm run audit:assure-repo` and
  commit the results, or the push is refused.
- **Server tests**: prefer targeted files. `mix precommit` runs the whole
  suite (about 4,170 tests, three minutes) and is worth it before pushing
  anything that touches the provider or chat lanes.
- **Invariant Discipline**: a change that adds, relaxes, or reinterprets an
  invariant updates `INVARIANTS.md` in the same change, with a test.
- **Owner actions go in `NEEDS_OWNER.md`** at the workspace root, committed
  and pushed — the owner reads it on GitHub, so an uncommitted edit is
  invisible.

## 5. Loose ends at pause

- Five agents were in flight: #205, #202, #77 (`openagents.com`), #12
  (monorepo, operator deployment commands), and the #198 foreign-session
  plugin pilot (monorepo). Their branches, if they exist, are
  `thread-visibility-tiers`, `effect-outbox`, `capture-issue-from-chat`,
  `operator-deploy-commands`, and `foreign-sessions-plugin`, in worktrees
  under the session scratchpad. Check `git branch --list` in both
  repositories before redoing any of that work.
- **#164 and #160 are code-complete on main but stay open** until production
  serves the revision; #187 tracks the gap between `main` and the deployed
  forge. Verify against the live API before closing either.
- The published CLI is 0.3.5 and predates every coder change above. Nothing
  in the coder lane reaches a user until it publishes.
