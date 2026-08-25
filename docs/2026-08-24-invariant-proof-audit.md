# Invariant proof audit: the second pass, at the test files

`docs/2026-08-23-invariant-proof-audit.md` classified every contract in
`INVARIANTS.md` as specific or universal and repaired nineteen proofs that
could not fail for their claims. It also recorded its own limit: most verdicts
"were judged from the mechanism the contract names rather than re-derived. A
second pass over those would be worth doing and is not what this one did."

This document is that second pass. Every contract's cited proof was read at
the file — the test, the script, the migration, and the production module it
claims to cover — and checked against issue #166's mechanical test: name a
violation the proof would not catch. Line numbers refer to the working tree on
2026-08-24.

The first pass asked whether a universal claim's population is closed. This
pass asks a different question about the same proofs: when the claim is
violated, does the named proof actually go red? Five defect classes recur:

1. **Fixture-path assertions.** The test asserts on a fixture, a hand-built
   map, or a JSON file's own fields rather than the production path.
2. **Subset coverage.** The proof examines some members of the claimed
   population — two adapters of four, one extension object of four, one route
   of a class.
3. **Shared-code tautologies.** The expected value is computed by the code
   under test, so a bug moves both sides together and the assertion holds.
4. **Vacuous assertions.** The assertion is true by construction — an element
   ID that exists nowhere, a literal read back from the module that hard-codes
   it, an immutability property every BEAM value has.
5. **Empty-input passes.** An enumeration or scan that matched nothing passes
   as if it had checked everything, with no positive control forcing it to
   find what it should find.

## Result

130 contracts, one verdict each.

| Verdict | Count |
| --- | --- |
| Can fail — the proof goes red when the claim is violated | 61 |
| Partial — the core clause bites, but named clauses have no proof that can | 57 |
| Cannot fail — a load-bearing clause has no proof that can go red | 12 |

One proof is red right now, and that is the mechanism working: see the next
section. The verdicts here are about the cited proofs as they exist; "partial"
is not a defect report against the code, and several "cannot fail" entries
cover code that is currently correct. The finding in each case is that nothing
executable would notice when it stops being correct — which is the exact
condition `INVARIANTS.md` lines 13-25 names as the companion to taxonomy
rule 7.

## The proof that is failing right now

`ADMIN-001`'s enumerating proof, `test/openagents_web/operator_surface_test.exs`,
is statically red at HEAD. Commit `310dac1` ("Open the Gym", an ancestor of
HEAD) added:

- `/gym`, classified `:operator` with scope `gym:read` at
  `lib/openagents_web/route_authority.ex` lines 192-193, absent from the
  declared operator-route table at `test/openagents_web/operator_surface_test.exs`
  lines 33-72;
- `OpenAgentsWeb.GymLive` (lines 21 and 30) and `OpenAgentsWeb.GymRunController`
  (line 46), both calling `OpenAgents.Accounts.admin?/1`, absent from the
  declared authority-module table at lines 76-104.

`ADMIN-001` does not name the Gym anywhere. The proof is doing exactly what
#146 built it to do — a new operator surface fails until the contract is
amended to name it — and the failure reached `main` anyway. That is a process
finding, not a proof finding: the commit's own message reports a scoped test
run, and the section below on the gate shows how a candidate can carry a
`passed` receipt without this file ever running. The fix is two-sided: amend
`ADMIN-001` to name the Gym read surface, and close the gate path that let a
red enumeration land.

## Proofs that cannot fail for a load-bearing clause

Each entry names the claim, the cited proof, the violation the proof cannot
catch, and the smallest change that would let it fail.

### MEMORY-005 — the tests assert the violating behavior

**Claim:** `memory_remember.v1` accepts only a claim directly authorized by
the current user message, a host-recorded confirmation, or a first-party UI
action; "model arguments cannot substitute."

**Reality:** `lib/openagents/tools/memory_remember.ex` lines 130-135 swallow
every `OpenAgents.Memory.Consent` failure and proceed with
`%{kind: "conversation_context"}` — the model's arguments are the write
authority. The cited proof encodes this as correct:
`test/openagents/tools/profile_memory_tools_test.exs` lines 240-262 store a
model-paraphrased claim under `consent_kind == "conversation_context"`, and
lines 292-307 store a claim that **differs from** the exact confirmation on
record ("I prefer concise answers" confirmed, "I prefer detailed answers"
stored) and assert success. The `Consent` unit tests (lines 22-119) prove the
strict module in isolation; no test runs the tool with a fabricated claim and
asserts refusal.

**Smallest change:** delete the `{:error, _} -> %{kind: "conversation_context"}`
fallback so the tool returns the consent error, or amend MEMORY-005 to say
what the code does — a conversation-context write authorized by topical
relevance, not by exact consent. Either way the current sentence and the
current code cannot both stand.

### RELEASE-003 — the cited proof tests dead code

**Claim:** invalid, insecure, or path-bearing origins fail startup.

**Reality:** `OpenAgentsWeb.AllowedOrigins` has no production caller — the
only references in the repository are its own file and its test. Production
origin checking is `config/runtime.exs` line 190 feeding `check_origin` at
line 545, validated by `lib/openagents/runtime_config.ex` lines 823-840.
`test/openagents_web/allowed_origins_test.exs` therefore tests a module you
can delete without changing production behavior, and `ops/ci/release-smoke.sh`
never opens a WebSocket or sends an `Origin` header (lines 99-114 curl
`/health` over plain loopback HTTP), so the "production WebSocket read-back"
in the evidence line has no executable artifact.

**Smallest change:** either route `config/runtime.exs` through
`OpenAgentsWeb.AllowedOrigins.for_production/2` so the tested module is the
production path, or retarget the proof at `OpenAgents.RuntimeConfig`'s origin
validation and delete the dead module.

### VOICE-005 — the disclosure assertion checks an element that exists nowhere

