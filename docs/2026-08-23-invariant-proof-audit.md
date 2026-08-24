# Invariant proof audit: which proofs can fail for what they claim

`ADMIN-001` said no routed controller returns recording audio.
`GET /admin/recordings/:id/audio` returned exactly that, and had since it
landed, with its own passing test. The invariant's proof was green the entire
time the claim was false, because the proof examined the `/admin` panel and the
claim covered every routed controller.

Fixing it in `443c74b` found three more carrying the same shape: `VOICE-012`,
`DATA-004`, and `UI-001`. The pattern is exact. **Each was proven by tests of
*a* surface while asserting something about *every* surface.** A test of the
surfaces someone thought of cannot fail on the surface they did not, so the
proof is green precisely when it would be most useful.

`docs/taxonomy.md` naming rule 7 says a contract is not true until its proof
runs green. All four were green. This document records the companion rule and
the audit that applies it to every contract in `INVARIANTS.md`:

> A proof must be capable of failing for the claim it names.

## The test

For each contract, classify the claim, then apply one mechanical check.

**Specific** claims name a behavior at a named seam. "Explicit interruption
commits before provider cancellation" is about one code path, and a test of
that path is a proof of that claim. Most contracts here are specific, and that
is a good outcome rather than a gap.

**Universal** claims quantify: "no route", "every surface", "nothing", "only",
"at most one". For each one, name a violation its proof would not catch. If you
can name one, the proof does not bite.

The distinction that decides the answer is not the word "every". It is what
closes the population.

- **Closed by a mechanism.** "Every admitted Blueprint revision is a complete
  canonical snapshot" quantifies over rows in a table whose constraints reject
  anything else. PostgreSQL cannot forget a row, so the constraint is the
  enumeration. The same holds for a claim closed by a configuration list, a
  schema, a struct definition, a committed corpus, or a single validating
  function every value passes through.
- **Closed by memory.** "Every surface that builds a model-facing catalog
  resolves the caller" quantifies over a population that grows when a person
  adds a file. Nothing rejects the new member. The proof bites only if it
  derives the population from compiled or declared truth and compares it
  against a set the ledger declares.

Claims closed by memory are the defect class. Everything below is sorted by
that answer.

## Result

118 contracts, one verdict each.

| Verdict | Count |
| --- | --- |
| Specific — a named behavior at a named seam | 56 |
| Universal — the population is closed, so the proof bites | 41 |
| Universal — the proof did not bite; enumerated here | 17 |
| Universal — the proof did not bite; narrowed here | 2 |
| Universal — the proof does not bite; still open | 2 |

Two of the seventeen carry a residual clause that is still open, so the closing
table below lists three rows against three contracts. `IDENTITY-002` and
`THREAD-001` were enumerated under issue #174, `REPOSITORY-001` under #175,
`MEMORY-001`, `MEMORY-004`, and `PRIVACY-001` under #172, and `STATUS-001` and
`TRANSPARENCY-001` under #173, which also narrowed `UI-002` to the tool-step
projections its proof can cover. All nine moved out of that table.
`IDENTITY-002` and `REPOSITORY-001` keep a named residue, recorded in each
contract rather than here.

**How firm each verdict is.** The seventeen, the two, and the ten were established
by reading the named proof and, where the answer was not obvious from it,
querying the compiled application for the population the claim covers. The 41
were established from the contract prose and the mechanism it names — a
database constraint, a `config/config.exs` list, a struct definition, a
committed corpus, a source-tree scan, a route inventory. Some were read at the
test as well — the ones in the table under "Already enumerating" — and the rest
were judged from the mechanism the contract names rather than re-derived. A
second pass over those would be worth doing and is not what this one did.

## Universal claims fixed here

Each got an enumerating proof, and each proof was mutation-checked: break the
property, confirm red, restore.

### `PROVIDER-001` — conversation and web code depend on the behavior

**Would have missed:** a module calling `OpenAgents.Providers.OpenAI` directly.
`provider_contract_test.exs` iterates a two-element list of adapters and
asserts three behaviors *of the adapters*; nothing looked at the code that must
not know about them.

**Now:** `OpenAgents.DependencyBoundaryTest` reads every compiled module's
import table and asserts that the only module naming anything in the adapter's
namespace is the adapter itself. The adapter is reached through configuration,
so it carries no import edge — which is the property replaceability means.

### `SELF-EDIT-001` — no OpenAgents tool can promote, deploy, or hot-load

**Would have missed:** a tool module reaching `OpenAgents.Forge.Targets`. The
nearest proof, `shipped_catalog_test.exs`, checks `side_effect` over the six
modules `config/config.exs` admits. Roughly fifty modules live in
`lib/openagents/tools/`, and the next tool comes from one of the unadmitted
ones.

**Now:** the same test enumerates every module in `lib/openagents/tools/` and
fails on a dependency into promotion, deployment, relup, rolling replacement,
or hot-loading.

### `SCV-001` — every surface that starts an SCV enters the admission gate

**Would have missed:** a second caller of `OpenAgents.Work.start_scv/1`, which
is public and unguarded. `deployments_test.exs` proves the gate refuses a
non-operator; it cannot prove that everything reaches the gate.

**Now:** the callers of `start_scv/1` are an exact set, and that set is
`OpenAgents.SCV.Deployments`.

### `FLEETPROMOTE-001` — one authority path, not two implementations

**Would have missed:** a third surface calling `OpenAgents.Forge.Promotion`, or
a second writer calling `OpenAgents.Forge.Targets.promote/4` and skipping the
scope and live-standing checks.

**Now:** both caller sets are asserted exactly —
`OpenAgents.Forge.Promotion` is the only caller of `promote/4`, and
`OpenAgentsWeb.AdminForgeLive` and `OpenAgentsWeb.FleetTargetController` are
its only callers.

### `TOOL-005` — every surface that builds a model-facing catalog resolves the caller

**Would have missed:** a new surface calling `OpenAgents.Tools.Selector`
without `:reach`. `OpenAgents.Tools.Selector.reachable/2` returns the whole
list when it is given no caller, so the new surface offers unreachable tools
and every test stays green. `reach_test.exs` enumerates the other axis, tools
and their declared requirements, which is why the gap was not visible from it.

**Now:** the modules that call the selector are an exact set, and each must
also name `OpenAgents.Tools.Reach`.

### `IDENTITY-001`, `IDENTITY-002`, `UI-001` — the authentication boundary

**Would have missed:** a route added outside the `:authenticated` pipeline.
`auth_gate_test.exs` asks eleven hand-written paths whether they redirect. A
twelfth is not on the list.

**Now:** `OpenAgentsWeb.AuthenticatedRouteGateTest` dispatches every route
`OpenAgentsWeb.RouteAuthority` classifies `:authenticated_browser` without a
session — 40 of them today — and requires each to refuse with a redirect to the
public root or a `401`. `route_authority_test.exs` already fails a route it
cannot classify, so the two together close the loop from the router.

### `IDENTITY-002` — a LiveView event must not select another user

**Would have missed:** an event handler resolving a record from its own params
rather than from the socket's scope. `OpenAgentsWeb.AdminForumLinksLive` did
that — `Repo.get!(Forum.ActorLink, id)` straight from the event params, with no
in-body authority check, unlike its six operator siblings. Its route is
classified `:operator`, so `authenticated_route_gate_test.exs` and
`operator_surface_test.exs` were both green over it: a route table sees the
pipeline, not the handler.

**Now:** `OpenAgentsWeb.LiveViewScopeTest` enumerates two mechanisms.
`OpenAgentsWeb.UserAuth` attaches a `:handle_event` hook in the
`:ensure_authenticated` and `:ensure_admin` stages, so the acting account is
re-read before every event; every LiveView route classified
`:authenticated_browser` or `:operator` must sit in a live session mounting one
of those stages, and the live sessions are an exact declared set. Separately,
no LiveView reaches `OpenAgents.Repo` — the view above now resolves through
`OpenAgents.Forum.fetch_actor_link/1`. A context function that itself takes no
acting principal still passes both, and `IDENTITY-002` says so.

### `THREAD-001` — no route returns a grant token for a thread the caller did not open

**Would have missed:** a second route that renders a grant.
`thread_controller_test.exs` proves the property at the three routes that
exist, which is a proof of those routes rather than of the sentence.

**Now:** a plaintext token comes into existence in one place,
`OpenAgents.Inference.mint/1`, and leaves `OpenAgents.Threads` through
`mint_grant/1` and `open_and_mint/2,3`, so
`OpenAgents.Threads.GrantTokenReachTest` reads the compiled import edges to
those functions and asserts four exact sets — who mints, who receives, which of
them the router serves, and `OpenAgents.Threads`'s own export table, so a new
token-returning function is classified before it has callers. It then
dispatches every route the router gives that controller and requires a token in
the body only at the mint.

### `REPOSITORY-001` — repository visibility

**Would have missed:** a module deciding repository visibility with its own
restated join. Issue #166 narrowed the sentence from *every* surface to the
four that compose `readable_by/2`, because about thirty modules join the
repositories table and most reach a row by an identifier a caller already
passed authorization for. Nothing distinguished the two kinds, so a restated
join failed nothing — and three existed, two of them wrong.
`OpenAgents.Issues.get_issue_by_path!/3` and
`OpenAgents.Projects.get_project_by_path!/3` omitted `lifecycle_state`;
`OpenAgents.SCV.Deployments` admitted any membership row rather than one in a
reading role.