**Claim:** while recording is on, the surface that carries `START VOICE`
states before the microphone opens that calls are recorded; a visible marker
announces capture while running.

**Reality:** `test/openagents_web/live/chat_live_test.exs` line 206 asserts
`refute has_element?(view, "#voice-recording-disclosure")` — an ID that
appears nowhere else in the repository, so the assertion cannot fail under any
change. The positive disclosure is proven only on the memory surface
(`test/openagents_web/controllers/data_controller_test.exs` lines 243-247
against `lib/openagents_web/live/memory_live.ex`), while the surface that
carries `START VOICE` (`lib/openagents_web/live/chat_live.ex` line 2069)
renders no disclosure text. The capture marker at line 2063 is
`visually-hidden` and referenced by no test. The teardown half is also
unclosed: `assets/test/voice_state_test.mjs` lines 55-71 call the teardown
function directly with fakes; nothing proves `destroyed()` or reconnect
actually calls it (`assets/js/voice_controller.js` line 501 is the one call
site).

**Smallest change:** assert the disclosure element that the chat surface
actually renders — which first requires the chat surface to render one — and
delete the impossible-ID refutation.

### MODULE-004 — the proof is a JSON fixture identity check

**Claim:** every capability surface preserves the same authority boundary;
external effects need receipts; oversized catalogs degrade to discovery;
missing executors fail honestly.

**Reality:** `test/openagents/surface_eval_test.exs` is 28 lines. Lines 13-18
assert that the case IDs in `priv/sarah/evals/surfaces/identity-authority.v1.json`
equal a hard-coded list. Three of the four corpus cases — external effect
under read authority, oversized catalog, unavailable executor — declare
expectations that nothing executes. The file never touches
`OpenAgents.Modules.SurfacePolicy`, `OpenAgents.Tools.Registry`, or
`OpenAgents.Tools.Runner` — the three modules the invariant names as
evidence. Renaming a corpus case turns the test red; an external effect
executing under read-only authority does not.

**Smallest change:** drive the three unexecuted corpus cases through
`OpenAgents.Tools.Runner`, or narrow MODULE-004's proof index row to the
surface-vocabulary and revalidation tests in
`test/openagents/modules/router_test.exs` (lines 107-134), which do bite.

### COLLECTIVE-002 — the leak scanner has zero coverage

**Claim:** generalizer output "is scanned again for secrets, contacts,
identifiers, paths, exact source fragments, authority-bearing fields, and
size before storage."

**Reality:** the scanner exists (`lib/openagents/collective/generalizer.ex`
lines 267-299, five reject branches including the four-gram quote detector)
and no test reaches any reject branch — a grep for the rejection reasons
across `test/` returns nothing. The leak assertions in
`test/openagents/collective_generalizer_test.exs` lines 38-48 run against a
payload built from fixed-vocabulary maps that no input text ever flows into,
so they are true by construction.

**Smallest change:** construct a payload carrying a source fragment and
assert `validate_payload/2` rejects it — one test per reject branch.

### IDENTITY-006 — the branch discipline is enforced but never tested

**Claim:** Git receive-pack authorizes every requested ref update; the
assignment credential can update only its assignment branch, never a default
or protected branch.

**Reality:** nothing in `test/` exercises `authorize_receive_pack/3` or
`allowed_assignment_ref?/3` (`lib/openagents/forge/git_http.ex` lines
303-329). Deleting the default-branch and protected-branch checks fails no
test. `test/openagents/forge/assignment_test.exs` lines 133-147 test pkt-line
parsing — the input to the decision, not the decision. The non-Git-API
refusal in the auth plug is likewise untested, and the "stores only a digest"
assertion at lines 96-97 is tautological (the schema has no plaintext field
to leak).

**Smallest change:** a receive-pack push with an assignment credential
against the default branch, over the same real-HTTP harness
`test/openagents/forge/push_closes_issues_test.exs` already stands up,
asserting refusal — plus one against the assignment branch asserting success.

### DEPLOYPLANE-004 — "the only definition" has no only-ness proof

**Claim:** `OpenAgents.Deployments.Lifecycle` is the only definition of legal
states and transitions, enforced transactionally.

**Reality:** the transitions themselves are well proven
(`test/openagents/deployments/lifecycle_test.exs` lines 12-18 quantify over
the transition table), but nothing enumerates writers of run state — no
compiled-import-table assertion like FLEETPROMOTE-001's, and no PostgreSQL
transition trigger on the runs table (contrast `work_jobs`, whose trigger
`test/openagents/work_job_test.exs` line 232 exercises). The suite itself
demonstrates the bypass: `test/openagents/issues/completion_claims_test.exs`
lines 565-571 force a run to `succeeded` with a raw update.

**Smallest change:** either a transition trigger on the runs table with a
raw-update test, or a dependency-boundary assertion that the lifecycle module
is the sole caller of the state-writing function.

### OBSERVABILITY-001 — the read-back is proven against an empty database

**Claim:** release read-back recomputes zero-tolerance leakage, consent,
provenance, executor-disclosure, and attribution checks from authoritative
records without selecting private content.

**Reality:** `test/openagents/observability_test.exs` line 52 runs
`OpenAgents.Observability.Readback` against a freshly sandboxed database with
no conversation, message, or memory row seeded. The
"contains no private content" refutations (lines 65-66) are vacuous — there
is no content to leak — and the all-planes-healthy loop (lines 59-63) passes
over empty status maps. The blocked case is manufactured with `put_in` rather
than by seeding a violation, so neither direction (detects a real violation;
excludes real content) is exercised. The emit half does bite, but only 2 of 6
refusal branches are tested (lines 22-48).

**Smallest change:** seed one conversation with a known sentinel string and
one zero-tolerance violation, then assert the read-back reports the violation
and the sentinel appears nowhere in the snapshot.

### RELEASE-001 — nothing can fail when migrations stop preceding traffic

**Claim:** the production image runs all pending migrations before starting
the HTTP server.

**Reality:** the evidence line names the Docker `CMD`, but the `CMD` contains
no migration step — the ordering lives in `lib/openagents/application.ex`
lines 22-24 behind `migrate_on_boot`, which
`lib/openagents/runtime_config.ex` lines 267-268 require in staging and
production. No test asserts that requirement (the only `migrate_on_boot` hit
in `test/` is a fixture setting it true), and
`test/openagents_web/controllers/health_controller_test.exs` runs against an
already-migrated test database. The smoke boots the release, but health is
`SELECT 1` (`lib/openagents_web/controllers/health_controller.ex` line 5),
which succeeds on an unmigrated database, and the smoke never verifies the
database is fresh. Remove the migration call and every cited proof stays
green.

**Smallest change:** a `test/openagents/runtime_config_test.exs` case
asserting staging and production refuse `migrate_on_boot: false`, and a
migration-sensitive probe in the smoke (query a table the newest migration
creates). Also correct the evidence line: the mechanism is
`OpenAgents.Release` invoked from the application start, not the `CMD`.

### RELEASE-002 — the absence half has no detector

**Claim:** secrets are absent from source, the build context, and image build
arguments.

**Reality:** `ops/ci/reference-check.sh` is a naming check, not a secret
scan, and it cannot fail even at its own job when `rg` is missing: lines 37
and 39 end in `|| true`, and `ops/ci/gate.sh` line 71 checks for `jq mix npm`
but never `rg`, so on a builder without ripgrep the check silently passes.
Nothing reads `.gitignore` or `.dockerignore` in any test; nothing scans
`config/` or the Dockerfile for credential material; the Cloud Logging
exclusion the contract names exists only as prose in `INVARIANTS.md`. The
GitHub-config half (`test/openagents/github_oauth/runtime_config_test.exs`)
does bite, narrowly.