**Now:** a visibility decision is one that starts from something the caller
supplied — an owner and a name, or a listing with no prior authorization — and
an ownership reach is one that follows `repository_id` from an already
authorized row. `OpenAgents.Repositories.VisibilityJoinTest` closes the first
kind three ways: `OpenAgents.Repositories`'s own `*_by_path*` exports are an
exact set classified by the predicate each applies; the callers of the two that
do not apply the caller's predicate are exact sets read from compiled import
tables; and every site in `lib/` naming the predicate's own terms is classified
from a source-tree scan, so a restated join lands in an undeclared file. The
three restatements above compose the predicate now, and the composer list is
five modules rather than the four the contract named.

**A mutation that did not bite.** Removing the reading-role filter from
`readable_by/2` reddened nothing, because every role
`repository_memberships_role_check` admits is a reading role — the filter
guards a role nobody has added. The vocabulary is pinned against that
constraint instead, so a fifth role fails until someone says whether it reads.

**What is left.** A listing that applies no predicate at all names no term and
calls no resolver. `OpenAgents.DataRights.AccountExport`'s push-receipt and
deployment joins are that shape; each is scoped to the acting account's own
rows and selects a repository's `owner` and `name` without the predicate the
same module applies elsewhere. `REPOSITORY-001` records it.

### `RELEASE-004` — no hosted CI

**Would have missed:** a `.github/workflows/ci.yml` committed beside the owned
gate. `ops/ci/gate.sh` and `gate_receipt_test.exs` prove the owned gate runs
and binds a receipt; neither reads the repository for the thing the contract
says is absent.

**Now:** `OpenAgents.HostedCIAbsenceTest` reads the paths every hosted provider
configures itself from.

## Universal claims narrowed here

Enumeration was impractical or the wider sentence was not true, so the claim
was reduced to what its proof covers.

### `NOTIFY-001` — notification reads

It said "every read composes `readable_by/2` again". Two reads return records,
and both are built from one private `visible_query/2`. The contract now names
them and the query, which is a smaller statement its test actually covers.

## Already enumerating

These were read at the test and found sound. The population is derived, so a
new member fails until it is accounted for. They are the pattern to copy.

| Contract | What derives the population |
| --- | --- |
| `ADMIN-001` | `RouteAuthority` operator routes plus `admin?/1` import tables |
| `VOICE-012`, `DATA-004` | the same operator-surface enumeration |
| `FORGEAPI-001` | `OpenAgentsWeb.Router.__routes__/0` through `ApiRouteAuthority` |
| `DEPLOYPLANE-001` | `ApiRouteAuthority`, both directions plus anonymous dispatch |
| `API-001` | the root document read against live responses |
| `CONTRIBUTION-001` | `ApiRouteAuthority`, `RouteAuthority`, `allowed_scopes/0` |
| `EXIT-001` | `ApiRouteAuthority.families/0`, both directions |
| `EXIT-002`, `EXIT-003` | compiled import tables of the verifier and sync paths |
| `EXIT-004` | the advertised ref set against the one withheld namespace |
| `LEADERBOARD-001` | an exact field-set assertion on `Leaderboard.Entry` |
| `FORUM-001` | a source-tree scan for the retired mirror |
| `RELEASE-007` | the Dockerfile's own instruction order |
| `TOOL-006` | the `:tools` list in `config/config.exs` |

## What remains

Three claims across three contracts still rest on proofs that cannot fail for
them. Each is recorded with the violation it would miss. None is a known live defect:
these are claims whose truth currently depends on review rather than on a
proof.

| Contract | The claim | A violation the proof would miss | Carried by |
| --- | --- | --- | --- |
| `PERSONA-001` | provider adapters contain no independent persona | an adapter that composes its own instruction text | #176 |
| `IDENTITY-010` | the credential is not persisted in a job, journal, prompt, output, environment, Git configuration, or API response | a new sink that writes it | #177 |
| `EXIT-005` | `append_entry/2` is the one function every writer reaches the log through | a writer appending to an index directly | #151 |

`EXIT-005` sits in the WAL anchoring work that issue #151 carries, so it is
handed there rather than changed under it. Issue #166 stays open until every
row above is settled.

## How to add one

The shape is the same every time.

1. Find the enforcement mechanism. Operator authority lives in pipelines *and*
   in handler code, which is why `operator_surface_test.exs` needs two sets.
2. Enumerate its population from compiled or declared truth: the router,
   `RouteAuthority`, `ApiRouteAuthority`, a BEAM import table, a schema, a
   configuration list, the repository tree.
3. Compare it against a set the ledger declares, in both directions, so a new
   member fails and a stale entry fails too.
4. Mutation-check it. Break the property, confirm red, restore. A proof you
   have not seen fail is not a proof.

`test/openagents/dependency_boundary_test.exs` and
`test/openagents_web/operator_surface_test.exs` are the two worked examples.