**Smallest change:** fail `ops/ci/reference-check.sh` when `rg` is absent
(and add it to the gate's tool check), and add a repository-tree scan test
for high-signal secret shapes in `config/` and the Docker build context —
the same read-the-repo shape `test/openagents/hosted_ci_absence_test.exs`
already uses.

### UI-003 — no population of surfaces exists to enumerate

**Claim:** product surfaces render only through the sanctioned component
library.

**Reality:** `test/openagents_web/component_catalog_test.exs` proves the
catalog page documents the components — the arrow points the wrong way — and
`test/openagents_web/ui_test.exs` proves the primitives behave. Nothing scans
surfaces: a new LiveView rendering hand-rolled markup with its own palette
passes every cited proof. The narrow template scan that exists
(`test/openagents_web/ui_contracts_test.exs`) checks inert-control rules
only, by design.

**Smallest change:** narrow the claim to what the proofs cover (the primitive
contracts and the catalog), or add a template scan over
`lib/openagents_web/**` asserting variant-bearing markup uses the sanctioned
class-plus-data-attribute shapes.

### DATA-001 — the projection-loss clause has no test

**Claim:** losing PubSub or the LiveView stream must not lose accepted data;
rows are persisted before their state is presented as accepted.

**Reality:** the cited tests prove `create_turn/2` persists and a happy-path
turn renders (`test/openagents/conversations_test.exs` lines 28-41,
`test/openagents_web/live/chat_live_test.exs` lines 536-589). Nothing kills
a subscription, drops a stream, or asserts persist-before-broadcast ordering,
so a regression to broadcast-then-persist passes.

**Smallest change:** narrow the claim to what the tests prove (durable rows
for accepted turns), or add an ordering assertion at the delta-persistence
seam.

## Claims the code or the tests contradict

These are prose defects: the proof is fine or repairable, but the sentence in
the ledger is not what the system does.

- **VOICE-006 and VOICE-009** both state "sending typed input while voice is
  active ends the voice generation first." The cited test proves the
  opposite by design: `test/openagents_web/live/chat_live_test.exs` lines
  282-342 is titled "typing during a live voice call keeps the call open and
  hands voice the message" and asserts the session stays `listening`. The
  no-parallel-responses property may still hold through injection (no text
  turn opens), but the stated mechanism is a superseded design.
- **DATA-002** credits "unique indexes and identity-source constraint in
  `create_github_users`." No migration by that name exists — the indexes live
  in `priv/repo/migrations/20260816214200_create_sarah_conversations.exs` —
  and no identity-source constraint exists at all: nothing prevents a
  visitors row carrying both a browser key and a user ID. No test inserts a
  duplicate or races two creates, so dropping the unique indexes also fails
  nothing.
- **ADMIN-001** says the `/admin` panel shows recording completeness
  metadata; `test/openagents_web/live/admin_live_test.exs` lines 110-119
  refute recording strings with a stale comment claiming the product does not
  capture call audio, and line 139's model-ID refutation is vacuous because
  no call is seeded.
- **IDENTITY-007**'s proof index row cites `test/openagents/agents_test.exs`,
  which contains no grant test; the lifecycle is actually proven in
  `test/openagents/forge/assignment_test.exs` lines 105-131 and the two
  controller suites. The index row should follow the tests that exist.
- **STACK-001** cites `ops/ci/stack-contracts.sh` as evidence; nothing
  invokes it — it appears in no gate stage and wraps the same test file the
  suite already runs.
- **RELEASE-001**'s "Evidence: Docker `CMD`" points at a command with no
  migration step (see above).
- **MEMORY-003**'s evidence line lists `test/openagents/profile_memory_test.exs`
  twice — cosmetic.

## Tautologies, wrong chokepoints, and unexercised constraints

The most consequential "partial" verdicts, each with the violation the proof
misses.

### THREAD-001 — the race proof does not race

`test/openagents/threads/credit_race_test.exs` line 20 is
`use OpenAgents.DataCase, async: false`, and `test/support/data_case.ex`
line 40 starts the sandbox owner in shared mode for non-async tests. Every
`Task.async_stream` worker therefore serializes on one shared connection —
the concurrent opens and mints are savepoints on a single transaction, not
competing transactions. Deleting both `FOR UPDATE` locks in
`lib/openagents/threads.ex` (the admission-cap lock and the mint-side lock)
leaves all four tests green, and THREAD-001's amended text cites this file as
proving "the cap holds under concurrency." The token-reach half of THREAD-001
(`test/openagents/threads/grant_token_reach_test.exs`) is the strongest
enumeration in the repository — four derived sets, both directions, explicit
non-emptiness guards, route population from the router. The race clause needs
a test that checks out two real connections (unsandboxed or with explicit
allowances) before it proves anything.

### REPUTATION-001 — verification shares the producer's canonicalization

Every signature and digest check verifies with the same
`OpenAgents.Provenance.Canonical` encoding that produced the claim
(`test/openagents/reputation_test.exs` lines 38 and 45-49;
`lib/openagents/reputation/claim.ex` lines 103 and 112). A canonicalization
bug — a dropped field, an unstable ordering — verifies fine on both sides.
The tamper test (lines 116-124) catches a signature that ignores content, not
an encoding that ignores a field. "No function returns a ranking" is one
`function_exported?` check on one name (line 93) with no enumeration of the
module's exports. The key-rotation half
(`test/openagents/forge/key_rotation_test.exs`) bites hard and is the model
to follow. Smallest change: pin one full claim to a hard-coded expected byte
encoding and digest, the way `test/openagents/forge/wal_test.exs` lines
282-298 pin the WAL encoding.

### TOOL-005 — the boundary is enumerated at the wrong chokepoint

`test/openagents/dependency_boundary_test.exs` lines 152-178 enumerate
callers of `OpenAgents.Tools.Selector` and require each to name
`OpenAgents.Tools.Reach`. But `OpenAgents.Tools.Registry` is itself a public
un-narrowed catalog builder — `lib/openagents/tools/registry.ex` line 135
forwards whatever options it was handed — and the real catalog builders sit
one hop out (`lib/openagents/turns/turn_server.ex` line 113,
`lib/openagents/work/job_server.ex` line 138), outside the enumeration. A new
caller of the registry's prompt-definitions functions that omits `:reach`
offers the whole catalog and stays green — the exact violation the contract
says this test catches. The "names Reach" check is also satisfied by the
registry's unrelated boot-time `Reach.requirements()` call
(`lib/openagents/tools/registry.ex` line 366), so it cannot distinguish
resolving a caller from mentioning the module. Smallest change: enumerate
callers of the registry's catalog-building functions and require the reach
option at those sites.

### SELF-EDIT-001 — the population is a namespace prefix and the assertion is vacuous on empty

`test/openagents/dependency_boundary_test.exs` lines 196-198 filter to
modules named under the tools namespace, but the contract quantifies over
"every tool module." A tool-shaped module elsewhere — the coding work module,
a future plugin namespace — can name the hot-loader and stay green. The
assertion at line 93 is `offenders == []`, which passes if the module
enumeration breaks and returns nothing (unreadable BEAMs are swallowed at
line 210), and the fleet-release module list at lines 43-50 is hand-declared
with no existence check, so a renamed release module silently empties the
check forever. Smallest change: assert the enumerated population and the
release-module list are both non-empty, and derive the tool population from
the shipped-plus-fixture catalogs rather than a name prefix.

### SETTLEMENT-001 — the uniqueness ladder is never climbed

Every "pays once" mechanism is a constraint no test reaches: the payment-hash
unique index (`priv/repo/migrations/20260823060000_create_bounty_settlement.exs`
line 147) cannot collide because the test gateway returns a constant hash and
no second payment ever succeeds; the single-`paid`-intent partial index and
the one-receipt-per-intent index are shadowed by earlier context refusals.
The invariant calls its schemas "seven append-only schemas," and no
append-only trigger exists on any settlement table — the refund test re-reads
a receipt and finds it unchanged, but nothing would have refused a rewrite.
Smallest change: raw-insert tests against each uniqueness constraint, and
either add the append-only triggers or strike the phrase.

### COMPENSATION-001 — the payout check reads back a literal

"Never creates payout authority" is proven by
`refute function_exported?(..., :payout, 2)` and by asserting
`payout_authority == false` in a projection that hard-codes the literal
(`lib/openagents/compensation.ex` lines 30, 205, 239). The real defense — the
database CHECK on the policy rules
(`priv/repo/migrations/20260817010500_create_compensation_accounting.exs`
line 162) — is never bitten, and only one of seven append-only triggers is
tested. Smallest change: insert a policy with `payout_authority: true` raw
and assert PostgreSQL refuses.

### EFFECT-001 — the production call site's transaction is untested

The outbox mechanics bite (`test/openagents/effects_test.exs`: real rollback,
real payload-digest conflict, real reclaim, genuinely concurrent claims). But
`test/openagents/effects/work_launch_test.exs` lines 27-41, titled "commits
its launch in the same transaction," asserts only that the effect exists
afterward, and the refusal case fails before the enqueue runs — so moving the
enqueue outside the job transaction, reintroducing the exact crash window
EFFECT-001 exists to close, keeps both tests green. The two schema
constraints the contract leans on (`effects_lease_pair_check`,
`effects_status_shape_check` in
`priv/repo/migrations/20260824204740_create_effects.exs`) are never reached
by any test. EFFECT-002's milestone separation therefore also rests on
untested constraints. Smallest change: a raw insert against each constraint,
and a work-launch test that crashes between the job insert and the launch and
asserts the effect row exists.

### MODULE-001 — the pre-invocation byte check is real and unproven

The runner verifies the loaded executor before invocation
(`lib/openagents/tools/registry.ex` line 190), but the only tamper test
mutates an in-memory struct and calls the verify helper directly
(`test/openagents/modules/registry_test.exs` lines 171-184). Delete the
runner's check and the suite passes; no test unloads or changes module bytes
and drives the runner. Smallest change: purge a tool module's code in a test
and assert the runner returns the unavailable outcome.

### EXIT-005 — the sole-writer clause and the publisher

The chain, the rewrite mutation, and the anchor checks are excellent — the
rewrite is a real byte-level rewrite with recomputed keys, and the stranger's
anchor is taken from served bytes. Two clauses still have no proof:

- **"`append_entry/2` is the one function every writer reaches the log
  through"** — unchanged since the 2026-08-23 audit recorded it (issue #151).
  No test enumerates WAL writers, and the escape is real: `append_entry/2` is
  pure; the durable write is the CAS, and the test suite itself writes
  indexes without the chain in four places in
  `test/openagents/forge/independence_test.exs`. On a log with a pre-contract
  prefix, a bypassing writer's `chain_link_missing` is classified as history
  (`lib/openagents/forge/verification.ex` lines 330-341), so the bypass can
  be absorbed silently. The current writer population is three modules
  (`lib/openagents/forge/pushes.ex` line 175, `lib/openagents/forge/git_plane.ex`
  line 532, `lib/openagents/repositories/importer.ex` line 450); an
  import-table enumeration in the shape of
  `test/openagents/threads/grant_token_reach_test.exs` would close it.
- **`OpenAgents.Forge.AnchorPublisher` has zero test coverage.** Every anchor
  test calls the publish function by hand; nothing proves the scheduled child
  runs, reschedules, or that `published_at` advances — the clause the
  contract says lets a reader see that publication has stopped. Removing the
  supervisor child fails nothing.

Also: the encoding is verified by the same module that produces it;
`test/openagents/forge/wal_test.exs` lines 282-298 mitigate this with a
pinned hard-coded digest, which is the right shape and worth extending to a
full entry-plus-link vector.

### EXIT-002 and EXIT-003 — depth-1 import tables and a hand-listed function set

The independence reads are strict about missing modules (a `MatchError`, not
an empty pass), but they read one module's own import table only: a helper
module between the verifier and the database, or an `apply/3`, is invisible.
The mirror-function refusal at `test/openagents/forge/independence_test.exs`
line 564 names three functions as a literal with no completeness assertion
against the pushes module's exports — a new mirror-reading export evades it.

### EXIT-001 — six probes accept 200 with an empty body

`read_probe/2` (`test/openagents/data_rights/export_inventory_test.exs`
lines 529-534) treats any 200 as portable without checking the body, so the
six families the contract narrates as previously blocked would still read
portable if their routes regressed to returning empty lists for the owner's
own records. The issue, project, and repository probes check for the seeded
record; these six should too.

### WORK-001 — two of three bounds and the resume claim

The tool-call ceiling bites; the continuation ceiling and the ten-minute wall
clock have no test (no hit for either reason code in `test/`). The
non-advertisement clauses (no `deep_work` in a job's provider request, no
`work.delegate` or `memory.write` authority) are structurally invisible to
the scripted provider, which ignores the tools field entirely. Recovery
"resumes and continues" is asserted only as "not interrupted, generation
advanced" — a worker that adopts and immediately fails passes. SCV-001
inherits the same shape: "no job may deploy one" (`scv.deploy` never in job
authorities) has no test.

### Route classification — the catch-alls and the operator class

`test/openagents_web/authenticated_route_gate_test.exs` is the real thing —
derived population, non-empty guard, actual anonymous dispatch. Two
structural gaps sit beside it. First, the classifier's catch-alls
(`lib/openagents_web/route_authority.ex` line 588 for API GETs, lines 695-724
for browser path shapes) classify unknown reads as `:public_read` silently —
a private GET added in one of those shapes leaves the gate population without
failing anything; the box fan-out status route already demonstrates the
mislabel (harmless today only because the API inventory independently
dispatches it). Second, no test dispatches `:operator` routes anonymously as
a class — the gate test filters them out, and
`test/openagents_web/operator_surface_test.exs` proves membership, not
behavior, checking `pipe_through` for exactly one route. A route correctly
classified and correctly listed, but wired without the operator pipeline and
without an in-handler recheck, passes everything. FLEETPROMOTE-001's
`/admin/forge` is one path-keyed classification away from that shape, saved
today by its own LiveView test. Smallest change: dispatch the operator class
anonymously the way the authenticated class is dispatched.

### Scope-boundary scans — one backend is invisible and one guard is missing

`test/openagents/memory/scope_boundary_test.exs` is two proofs of different
strength. The entry-point enumeration bites. The query scan does not guard
against emptiness on the recall side (line 196 iterates whatever the AST scan
returns), and `OpenAgents.Memory.HybridRecall` reaches the database only
through raw SQL the AST scan cannot see — deleting the conversation predicate
from `lib/openagents/memory/hybrid_recall.ex` line 70 fails nothing. The scan
also accepts a scope column named anywhere in the query, not only in a
`where`. Separately, `OpenAgents.Memory.SemanticIndex.rebuild/1`
(`lib/openagents/memory/semantic_index.ex` lines 120-126) reads messages
across every conversation and sits outside both MEMORY-001's and MEMORY-004's
populations. And PRIVACY-001's projector enumeration labels
`OpenAgents.Tools.MemoryContract` as reading the category list only, while
its `memory_output/1` returns the raw stored claim to the model with no
redaction pass (`lib/openagents/tools/memory_contract.ex`) — the one-projector
assertion at line 264 compares the declaration to itself, and the redaction
check at line 270 is satisfied by any mention of the redaction module.

### UI-002 — the AST matcher's syntax blind spot

`test/openagents_web/tool_activity_projection_test.exs` has real anti-vacuity
guards and both-direction key sets, but its matcher recognizes only
`from ... select:` keyword queries; a projection written as a pipeline
(`select/3`, `select_merge`, a `Map.take` after the query) lands in neither
set and the exactness still passes.

### PERSONA-001 — two adapters have no wire probe

The behaviour and atom-table enumerations bite in both directions. But of the
three outbound HTTP adapters, only one is driven against a capturing plug;
`OpenAgents.Providers.OpenRouter` and `OpenAgents.Providers.VercelGateway`
have no wire probe in the boundary file, the configured-provider backstop
reads test-double config rather than production selections, and the
gateway's config key is not in the checked set. An OpenRouter payload builder
that appended its own system text would pass. (The payload test that exists
covers the messages field only, and shows instructions are trimmed — so
"byte for byte" is already not literal there.)

### PROVIDER-002 — lane routing is unverifiable under test config

The refusal paths bite against the production catalog list. But all three
provider lanes are the same test module under `config/test.exs`, so the
adapter-lane assertions are `Test == Test`, and the catalog endpoint tests
compare the response to the same function that renders it.

## The gate itself

Findings that are about whether proofs run, not whether they can fail.

- **A Markdown-only candidate runs no tests.** `ops/dev/precommit.sh` lines
  61-81 skip the test suite when every changed path is documentation, and
  `ops/ci/gate.sh` line 116 runs precommit as a stage — the receipt still
  records the stage as passed. Tests with no dedicated gate stage are only
  reached through precommit, including
  `test/openagents/hosted_ci_absence_test.exs`,
  `test/openagents/network_status_test.exs`,
  `test/openagents_web/transparency_surface_test.exs`,
  `test/openagents/transparency/work_disclosure_test.exs`,
  `test/openagents/forge/deployment_lane_test.exs`,
  `test/openagents/capacity_test.exs`, and both token-vault suites. This is
  the most likely mechanism by which the red operator-surface enumeration
  reached `main`.
- **The gate receipt is forgeable and short-circuits.** `ops/ci/gate.sh`
  lines 15-30 and 51-54: an unsigned JSON at a known path skips the gate
  entirely. `test/openagents/forge/gate_receipt_test.exs` proves shape and
  SHA-binding, not authenticity — RELEASE-004 does not claim authenticity, so
  this is a bound to record rather than a defect, but the stage list is
  declared in three unlinked places and nothing ties the receipt's list to
  the script's.
- **`ops/ci/reference-check.sh` passes when `rg` is missing** (see
  RELEASE-002 above).
- **RELEASE-004's absence test covers hosted providers by list**, and the
  list omits `cloudbuild.yaml` — notable because the deployment target is
  Google Cloud — plus a handful of others (CodeBuild, Bitbucket, Gitea and
  Forgejo workflow paths).
- **VAULT-001's third vault has no test.** `OpenAgents.Voice.RecordingVault`
  has no test file; nothing proves it does not borrow the GitHub key, and no
  enumeration closes the vault population, so a fourth vault that borrows a
  key is invisible.

## Every contract, one verdict

Verdicts: **can fail** (the cited proof goes red when the claim is violated),
**partial** (the core clause can fail; the named clause cannot), **cannot
fail** (a load-bearing clause has no proof that can go red). Details above
where a section exists; one line here for everything else.

### Identity and canon

| Contract | Verdict | Sharpest gap |
| --- | --- | --- |
| CANON-001 | partial | Content SHA-256 is shape-checked, never compared to any file's bytes (`lib/openagents/persona/source_manifest.ex` line 256) |
| CANON-002 | can fail | Strongest enumeration in the set; pattern covers the public schema only, and the audit-kind check is one-directional |
| PERSONA-001 | partial | Two of three outbound adapters have no wire probe; config backstop reads test doubles |
| PERSONA-002 | can fail | Voice-session role receipt persistence has no cited proof |
| PERSONA-003 | partial | The incomplete-results branch is untested; corpus digest computed on both sides, so a weakened corpus moves both |
| BLUEPRINT-001 | partial | Deletion of admitted rows and the facts table never attempted; explicit-none pinned only at the composer layer |
| PROGRAM-001 | partial | No-effect-authority is four atom names on one module; the in-flight-capture test asserts BEAM immutability |
| DEGRADE-001 | can fail | Real trigger tests, default path covered |
| PROGRAM-002 | partial | "The live turn never consumes their result" has no test; the synthetic-corpus claim is the fixture describing itself |
| PROGRAM-003 | can fail | Generation-pointer proof is genuine |

### Identity and authorization

| Contract | Verdict | Sharpest gap |
| --- | --- | --- |
| IDENTITY-001 | can fail | One-time state, replay, ban, token-never-in-browser all driven |
| IDENTITY-002 | partial | Classifier catch-alls mislabel silently; Repo-reach scan has no positive control; public-read LiveViews exempt from the event hook |
| IDENTITY-003 | partial | Non-persistence is a schema field-name check; KDF envelope parameters unpinned |
| IDENTITY-004 | partial | One-active-link constraint and attribution-across-unlink untested |
| IDENTITY-005 | can fail | Route list is 5 of 12 box-control paths |
| IDENTITY-006 | cannot fail | See section above |
| IDENTITY-007 | partial | Cited file has no grant test; real coverage lives elsewhere |
| IDENTITY-008 | can fail | Lock asserted from the live database function; contention window honestly declared unproven |
| IDENTITY-009 | can fail | Planted-secret redaction is a real control |
| IDENTITY-010 | can fail | Catalog scan with positive control; nested-value and derived-copy residues |
| IDENTITY-011 | can fail | Query plan asserted with sequential scans priced out |
| IDENTITY-012 | can fail | Residue: a future non-changeset writer of guarded columns |
| CAPACITY-002 | can fail | Concurrency tests would fail without the locks |
| CAPACITY-003 | partial | Interval test asserts the literal it passed in; 15-second timeout and cost parser untested |
| WORK-002 | can fail | Single-probe and cancellation-stamp ordering proven |

### Data, memory, and privacy

| Contract | Verdict | Sharpest gap |
| --- | --- | --- |
| DATA-001 | cannot fail | See section above |
| DATA-002 | partial | Cited migration name and identity-source constraint do not exist; no duplicate-insert or race test |
| DATA-003 | can fail | Partition test is complete; timestamp-tie determinism unasserted |
| MEMORY-001 | can fail | The semantic-index rebuild reads cross-conversation and sits outside the population |
| MEMORY-002 | partial | Model-side clauses vacuous against a scripted provider; host-side halves bite |
| MEMORY-003 | can fail | Real trigger tests via raw SQL |
| MEMORY-004 | partial | Query scan vacuous for the hybrid backend's raw SQL; no non-empty guard on the recall side |
| MEMORY-005 | cannot fail | See section above |
| MEMORY-006 | partial | Synonym-recall metric measures the test's own regex provider |
| MEMORY-007 | can fail | Gate driven end to end with each bypass refused |
| MEMORY-008 | partial | Default-off asserted from the eval JSON, not the shipped config |
| MEMORY-009 | partial | Same default-off defect; build determinism genuinely proven |
| PRIVACY-001 | partial | The claim-projecting tool is mislabeled and skips redaction; projector assertion compares the declaration to itself |

### Turn, provider, and effects

| Contract | Verdict | Sharpest gap |
| --- | --- | --- |
| TURN-001 | can fail | Real second insert against the real index; no concurrent case |
| TURN-002 | partial | Single-transaction claim untestable as written — moving inserts out of the transaction passes |
| TURN-003 | partial | Non-blocking proven; persist-before-broadcast ordering not |
| TURN-004 | can fail | Idempotency claimed, never called twice |
| TURN-005 | partial | Parallel-call refusal and continuation ceiling have zero tests |
| PROVENANCE-001 | can fail | Five raw-SQL trigger tests; the strongest turn proof |
| PROVIDER-001 | partial | Contract test iterates two of four adapters |
| PROVIDER-002 | partial | Lane assertions are the same module compared to itself under test config |
| EFFECT-001 | partial | See section above |
| EFFECT-002 | partial | The status-shape constraint that carries the claim is untested |
| TOOL-001 | partial | No registry rebuild mid-turn; digest compared to the live registry |
| TOOL-002 | partial | Execution contexts hand-built rather than application-created |
| TOOL-003 | can fail | Claim atomicity proven sequentially only |
| TOOL-004 | partial | The UI disclosure test runs entirely on literal maps |
| TOOL-005 | partial | See section above — wrong chokepoint |
| TOOL-006 | can fail | Reads shipped config through the prod reader, not the test fixture; both directions |
| DEGRADE-002 | can fail | Honest-degradation asserted on the rendered answer |

### Collective, settlement, and modules

| Contract | Verdict | Sharpest gap |
| --- | --- | --- |
| COLLECTIVE-001 | partial | Cited database constraints never exercised; raw-quote check is six hand-listed fields |
| COLLECTIVE-002 | cannot fail | See section above |
| COLLECTIVE-003 | can fail | Append-only via real constraint errors |
| COMPENSATION-001 | partial | See section above |
| REPUTATION-001 | partial | See section above |
| SETTLEMENT-001 | partial | See section above |
| MODULE-001 | partial | See section above |
| MODULE-002 | can fail | Projection key allowlist would strengthen it |
| MODULE-003 | can fail | Nine-axis filter matrix is a real enumeration |
| MODULE-004 | cannot fail | See section above |

### Delegated work, threads, and deployment plane

| Contract | Verdict | Sharpest gap |
| --- | --- | --- |
| WORK-001 | partial | See section above |
| SELF-EDIT-001 | partial | See section above |
| SCV-001 | partial | The no-job-may-deploy clause has no test |
| OUTCOME-001 | partial | Four of five false-green classes never pass through either path; the pure-grader suite proves fixtures |
| THREAD-001 | partial | Token reach is exemplary; the race proof does not race (see above) |
| THREAD-002 | can fail | Write routes dispatched as a reader; one subset check is one-directional |
| DEPLOYPLANE-001 | partial | Artifact-digest format never validated |
| DEPLOYPLANE-002 | can fail | Every bound dimension widened in turn |
| DEPLOYPLANE-003 | partial | The digest half of "same SHA and same digest" never varied on the admission path |
| DEPLOYPLANE-004 | cannot fail | See section above |
| DEPLOYPLANE-005 | partial | Supervisor gating untested; all provider claims carried by the one fake |
| FLEETPROMOTE-001 | can fail | Best-proven contract in the ledger; the browser route's pipeline membership rests on its own LiveView test |

### Voice, admin, and interface

| Contract | Verdict | Sharpest gap |
| --- | --- | --- |
| VOICE-001 | can fail | Architecture and provider values never given a bad case |
| VOICE-002 | partial | CSRF never omitted; SDP size ceiling untested; header check greps the variable name, not the value |
| VOICE-003 | partial | The database-constraint half is unproven; the one-active index has no test and the code path does not use it |
| VOICE-004 | can fail | Hostile provider frames through the real decoder |
| VOICE-005 | cannot fail | See section above |
| VOICE-006 | can fail | But the prose contradicts the cited test (see above) |
| VOICE-007 | can fail | Changed-identity refusal has no dedicated test |
| VOICE-008 | can fail | Exact durable terminal set asserted |
| VOICE-009 | can fail | Real chronology plus a real constraint error; same stale sentence as VOICE-006 |
| VOICE-010 | partial | The advisory-lock serialization claim has no concurrent test |
| VOICE-011 | partial | The event-kind field is a free-text channel no test constrains; the 64-event cap untested |
| VOICE-012 | can fail | The no-opt-out never-claim has no closing mechanism |
| ADMIN-001 | can fail | Red right now (see above); membership proven, class-wide behavior not |
| DATA-004 | can fail | Cascade seeded broadly with direct-delete refusals first; the voice-summary export branch is vacuous |
| UI-001 | partial | The operator class is never dispatched anonymously |
| UI-002 | can fail | Pipeline-syntax queries evade the matcher |
| UI-003 | cannot fail | See section above |
| LEADERBOARD-001 | can fail | Two named exclusions never seeded, so excluded vacuously |
| OBSERVABILITY-001 | cannot fail | See section above |

### Release, status, and transparency

| Contract | Verdict | Sharpest gap |
| --- | --- | --- |
| RELEASE-001 | cannot fail | See section above |
| RELEASE-002 | cannot fail | See section above |
| VAULT-001 | partial | The recording vault has no test; no enumeration over the vault population |
| RELEASE-003 | cannot fail | See section above |
| RELEASE-004 | partial | Provider path list omits the deployment target's own CI config file |
| RELEASE-005 | can fail | Empty-relup refusal is a real positive control |
| RELEASE-006 | can fail | Both directions of refusal at target and readiness |
| RELEASE-007 | can fail | Parses the real Dockerfile; one silent-skip seam when a variable is undeclared in a stage |
| RELEASE-008 | can fail | Runs the real OTP walk against the real running application |
| RELEASE-009 | can fail | Fail-closed in every direction; the file has no dedicated gate stage |
| STATUS-001 | can fail | Structs contribute one opaque key; degradation enumerated for one section only |
| CAPACITY-001 | partial | Redaction proven over nine hand-listed fields, no exact key set on the projection |
| TRANSPARENCY-001 | partial | The route population filter misses the anonymous JSON API entirely; the gate check proves a static reference, not a gated path |

### Repository, exit, and issues

| Contract | Verdict | Sharpest gap |
| --- | --- | --- |
| REPOSITORY-001 | can fail | The past insert-the-grant-yourself defect is genuinely closed; regex-evading join forms remain the residue |
| API-001 | partial | Governance covers one of four extension objects; one enum is written twice with nothing binding the copies |
| CONTRIBUTION-001 | can fail | Cross-binds the document to the router, both authorities, and the real push guard |
| REPOSITORY-002 | can fail | Executes the real script against real hostile remotes |
| REPOSITORY-003 | can fail | Real pushes, real cache deletion, real replay |
| EXIT-001 | can fail | Six probes accept 200 with an empty body (see above) |
| EXIT-002 | partial | Depth-1 import tables; helper-module indirection invisible |
| EXIT-003 | partial | Mirror-function list is a literal with no completeness check |
| EXIT-004 | can fail | Rebuilds the exact #179 failing shape and clones for real |
| EXIT-005 | partial | Sole-writer clause still unproven (#151); the anchor publisher has zero coverage (see above) |
| EXIT-006 | can fail | Gap list vacuous today in one direction, by honest construction |
| STACK-001 | can fail | The cited CI script is invoked by nothing |
| ISSUE-001 | can fail | Real pushes over real HTTP through the real auth plug |
| FORUM-001 | can fail | The source scan carries its own anti-rot control |
| ISSUE-002 | can fail | The lock-based no-clobber clause and the 200-body bound are untested |
| ISSUE-003 | can fail | Ambiguous-name and unsettled-name cases covered |
| ISSUE-004 | can fail | Crafted events from readers asserted to write nothing |
| PROMISE-001 | partial | The LIVE gate is proven on create, not on update into LIVE |
| PROMISE-002 | can fail | Proposed status; the append-only trigger is already exercised |
| NOTIFY-001 | partial | The "reveals nothing" clause has no proof — no schema enumeration, no content refutation anywhere in the cited tests |
| FORGEAPI-001 | can fail | Dispatches every envelope-classified route and pins the exact key set |

## What to fix first

1. **Amend ADMIN-001 for the Gym and re-run the enumeration** — the ledger is
   wrong today and the proof already says so.
2. **MEMORY-005** — decide whether the code or the sentence is right; the two
   cannot coexist. If the fallback stays, the invariant must be rewritten and
   the consent claim withdrawn.
3. **Close the gate's Markdown-only skip** or give the enumeration tests
   (operator surface, transparency surface, hosted-CI absence, work
   disclosure) a dedicated gate stage, so a red enumeration cannot land with
   a passing receipt again.
4. **RELEASE-003** — wire the tested module into production or retarget the
   proof; today the claim is carried by code nothing cited tests, and the
   cited test covers code nothing runs.
5. **THREAD-001's race** — a concurrency proof in shared sandbox mode proves
   serialization by the test harness, not by the lock. Two real connections
   or an honest narrowing.
6. **The unexercised constraint set** — settlement uniqueness and append-only,
   the effects lease-pair and status-shape checks, compensation's payout
   CHECK, the voice one-active index: each is one raw-SQL test in the shape
   `test/openagents/threads/grant_fence_test.exs` already uses everywhere.
7. **EXIT-005's writer set and publisher** — the one remaining row from the
   2026-08-23 audit's closing table, still open, plus a supervised child with
   no test.
8. **IDENTITY-006** — the credential's branch discipline is the whole point
   of the contract and is one real receive-pack test away from proven.

A closing observation the counts understate: the proofs this repository
builds when it decides to enumerate — the operator surface, the grant-token
reach, the visibility joins, the WAL rewrite, the fleet-promotion caller
sets — are genuinely strong, and three of them caught real defects during
this audit (the Gym, the mislabeled fan-out route, the stale admin-panel
comment). The recurring weakness is not the enumerations; it is the sentence
beside them that names a mechanism ("in one transaction", "under a lock",
"append-only", "the only definition", "before the supervision tree starts")
that no test has ever watched fail. Where a constraint or an ordering is
load-bearing, the proof should reach it raw — the way the fence, provenance,
and profile-memory tests already do — or the ledger should stop crediting it.
