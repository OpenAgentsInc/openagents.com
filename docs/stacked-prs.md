# Stacked PRs: the problem, GitHub’s design, and how to build them from scratch

As of **August 22, 2026**, GitHub’s native Stacked Pull Requests feature is in public preview. GitHub announced the preview on July 30, 2026. ([The GitHub Blog][1])

The most important idea is this:

> **A stacked PR system is not merely a chain of pull requests with unusual base branches. It is an orchestration layer over ordinary Git branches and PRs.**

The branch chain gives you small, reviewable diffs. The first-class stack abstraction gives you everything else: ordering, policy inheritance, cascading rebases, stack-aware CI, merge-queue behavior, conflict handling, and the ability to merge a contiguous portion of the stack as one operation.

---

## 1. The basic model

Suppose a developer wants to ship a feature in three logical pieces:

1. Add the database schema.
2. Add the API.
3. Add the user interface.

Without stacking, the developer has two bad options:

* Put everything in one large PR.
* Wait for each PR to merge before beginning the next.

With stacked PRs, the Git history looks like this:

```text
A                         main
 \
  B                       feature/schema
   \
    C                     feature/api
     \
      D                   feature/ui
```

The corresponding pull requests are:

```text
PR 101: feature/schema → main
PR 102: feature/api    → feature/schema
PR 103: feature/ui     → feature/api
```

GitHub calls PR 101 the **bottom** of the stack because it is closest to the trunk branch. PR 103 is the **top** because it is furthest away. Each PR presents only the changes introduced by its own layer, even though the top branch contains the cumulative result of every layer below it. ([GitHub Docs][2])

Formally, let a stack be:

```text
S = [P₁, P₂, …, Pₙ]
```

where:

```text
base(P₁) = trunk
base(Pᵢ) = head(Pᵢ₋₁), for i > 1
```

For a healthy, fully restacked stack, the current commit graph should also satisfy:

```text
isAncestor(trunkTip, H₁)
isAncestor(H₁, H₂)
…
isAncestor(Hₙ₋₁, Hₙ)
```

where `Hᵢ` is the current head commit of the branch belonging to `Pᵢ`.

There are two different notions of “base”:

```text
directBase(Pᵢ) =
    trunk,               when i = 1
    head branch of Pᵢ₋₁, when i > 1

effectiveBase(Pᵢ) = trunk
```

That distinction is fundamental:

* The **direct base** determines what the reviewer sees in the PR diff.
* The **effective base** determines which branch protections, workflows, CODEOWNERS rules, and merge policies apply.

GitHub explicitly applies the stack’s trunk-branch policies to every PR in the stack, rather than allowing an intermediate feature branch to weaken or redefine policy for upper layers. ([GitHub Docs][3])

---

# 2. What problem stacked PRs solve

## 2.1 They decouple authoring throughput from merge latency

In a conventional PR workflow, a developer often finishes one change and then waits:

```text
write → open PR → wait for review → merge → begin next change
```

The waiting may take hours or days. Yet the developer already knows what the next dependent change should be.

A stack changes the workflow to:

```text
write layer 1 → open PR 1
write layer 2 → open PR 2
write layer 3 → open PR 3
```

Review and implementation proceed concurrently.

The developer does not need to merge schema work before writing API work. They can build the API on the schema branch while preserving a separate review boundary.

GitHub specifically presents this as a way to continue building dependent work without waiting for earlier PRs to merge. ([GitHub Docs][2])

## 2.2 They make reviews smaller without destroying dependency structure

A large feature might contain:

* schema changes,
* migrations,
* server types,
* business logic,
* API endpoints,
* client state,
* UI,
* tests,
* instrumentation.

A single 3,000-line PR is difficult to review. Splitting it into unrelated PRs is also difficult because later pieces cannot compile or function without earlier ones.

Stacking preserves the real dependency:

```text
UI depends on API
API depends on schema
```

while giving reviewers focused units:

```text
PR 1: Review the schema design.
PR 2: Review the API implementation.
PR 3: Review the UI.
```

This is qualitatively different from merely breaking work into commits. Each layer gets its own:

* discussion,
* reviewers,
* approval state,
* CI result,
* merge policy,
* audit trail,
* issue linkage,
* release metadata.

## 2.3 They make sequencing explicit

The stack is an explicit declaration that:

```text
P₁ must land before P₂
P₂ must land before P₃
```

Without a first-class s[118;1:3utack, this information is usually buried in:

* branch ancestry,
* PR descriptions,
* “Depends on #123” comments,
* naming conventions,
* or the author’s memory.

A first-class stack turns dependency order into enforceable data.

## 2.4 They automate cascading branch maintenance

Suppose review of the bottom PR requests a change:

```text
A---B---C---D
    ↑
  modify B
```

After modifying or rebasing `B`, the old `C` and `D` are based on the wrong history. They must be replayed:

```text
A---B'
     \
      C'
       \
        D'
```

Doing this manually is error-prone. A stack system can perform a **waterfall rebase** from the bottom upward, stopping at the first conflict and retaining enough state to continue or abort.

GitHub supports cascading rebases, and its open-source `gh-stack` CLI persists local stack and interrupted-rebase state under `.git/gh-stack`. ([GitHub Docs][2])

## 2.5 They prevent policy bypass through intermediate branches

A naïve chained-PR implementation often evaluates this PR:

```text
feature/api → feature/schema
```

as though `feature/schema` were its true destination.

That can create serious inconsistencies:

* Workflows configured for `main` might not run.
* `main`’s required checks might not apply.
* CODEOWNERS from a lower feature branch might replace the protected version.
* A lower layer could alter policy and thereby change the requirements for upper layers.

GitHub avoids this by evaluating every layer against the stack’s ultimate base branch. A workflow whose pull-request filter targets `main` can therefore run for every PR in a stack rooted at `main`, even when a PR’s direct base is another feature branch. ([GitHub Docs][3])

## 2.6 They make merging a coordinated operation

If three dependent PRs are ready, naïvely merging them requires:

1. Merge PR 1.
2. Retarget or rebase PR 2.
3. Wait for checks.
4. Merge PR 2.
5. Retarget or rebase PR 3.
6. Wait again.
7. Merge PR 3.

A stack-aware system can validate the entire contiguous prefix and merge it through a single user operation.

GitHub permits merging from the bottom through a selected PR. Selecting the top PR merges all PRs below it as well. It does not allow skipping a lower PR and merging a middle layer independently. ([GitHub Docs][4])

## 2.7 They are particularly well suited to coding agents

A coding agent naturally produces sequential units:

```text
Task 1: Add data model
Task 2: Add service
Task 3: Add endpoint
Task 4: Add frontend
Task 5: Add tests
```

Without stacks, the agent either creates a giant PR or must wait for humans between tasks. With stacks, it can maintain small review boundaries while continuing autonomously.

GitHub explicitly associates stacked PRs with higher-volume development and AI-assisted coding workflows. ([GitHub Docs][2])

---

# 3. What stacked PRs do not solve

Stacked PRs are a **linear dependency model**, not a universal dependency graph.

They do not naturally represent this:

```text
        PR B
       /    \
PR A          PR D
       \    /
        PR C
```

That is a DAG, not a stack.

They also do not solve:

* Cross-repository atomic changes.
* Independent changes that happen to be authored together.
* Semantic merge conflicts.
* Poor review discipline.
* Excessive CI cost.
* Long-lived branch divergence.
* Release-train coordination across many unrelated stacks.
* The need for feature flags when partially landed work must remain inactive.

GitHub’s current implementation is restricted to PRs in the same repository, which keeps the public model linear and avoids cross-repository branch, permission, and object-storage complications. ([GitHub Docs][2])

A useful rule is:

> Stack changes that must land in a specific linear order. Do not stack changes merely because one developer authored them consecutively.

---

# 4. Manual chained PRs versus a first-class stack

Developers have manually created stacked PRs for years by pointing each PR at the branch below it. That supplies only part of the system.

| Capability                          |  Manual branch chain | First-class stack |
| ----------------------------------- | -------------------: | ----------------: |
| Small per-layer diff                |                  Yes |               Yes |
| Explicit stack identity             |                   No |               Yes |
| Durable ordering                    |             Informal |          Enforced |
| Trunk policy applied to every layer |           Usually no |               Yes |
| Stack-aware CI metadata             |                   No |               Yes |
| Cascading rebase                    | Manual/tool-specific |        Integrated |
| Merge contiguous prefix             |     Multiple actions |     One operation |
| Merge-queue ordering                |              Unaware |       Stack-aware |
| Conflict recovery state             |               Ad hoc | Durable operation |
| Stack lifecycle/webhooks            |                   No |               Yes |
| Concurrency control                 |                   No |               Yes |

A branch chain answers:

> “What commit is this branch based on?”

A stack object answers:

> “Which PRs constitute one ordered unit of dependent work, what trunk do they ultimately target, what policy applies to them, and what operations may be performed across the group?”

That is why a serious implementation needs a server-side stack object.

---

# 5. How GitHub implemented stacked PRs

GitHub’s exact internal service architecture is not publicly documented. However, its public APIs, documentation, UI behavior, and open-source CLI reveal the external data model and much of the operational design.

## 5.1 Ordinary Git branches remain the storage model

GitHub did not introduce a new Git object type.

A stack still consists of:

* ordinary commits,
* ordinary branch refs,
* ordinary pull requests,
* ordinary base/head branch relationships.

The additional stack is collaboration metadata that links and orders those PRs. This is evident from GitHub’s stack API and from `gh-stack`, which creates or updates regular branches and PRs before creating or extending the server-side stack. ([GitHub Docs][5])

That is a good compatibility decision. Existing Git clients, fetches, branch protections, commit pages, and PR machinery continue to work.

## 5.2 GitHub has a first-class server-side stack object

GitHub’s REST representation includes concepts such as:

* stack ID,
* repository-scoped stack number,
* ultimate base ref,
* ordered pull requests,
* open/completed state,
* timestamps.

The creation API receives PR numbers ordered from bottom to top and validates that each PR’s base branch matches the preceding PR’s head branch. GitHub also exposes an operation that appends a PR to the top of an existing stack and returns a conflict response if a concurrent modification prevents the update. ([GitHub Docs][5])

Its GraphQL model exposes a `PullRequestStack` and ordered `PullRequestStackEntry` objects. Each entry has a one-based position and links to a PR. ([GitHub Docs][6])

A likely normalized representation is therefore approximately:

```text
pull_request_stacks
  id
  repository_id
  number
  base_ref
  state

pull_request_stack_entries
  id
  stack_id
  pull_request_id
  position
```

That table design is an inference, not a claim about GitHub’s private schema. But it closely matches the public object model.

## 5.3 The stack is durable rather than inferred on every request

GitHub could theoretically inspect PR bases and reconstruct branch chains dynamically. It instead provides APIs for explicitly creating, extending, and dissolving stacks.

That matters because branch topology alone is ambiguous.

For example:

* A developer may temporarily base one feature branch on another without intending a stack.
* A PR could be retargeted accidentally.
* Closed and merged PRs complicate inference.
* A branch could appear in several possible chains.
* Operations need a stable ID and optimistic-concurrency boundary.
* Webhooks and audit logs need an identifiable object.

The Git graph should be treated as a structural invariant of the stack, not as its sole identity.

## 5.4 The local CLI tracks more than branch names

GitHub’s `gh-stack` code maintains local metadata and records, for each stacked branch, both its current head and a base commit boundary. The project’s source describes that base as the parent branch’s head SHA at the last synchronization or rebase, used to identify the commits unique to the layer. ([GitHub][7])

This is one of the most important implementation details in the entire system.

Consider:

```text
A---B---C

main = A
PR 1 head = B
PR 2 head = C
```

Now PR 1 is squash-merged, producing commit `S`:

```text
A---S              main

A---B---C          old feature history
```

To restack PR 2, the system must replay only the work after `B`:

```bash
git rebase --onto S B C
```

It must **not** replay everything after `A`, because that would reapply PR 1’s changes on top of the squashed version.

The old boundary SHA `B` tells the system where PR 2’s unique layer begins.

Branch names are insufficient because `feature/schema` may have moved, been deleted, or been replaced by a squash commit. A robust stack implementation must retain commit boundaries as immutable OIDs.

## 5.5 GitHub uses waterfall rebasing

A cascade rebase proceeds from the trunk upward:

```text
rebase layer 1 onto current trunk
rebase layer 2 onto new layer 1
rebase layer 3 onto new layer 2
…
```

If a conflict occurs, the operation pauses at the affected layer. GitHub’s CLI supports continuing or aborting an interrupted stack rebase and persists the necessary local state. ([GitHub][8])

The direction matters. Rebasing the top first would use parent commits that are about to be replaced.

## 5.6 Pushes use optimistic ref safety

GitHub’s CLI pushes active branches with per-ref `--force-with-lease`, protecting against overwriting a remote branch that changed unexpectedly.

The CLI documentation notes that its multi-branch push is not completely atomic: one branch update can succeed while another fails. It therefore needs reconciliation and retry behavior. ([GitHub][8])

A GitHub clone that owns its Git backend can provide stronger server-side semantics through a batch compare-and-swap ref API.

## 5.7 GitHub virtualizes the policy base

GitHub distinguishes the immediate PR base from the stack’s trunk base.

For all stacked layers, GitHub evaluates:

* branch protection,
* required checks,
* workflow applicability,
* required reviews,
* CODEOWNERS,

against the stack’s ultimate target branch. In particular, changing a CODEOWNERS file in a lower PR does not alter ownership requirements for upper PRs; the policy definition is taken from the stack base. ([GitHub Docs][3])

This is both a security requirement and a usability requirement.

## 5.8 GitHub includes stack context in CI events

GitHub’s pull-request event payload exposes stack metadata including:

* stack number,
* stack size,
* the PR’s position,
* the effective base ref and SHA.

That lets CI systems make stack-aware decisions. ([GitHub Docs][3])

For example:

```yaml
if: github.event.pull_request.stack.position ==
    github.event.pull_request.stack.size
```

could run a particularly expensive end-to-end suite only for the top layer, while cheaper required checks still run for every layer.

The downside is CI multiplication. A ten-layer stack may trigger ten sets of workflows, and changing the bottom can invalidate all ten.

## 5.9 GitHub supports contiguous-prefix merges

Suppose the stack is:

```text
PR 1
PR 2
PR 3
PR 4
```

Permitted operations include:

```text
merge PR 1
merge PRs 1–2
merge PRs 1–3
merge PRs 1–4
```

But not:

```text
merge only PR 2
merge PRs 2–3 while PR 1 remains open
```

All selected layers and all layers below the selected one must satisfy their requirements. ([GitHub Docs][4])

This follows directly from the dependency model: a layer cannot land without its prerequisites.

## 5.10 Stack merging is asynchronous

GitHub exposes an asynchronous merge endpoint for stacked PRs. The request can include:

* expected head SHA,
* merge method,
* direct merge versus merge queue,
* and the selected PR.

The server returns an operation UUID and an HTTP `202 Accepted`; the client polls for the result. GitHub also returns conflicts for an already-running incompatible operation. ([GitHub Docs][9])

This is the correct architectural model. A stack merge may need to:

* validate several PRs,
* query checks and reviews,
* create multiple commits,
* interact with the merge queue,
* update several branches,
* close several PRs,
* generate events,
* and restack remaining upper branches.

That should not be implemented as a fragile synchronous HTTP request.

## 5.11 GitHub supports the normal merge methods

GitHub documents stack behavior for:

* **Merge commit:** one merge commit for the selected group, preserving the commits in the selected branch history.
* **Squash:** one squashed commit per PR.
* **Rebase:** commits from each PR are replayed in stack order.

For merge-queue operation, stack ordering is preserved, and ejecting a lower member necessarily affects the members above it. ([GitHub Docs][10])

## 5.12 “Atomic” has an important caveat

GitHub describes stack merging as one coordinated operation, but its troubleshooting documentation acknowledges that an unexpected failure may occur after some lower PRs have already landed. In that case, the landed PRs remain merged and the failed and upper PRs remain open. ([GitHub Docs][11])

Therefore, “atomic” should be understood as:

* one user-visible operation,
* one preflight,
* one ordered orchestration,

not necessarily a mathematically strict all-or-nothing transaction spanning Git refs, SQL rows, CI, queues, and webhooks.

A new implementation can make Git-ref movement more atomic than this, but it still needs durable recovery across storage systems.

## 5.13 Current limitations

GitHub’s documented preview currently has several meaningful constraints:

* All PRs must be in the same repository.
* GitHub Desktop does not provide stack management.
* Auto-merge is not supported for stacked PRs.
* Merge queue is supported.
* REST and webhooks support stack operations; GraphQL exposes a read model.
* The feature remains subject to change during public preview. ([GitHub Docs][2])

---

# 6. Architecture for implementing stacked PRs in a GitHub clone

A clean implementation should separate the system into seven responsibilities:

```text
┌───────────────────────────────────────────────────────────────┐
│ Web UI / CLI / API                                            │
├──────────────────────────────┬────────────────────────────────┤
│ Pull Request Service         │ Stack Service                  │
│ reviews, comments, diffs     │ membership, ordering, state    │
├──────────────────────────────┼────────────────────────────────┤
│ Policy + CI Planner          │ Operation Orchestrator         │
│ effective base, checks       │ rebase, merge, recovery        │
├──────────────────────────────┴────────────────────────────────┤
│ Merge Queue                                                   │
├───────────────────────────────────────────────────────────────┤
│ Git Data Plane                                                │
│ objects, refs, diffs, merge/replay, CAS ref transactions      │
├───────────────────────────────────────────────────────────────┤
│ Metadata DB + Outbox + Workers                                │
└───────────────────────────────────────────────────────────────┘
```

In a forge where Git object storage is already separated from collaboration metadata, the stack should live in the **collaboration database and orchestration layer**.

The Git data plane should not know what a “pull request stack” is. It should expose generic primitives:

```text
ResolveRef
ReadCommitGraph
IsAncestor
ComputeDiff
MergeTrees
ReplayCommits
CreateCommit
BatchUpdateRefsCAS
PinObjects
```

The stack service composes those primitives.

That separation keeps Git storage reusable for:

* ordinary PRs,
* merge queues,
* coding-agent workspaces,
* patch previews,
* release branches,
* mirrors,
* and ephemeral environments.

---

# 7. Recommended data model

## 7.1 Stack records

```sql
CREATE TABLE pull_request_stacks (
    id                  UUID PRIMARY KEY,
    repository_id       UUID NOT NULL,
    number              BIGINT NOT NULL,
    trunk_ref_name      TEXT NOT NULL,
    state               TEXT NOT NULL,
    version             BIGINT NOT NULL DEFAULT 1,
    created_by          UUID NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL,
    updated_at          TIMESTAMPTZ NOT NULL,

    UNIQUE (repository_id, number)
);
```

Suggested states:

```text
OPEN
COMPLETED
DISSOLVED
```

Avoid encoding transient operational states directly on the stack. Put those in an operation table.

## 7.2 Ordered entries

```sql
CREATE TABLE pull_request_stack_entries (
    id                  UUID PRIMARY KEY,
    stack_id            UUID NOT NULL,
    pull_request_id     UUID NOT NULL,
    position            INTEGER NOT NULL,

    boundary_oid        BYTEA NOT NULL,
    observed_head_oid   BYTEA NOT NULL,

    removed_at          TIMESTAMPTZ,

    UNIQUE (stack_id, position)
);
```

`boundary_oid` is the critical field.

For each layer:

```text
bottom entry boundary = trunk SHA at its last valid restack
upper entry boundary  = previous layer’s head SHA at its last valid restack
```

Use an opaque Git OID type or a representation capable of storing both SHA-1 and SHA-256 object IDs. Do not hard-code a 40-character SHA-1 schema.

Add a partial uniqueness constraint so a PR cannot be an active member of two stacks simultaneously.

## 7.3 Durable operations

```sql
CREATE TABLE stack_operations (
    id                      UUID PRIMARY KEY,
    stack_id                UUID NOT NULL,
    kind                    TEXT NOT NULL,
    state                   TEXT NOT NULL,
    target_position         INTEGER,
    expected_stack_version  BIGINT NOT NULL,
    idempotency_key         TEXT NOT NULL,

    request                 JSONB NOT NULL,
    snapshot                JSONB,
    planned_result          JSONB,
    error                   JSONB,

    created_at              TIMESTAMPTZ NOT NULL,
    started_at              TIMESTAMPTZ,
    completed_at            TIMESTAMPTZ,

    UNIQUE (stack_id, idempotency_key)
);
```

Operation kinds:

```text
CREATE
APPEND
RESTRUCTURE
REBASE
MERGE
QUEUE
UNSTACK
DISSOLVE
REPAIR
```

Operation states:

```text
PENDING
RUNNING
WAITING_FOR_CONFLICT_RESOLUTION
WAITING_FOR_CHECKS
SUCCEEDED
PARTIALLY_SUCCEEDED
FAILED
CANCELLED
```

For detailed recovery, add:

```sql
stack_operation_steps (
    operation_id,
    sequence,
    entry_id,
    action,
    state,
    old_oid,
    new_oid,
    error
);
```

## 7.4 Object retention

Every `boundary_oid` must remain reachable.

A commit that is no longer referenced by a public branch can eventually be garbage-collected. If that commit is the only record of a layer boundary, future restacking becomes unreliable.

Use either:

* hidden internal refs, such as `refs/internal/stacks/<stack-id>/<entry-id>`,
* object leases,
* or an explicit Git-object retention table understood by the garbage collector.

Do not advertise those internal refs to normal clients.

---

# 8. Structural invariants

Separate **structural validity** from **current mergeability**.

## 8.1 Hard structural invariants

A stack should require:

```text
All PRs belong to the same repository.
All entries are unique.
Positions are contiguous: 1…n.
The first PR targets the stack trunk.
Every later PR targets the preceding PR’s head branch.
No PR belongs to two active stacks.
No branch appears twice.
No cycle exists.
```

While a PR is stacked, generic “change base branch” operations should either:

* be routed through the stack service,
* or be rejected with an explanation.

Otherwise an ordinary PR update can silently corrupt the stack.

## 8.2 Dynamic validity

A stack can remain a recognized stack while temporarily needing a rebase.

For example:

```text
A---X                   main
 \
  B---C                 stack branches
```

The stack metadata remains valid, but `main`’s new commit `X` is not an ancestor of the bottom branch.

Represent that as:

```text
stack state: OPEN
health: NEEDS_REBASE
```

Other useful health states:

```text
HEALTHY
NEEDS_REBASE
CONFLICTED
MISSING_REF
HEAD_CHANGED
POLICY_BLOCKED
OPERATION_IN_PROGRESS
```

Do not dissolve the stack merely because its Git topology is temporarily stale.

## 8.3 Mergeability invariants

Before merging a selected prefix, require:

```text
current trunk tip is an ancestor of layer 1 head
layer 1 head is an ancestor of layer 2 head
…
selected layers form the lowest contiguous open prefix
all expected head SHAs still match
all required checks are current
all required approvals are current
no conflicting operation is active
```

For a simpler first version, prohibit merge commits inside individual layers when using the rebase merge method. Supporting arbitrary merge topologies complicates commit selection and replay semantics considerably.

---

# 9. Creating a stack

A creation operation should look like this:

```text
POST /repos/:owner/:repo/stacks
{
  "trunk_ref": "main",
  "pull_requests": [101, 102, 103],
  "expected_heads": {
    "101": "…",
    "102": "…",
    "103": "…"
  },
  "idempotency_key": "…"
}
```

Server algorithm:

```text
1. Begin metadata transaction.
2. Lock the repository’s relevant PR and stack rows.
3. Check repository and PR permissions.
4. Require every PR to be open and in the same repository.
5. Require no active membership in another stack.
6. Resolve all base and head refs from the Git service.
7. Validate the direct-base chain.
8. Snapshot current head OIDs.
9. Assign boundary OIDs.
10. Create stack and ordered entries.
11. Pin all boundary objects.
12. Increment stack version.
13. Write outbox events.
14. Commit metadata transaction.
15. Schedule policy and CI recalculation.
```

A useful UI may detect a potential manual chain and offer:

> “These three PRs form a branch chain. Convert them into a stack?”

But conversion should be explicit. Automatically treating every chain as a stack would produce surprising policy and merge behavior.

---

# 10. Computing the PR diff

GitHub PRs conventionally display a three-dot comparison: changes from the merge base of the base and head branches to the head. ([GitHub Docs][12])

Conceptually:

```bash
git diff base...head
```

or:

```text
M = mergeBase(baseHead, prHead)
diff(M, prHead)
```

For a healthy stacked layer:

```text
mergeBase(parentHead, childHead) = parentHead
```

so the PR displays only the child layer.

For the example:

```text
A---B---C---D
```

the reviews are:

```text
PR 1 diff: A → B
PR 2 diff: B → C
PR 3 diff: C → D
```

The system should offer two views:

### Layer diff

```text
direct base → this PR head
```

This is the primary review view.

### Cumulative preview

```text
trunk → this PR head
```

This answers:

> “What will the repository look like if everything through this point lands?”

If a lower branch is rewritten and an upper branch has not yet been restacked, the merge base may move backward and the layer diff may suddenly include lower-layer changes. The UI should not present that enormous diff without explanation. It should show:

```text
This layer is based on an outdated parent commit.
Rebase the stack to restore the intended review boundary.
```

---

# 11. Policy and CI architecture

## 11.1 Store both direct and effective bases

For each PR evaluation:

```text
direct_base_ref    = immediate parent branch
effective_base_ref = stack trunk branch
```

Use `direct_base_ref` for:

* diff presentation,
* branch ancestry,
* layer boundary,
* base branch display.

Use `effective_base_ref` for:

* branch protection,
* rulesets,
* required workflows,
* allowed merge methods,
* required approvals,
* CODEOWNERS configuration,
* merge-queue configuration.

This should be a first-class field in the policy request rather than a collection of stack-specific exceptions scattered throughout the codebase.

For example:

```json
{
  "pull_request_id": "pr_102",
  "head_oid": "C",
  "direct_base": {
    "ref": "feature/schema",
    "oid": "B"
  },
  "effective_base": {
    "ref": "main",
    "oid": "A"
  },
  "stack": {
    "id": "stack_17",
    "position": 2,
    "size": 3
  }
}
```

## 11.2 Evaluate configuration from the trunk tree

Suppose PR 1 changes:

```text
.github/CODEOWNERS
.github/workflows/test.yml
```

PR 2 must not immediately receive weaker rules based on the unmerged configuration.

Resolve policy configuration from:

```text
effective_base_oid
```

not from the direct parent branch’s tree.

After the lower change lands in trunk, later evaluations may legitimately use the new policy.

## 11.3 What code state should CI test?

For a healthy stack, each layer’s head already contains every lower layer:

```text
H₁ = trunk + layer 1
H₂ = trunk + layer 1 + layer 2
H₃ = trunk + layer 1 + layer 2 + layer 3
```

Therefore, testing `H₂` validates the cumulative repository state through layer 2.

A robust CI identity is:

```text
(pr_id, head_oid, effective_base_oid, workflow_definition_oid)
```

Do not key required-check validity only by `head_oid`.

If trunk advances, the same PR head may no longer represent a current, mergeable result. Changing the effective base must invalidate or re-evaluate relevant checks.

## 11.4 Synthetic test refs

For stacks that are not currently rebased, or for merge-queue speculation, generate a private test commit/ref:

```text
refs/internal/checks/<run-id>
```

Its tree should represent:

```text
current trunk + all stack layers through this PR
```

The CI system tests that immutable synthetic SHA.

This gives reproducible results and avoids running CI against a moving branch name.

## 11.5 Managing CI explosion

A stack with `n` layers can cause approximately `n` evaluations whenever the bottom changes.

Provide explicit workflow policies such as:

```text
run_on: every_layer
run_on: top_layer_only
run_on: bottom_layer_only
run_on: changed_paths
run_on: merge_group_only
```

A sensible pattern is:

```text
Every layer:
  compile
  type-check
  unit tests
  policy checks

Top layer or merge group:
  full integration suite
  browser tests
  expensive performance tests
```

However, never silently skip a check that branch protection declares required. Optimization must be part of the repository’s declared policy.

---

# 12. Cascading rebase implementation

A stack rebase is the most difficult day-to-day operation.

## 12.1 Why the boundary OID is required

Suppose:

```text
A---B₁---B₂---C₁---C₂
```

where:

```text
PR 1 unique commits: B₁, B₂
PR 2 unique commits: C₁, C₂
```

The stored entry boundaries are:

```text
PR 1 boundary = A
PR 2 boundary = B₂
```

If `main` advances to `X`, the desired result is:

```text
A---X---B₁'---B₂'---C₁'---C₂'
```

The conceptual commands are:

```bash
git rebase --onto X   A   B₂
git rebase --onto B₂' B₂  C₂
```

`git rebase --onto` is precisely the Git operation for selecting commits after an old boundary and replaying them onto a new parent. ([Git SCM][13])

## 12.2 Server-side algorithm

```text
function rebaseStack(stackId, expectedVersion):
    lock stack
    snapshot trunk and every branch head

    newParent = currentTrunkHead

    for entry in bottomToTop:
        oldBoundary = entry.boundaryOid
        oldHead = entry.observedHeadOid

        verify live branch still equals oldHead

        uniqueCommits =
            commits reachable from oldHead
            but not reachable from oldBoundary

        result =
            replay uniqueCommits onto newParent

        if result has conflicts:
            persist conflict workspace and operation state
            return WAITING_FOR_CONFLICT_RESOLUTION

        plannedRefUpdates.append(
            branchRef,
            expectedOld = oldHead,
            new = result.newHead
        )

        plannedEntryUpdates.append(
            boundaryOid = newParent,
            observedHeadOid = result.newHead
        )

        newParent = result.newHead

    atomically compare-and-swap all branch refs
    update metadata
    emit PR synchronize and stack rebase events
```

The system should create all new commits under temporary internal refs before touching public branch refs.

## 12.3 Conflict handling

For each conflicting layer, persist:

* old boundary,
* old head,
* proposed new parent,
* commit currently being replayed,
* index/tree conflict state,
* conflict paths,
* prior successful step results,
* expected branch heads.

Offer two resolution modes:

### Local continuation

The CLI fetches the operation’s state, places the repository into a rebase, and later uploads the resolved commits.

### Hosted continuation

The forge exposes a temporary workspace or editor, applies conflict resolutions, and resumes the worker.

After resolution, the server must still verify that no branch changed in the meantime.

## 12.4 Ref transaction

Standard Git supports compare-and-swap updates by supplying the expected old object ID and can batch updates through `git update-ref --stdin`. Git documents transactional `start`, `prepare`, and `commit` phases for grouped ref changes. ([Git SCM][14])

A custom Git service should expose something like:

```protobuf
rpc BatchUpdateRefs(BatchUpdateRefsRequest)
    returns (BatchUpdateRefsResponse);

message RefUpdate {
  string ref_name = 1;
  GitOid expected_old_oid = 2;
  GitOid new_oid = 3;
}
```

The entire update fails when any expected old OID does not match.

This is stronger than independently running several force pushes.

## 12.5 Commit signatures

A server-side rebase necessarily creates new commits.

It cannot preserve the original cryptographic signatures because:

* parent OIDs change,
* commit OIDs change,
* the original author’s private key is unavailable.

Possible policies are:

* mark server-restacked commits as unsigned,
* sign them with a forge service identity,
* or require a local rebase when user signatures are mandatory.

GitHub warns that server-generated rebase commits may be unsigned, while locally generated commits follow the user’s Git signing configuration. ([GitHub Docs][11])

---

# 13. Merging a stack

## 13.1 API shape

```text
PUT /repos/:owner/:repo/pulls/:number/merge-async
```

Request:

```json
{
  "expected_stack_version": 27,
  "expected_heads": {
    "101": "…",
    "102": "…",
    "103": "…"
  },
  "merge_method": "squash",
  "merge_action": "direct_merge",
  "idempotency_key": "client-generated-uuid"
}
```

Response:

```json
{
  "operation_id": "…",
  "state": "pending"
}
```

The selected PR determines the target prefix.

Selecting PR 103 means:

```text
merge all open entries from the bottom through PR 103
```

## 13.2 Preflight

Before creating any public ref update:

```text
1. Lock stack operation slot.
2. Snapshot stack version, trunk SHA, and all branch heads.
3. Verify selected entries are a contiguous lowest prefix.
4. Verify the current ancestry chain.
5. Verify expected head SHAs.
6. Verify all selected PRs are open and mergeable.
7. Evaluate approvals, CODEOWNERS, rules, and checks.
8. Verify actor permission.
9. Verify merge method is permitted.
10. Ensure no queue/rebase/merge operation conflicts.
```

Do as much work as possible before modifying state.

## 13.3 Merge-commit method

Suppose the selected prefix ends at head `Hₖ`.

Because the stack is required to be fully linear and based on the current trunk, `Hₖ` already contains the cumulative code for every selected PR.

Create one merge commit:

```text
parents:
  current trunk
  Hₖ

tree:
  tree(Hₖ)
```

The result is:

```text
         B---C---D
        /         \
A------             M
```

where `M` is the group merge commit.

This preserves all commits from all selected layers while presenting one merge event on the trunk.

## 13.4 Squash method

For squash merging, create one commit per PR, not one commit for the entire stack:

```text
A---S₁---S₂---S₃
```

where:

```text
tree(S₁) = tree(H₁)
tree(S₂) = tree(H₂)
tree(S₃) = tree(H₃)
```

and each commit’s parent is the previous generated squash commit.

The diff represented by each commit is naturally the corresponding layer:

```text
diff(A, S₁)   = layer 1
diff(S₁, S₂)  = layer 2
diff(S₂, S₃)  = layer 3
```

This avoids accidentally combining all PRs into a single squash commit and preserves one trunk-level commit per reviewed unit.

## 13.5 Rebase method

For the rebase method, replay the unique commits of every selected layer in order:

```text
layer 1 commits
then layer 2 commits
then layer 3 commits
```

The final tree must equal the selected top branch’s tree.

For a fully linear, current stack, the operation is deterministic. The server can reproduce each non-merge commit with:

* the same tree,
* the same author information,
* the same message,
* a new parent,
* new committer metadata.

If arbitrary merge commits are supported inside a layer, the system needs an explicit policy such as:

* flatten them,
* preserve merges,
* or reject the merge method.

Do not leave this undefined.

## 13.6 Restacking the remaining upper layers

Suppose a four-PR stack merges only PRs 1–2:

```text
PR 1: merged
PR 2: merged
PR 3: remains open
PR 4: remains open
```

After the operation:

```text
PR 3 should target trunk
PR 4 should still target PR 3
```

PR 3’s commits must be replayed onto the newly created trunk result using its old boundary SHA. PR 4 must then be replayed onto the new PR 3 head.

This restacking should be included in the same planned operation when possible.

Do not delete the merged lower branches until upper-layer restacking has succeeded or the retained boundary OIDs have been safely pinned.

## 13.7 Building Git objects before updating refs

Create all prospective commits and trees first.

Git’s modern `merge-tree --write-tree` can compute a merge result without modifying a working tree or index, which is useful for server-side planning. ([Git SCM][15])

The general transaction is:

```text
Phase A: Create unreachable candidate objects.
Phase B: Validate all policies and expected refs.
Phase C: Batch-CAS public refs.
Phase D: Finalize SQL metadata and emit events.
```

If Phase B fails, candidate objects remain unreachable and can later be garbage-collected.

## 13.8 Git and SQL cannot trivially share one transaction

Even with a fully atomic Git ref transaction, you still have two durable systems:

```text
Git ref store
SQL metadata store
```

A crash can occur after the Git refs move but before SQL marks the PRs merged.

Use:

* durable operation records,
* an idempotency key,
* snapshots of old and intended refs,
* a transactional outbox,
* and a reconciliation worker.

For example:

```text
operation planned
    ↓
Git refs updated
    ↓ crash
SQL still says RUNNING
    ↓
reconciler observes refs equal planned result
    ↓
finalizes PR and stack metadata
```

Do not try to hide this problem with a large in-process mutex.

---

# 14. Merge-queue integration

Treat the selected stack prefix as one **logical queue item** with ordered internal members:

```text
QueueItem {
  stack_id
  selected_entries: [P₁, P₂, P₃]
  expected_heads
  effective_base_oid
}
```

The speculative merge group should apply:

```text
current queue base
then P₁
then P₂
then P₃
```

The queue may reorder independent queue items, but it must never reorder entries within a stack.

If a lower stacked PR is ejected because of a failure, all selected entries above it must also leave that speculative group because their prerequisite is no longer present. GitHub uses this kind of stack-aware queue behavior and documents special handling for stack grouping and ejection. ([GitHub Docs][4])

Queue validation should be keyed to:

```text
queue base SHA
stack version
every selected head SHA
policy version
```

Any change invalidates the speculative result.

---

# 15. API design

A practical REST surface could be:

```text
GET    /repos/:owner/:repo/stacks
POST   /repos/:owner/:repo/stacks
GET    /repos/:owner/:repo/stacks/:number

POST   /repos/:owner/:repo/stacks/:number/append
POST   /repos/:owner/:repo/stacks/:number/restructure
POST   /repos/:owner/:repo/stacks/:number/rebase
POST   /repos/:owner/:repo/stacks/:number/unstack
POST   /repos/:owner/:repo/stacks/:number/dissolve

PUT    /repos/:owner/:repo/pulls/:number/merge-async
GET    /repos/:owner/:repo/stack-operations/:operation_id
POST   /repos/:owner/:repo/stack-operations/:operation_id/continue
POST   /repos/:owner/:repo/stack-operations/:operation_id/abort
```

Every mutating request should support:

```text
Idempotency-Key
If-Match or expected_stack_version
expected head OIDs
```

An individual PR representation should include:

```json
{
  "stack": {
    "id": "stack_17",
    "number": 17,
    "position": 2,
    "size": 4,
    "trunk_ref": "main",
    "trunk_oid": "…",
    "health": "healthy"
  }
}
```

GraphQL is particularly useful for reading the stack map:

```graphql
type PullRequestStack {
  id: ID!
  number: Int!
  trunkRefName: String!
  state: PullRequestStackState!
  health: PullRequestStackHealth!
  version: Int!
  entries: [PullRequestStackEntry!]!
}

type PullRequestStackEntry {
  id: ID!
  position: Int!
  pullRequest: PullRequest!
  boundaryOid: GitObjectID!
  observedHeadOid: GitObjectID!
}
```

It is reasonable to keep complex operations REST/job-based initially while exposing the read model through GraphQL.

---

# 16. Events and webhooks

Recommended events:

```text
pull_request_stack.created
pull_request_stack.appended
pull_request_stack.restructured
pull_request_stack.dissolved

pull_request.stacked
pull_request.unstacked
pull_request.stack_position_changed

pull_request_stack.rebase_started
pull_request_stack.rebase_conflicted
pull_request_stack.rebase_completed

pull_request_stack.merge_started
pull_request_stack.merge_queued
pull_request_stack.merge_partially_completed
pull_request_stack.merge_completed
pull_request_stack.merge_failed
```

Every event should include:

```text
stack ID and number
operation ID
stack version
actor
old and new ordering
trunk ref and SHA
affected PR IDs
old and new head SHAs
timestamp
```

Deliver through a transactional outbox rather than publishing directly from the request handler. Consumers must deduplicate by event ID.

For ordinary `pull_request` synchronization events, include stack context:

```json
{
  "stack": {
    "number": 17,
    "position": 2,
    "size": 4,
    "base": {
      "ref": "main",
      "sha": "…"
    }
  }
}
```

That mirrors the useful part of GitHub’s CI event model. ([GitHub Docs][3])

---

# 17. Concurrency model

Stack operations touch several mutable objects:

* stack ordering,
* PR base branches,
* branch refs,
* trunk ref,
* approvals,
* checks,
* merge queue entries.

Use several layers of concurrency protection.

## Database lock

Permit only one structural or Git-mutating operation per stack at a time.

```text
SELECT ... FOR UPDATE
```

or use a stack-scoped advisory lock.

## Optimistic stack version

Every structural mutation increments:

```text
stack.version
```

Clients provide the version they observed. A mismatch returns `409 Conflict`.

## Git compare-and-swap

Every branch update includes:

```text
expected_old_oid
new_oid
```

A push made after the operation snapshot causes the transaction to fail rather than overwrite the user’s work.

## Operation idempotency

Retrying the same request must return the same operation rather than enqueueing a second merge or rebase.

## Worker lease

Long-running operations need:

```text
lease_owner
lease_expires_at
heartbeat_at
```

A worker that dies can be replaced safely.

## Reconciliation

Periodically inspect incomplete operations and compare:

```text
actual refs
planned refs
metadata state
```

Then complete, retry, or mark the operation partial.

---

# 18. Permissions and security

A stack adds several operations more powerful than an ordinary PR edit.

## Creating or restructuring a stack

Require permission to modify every affected PR’s base relationship.

## Server-side rebase

Require permission to rewrite every affected branch ref.

Do not allow a user with permission over only their own upper branch to force-update another author’s lower branch.

## Stack merge

Require normal trunk merge permission and satisfaction of all effective-base policies.

## Forks

Avoid cross-fork stacks in the first version.

They introduce:

* different repository object stores,
* different ref owners,
* token permission boundaries,
* workflow-secret restrictions,
* potentially untrusted code,
* inability to atomically update refs,
* branch deletion and retention complications.

GitHub’s same-repository restriction is operationally sensible, although GitHub has not publicly stated that these are its exact internal reasons. ([GitHub Docs][2])

## Auditability

Record:

```text
actor
operation
old and new stack ordering
old and new refs
approvals/checks snapshot
merge method
queue decision
conflict resolutions
service identity that created commits
```

A stack merge should be reconstructable after the fact.

---

# 19. User interface design

The PR page should show a stack map:

```text
✓ #101 Add schema                 merged
✓ #102 Add API                    approved
● #103 Add UI                     you are here
○ #104 Add integration tests      checks running
```

Each entry should display:

* position,
* direct base,
* head branch,
* approval state,
* required-check state,
* conflict/rebase state,
* whether changing it affects upper entries.

Important actions:

```text
Review this layer
Preview cumulative changes
Move up/down stack
Rebase stack
Update entire stack
Merge through this PR
Add PR to top
Remove from stack
Repair stack
```

A merge button on PR 103 should say:

```text
Merge 3 pull requests
```

not merely:

```text
Merge pull request
```

Before rewriting a lower branch, show impact:

```text
This will rewrite 4 branches above this layer,
invalidate 5 approvals, and rerun 23 required checks.
```

That is much more useful than presenting cascading rebase as a harmless implementation detail.

---

# 20. CLI design

A minimal CLI could expose:

```bash
forge stack init
forge stack add
forge stack submit
forge stack view
forge stack up
forge stack down
forge stack checkout
forge stack rebase
forge stack continue
forge stack abort
forge stack push
forge stack sync
forge stack merge
forge stack remove
```

A local metadata cache might contain:

```json
{
  "stack_id": "…",
  "stack_version": 27,
  "trunk": {
    "ref": "main",
    "oid": "…"
  },
  "branches": [
    {
      "name": "feature/schema",
      "pr": 101,
      "boundary_oid": "…",
      "head_oid": "…"
    }
  ]
}
```

But the server must remain authoritative.

The local file is useful for:

* fast navigation,
* identifying layer commit ranges,
* preparing offline commits,
* recovering interrupted local rebases.

It must not be trusted to override current server membership or remote ref state.

---

# 21. Important edge cases

## Lower branch force-pushed

Mark every upper entry as needing restack. Do not assume the old boundary remains present unless it is pinned.

## Trunk advances

Mark the entire stack as needing rebase or enqueue a safe automatic rebase, depending on policy.

## Middle PR closes

Upper layers remain structurally dependent on missing work. Mark them blocked. GitHub similarly treats closing or invalidating a middle member as preventing the entries above it from landing normally. ([GitHub Docs][11])

## Branch deleted

Keep the stack object and show `MISSING_REF`. Offer restoration from the observed head OID when permission allows.

## Generic PR base edit

Reject or convert into an explicit restructure operation.

## PR added to two stacks

Reject. Linear stack membership should be unique.

## A lower PR is squash-merged outside the stack operation

Use the stored boundary and merged result to restack upper layers rather than attempting to rediscover commit ranges from branch names.

## A boundary commit becomes unreachable

Prevent this through hidden refs or object leases.

## User pushes during rebase

The final CAS fails. Preserve the user’s branch and mark the operation stale.

## Review comments after rebase

Map comments by blob/path/context where possible. Mark comments outdated when the relevant patch no longer exists. Apply the repository’s normal approval-dismissal policy to rewritten heads.

## Duplicate or cherry-picked commits

Do not use patch-ID heuristics as the primary definition of a layer. Stored boundary OIDs and ancestry are more deterministic.

## Merge commits within a layer

Define behavior explicitly. A first version can reject them for stack rebase operations rather than producing surprising flattened histories.

## Huge stacks

Set practical limits for:

* number of layers,
* queue group size,
* rebase operation duration,
* webhook payload size,
* simultaneous CI runs.

GitHub’s merge-queue documentation includes special stack group-sizing behavior, illustrating that stack size becomes an operational concern rather than merely a UI concern. ([GitHub Docs][4])

## Partial operation failure

Represent it directly:

```text
PARTIALLY_SUCCEEDED
```

Include which PRs landed and which did not. Never report a generic failure after some trunk refs have already moved.

---

# 22. Testing strategy

Stacked PRs need substantially more than ordinary unit tests.

## Property tests

Generate random linear commit histories and verify:

```text
each layer diff equals its unique change
cascade rebase preserves final tree
squash produces one commit per layer
group merge final tree equals selected top tree
remaining upper layers retain their unique changes
```

## Operation matrix

Test:

```text
merge / squash / rebase
× full stack / partial prefix
× trunk unchanged / trunk advanced
× no upper layers / remaining upper layers
× local push / concurrent push
× success / conflict / worker crash
```

## Fault injection

Crash after every durable step:

```text
after operation creation
after candidate object creation
after ref prepare
after ref commit
after PR metadata update
after stack update
before outbox publication
```

Verify that reconciliation reaches a correct state.

## Policy tests

Verify:

* trunk workflows run on intermediate layers,
* CODEOWNERS comes from trunk,
* lower unmerged policy changes do not weaken upper requirements,
* stale checks are invalidated when trunk changes,
* approvals are dismissed according to policy after rewrites.

## Queue tests

Verify:

* stack members retain order,
* independent queue items can move around the stack,
* lower-member ejection ejects dependent upper members,
* a changed head invalidates the entire corresponding group.

## Garbage-collection tests

Delete public refs, run aggressive object GC, and verify pinned boundary commits remain available until the stack no longer needs them.

## Performance tests

Benchmark:

* stack views at 10, 50, and 100 layers,
* ancestry validation,
* per-layer diff calculation,
* cascading rebase,
* batch ref updates,
* event fan-out,
* CI invalidation.

---

# 23. Sensible implementation roadmap

## Phase 1: First-class metadata and review UX

Build:

* stack and entry records,
* explicit create/append/remove,
* stack map,
* structural validation,
* ordinary per-layer PR diffs,
* bottom-only merge.

This already gives users a legible stack without attempting dangerous history rewriting.

## Phase 2: Effective-base policy and CI

Add:

* direct versus effective base,
* stack metadata in events,
* trunk-based branch protection,
* CODEOWNERS evaluation,
* current-base-aware check identities.

Do this before presenting stacks as production-safe.

## Phase 3: Rebase engine

Add:

* boundary OID storage,
* object pinning,
* waterfall replay,
* temporary operation refs,
* conflict pause/continue/abort,
* compare-and-swap branch updates,
* local CLI support.

Boundary OIDs should actually be stored from Phase 1, even if the rebase engine comes later.

## Phase 4: Multi-PR merge

Add:

* asynchronous merge operations,
* contiguous-prefix validation,
* merge/squash/rebase methods,
* upper-layer restacking,
* idempotency,
* reconciliation,
* partial-failure reporting.

## Phase 5: Merge queue

Add:

* logical stack queue items,
* speculative group SHAs,
* in-stack ordering,
* cascading ejection,
* group-size limits.

## Phase 6: Advanced editing

Add:

* insert into middle,
* split a layer,
* combine adjacent layers,
* reorder layers,
* move a suffix to another stack,
* agent-driven automatic stack construction.

These are powerful but substantially harder because they require transplanting commit ranges and preserving review attribution.

---

# 24. Recommended design decisions

For a new GitHub clone, I would make these choices:

1. **Use ordinary branches and PRs.**
   Make the stack an additional collaboration object, not a new Git primitive.

2. **Persist the stack explicitly.**
   Do not infer it from branch relationships on every request.

3. **Support only linear stacks initially.**
   Build a separate dependency-graph feature later rather than corrupting stack semantics.

4. **Separate direct base from effective base everywhere.**
   This prevents both CI confusion and policy bypass.

5. **Store and pin immutable boundary OIDs from day one.**
   This is what makes squash merges, rebases, and upper-layer restacking reliable.

6. **Make the server authoritative.**
   Local CLI metadata is a cache and editing aid.

7. **Implement every mutation as a durable operation.**
   Use operation IDs, idempotency, leases, snapshots, and recovery.

8. **Use batch compare-and-swap ref updates.**
   Never rewrite a stack through a sequence of unconditional force pushes.

9. **Treat rebase and conflict recovery as core functionality.**
   A stack without reliable maintenance becomes unusable as soon as the bottom changes.

10. **Make stack-wide effects visible.**
    Show when an action will rewrite upper branches, invalidate approvals, or rerun CI.

11. **Keep forks and cross-repository stacks out of the first version.**
    They multiply permissions, security, and transaction complexity.

12. **Design the merge queue with stacks in mind from the beginning.**
    Retrofitting grouped dependency ordering into a queue later is painful.

---

# Bottom line

A stacked PR system has three layers:

```text
1. Git topology
   Ordinary branches form a linear commit chain.

2. Collaboration model
   A durable stack object orders ordinary PRs and assigns an ultimate trunk.

3. Orchestration
   Policy, CI, rebasing, merging, queueing, recovery, and events operate
   across the ordered group.
```

The Git topology is the easy part. Developers have manually chained branches for years.

The real product is the orchestration layer:

* preserving each layer’s review boundary,
* evaluating every layer under trunk policy,
* rebasing from the bottom upward,
* retaining old boundary SHAs,
* atomically or recoverably updating several refs,
* merging only contiguous prefixes,
* restacking whatever remains,
* and accurately reflecting all of that in CI, review state, the merge queue, and the UI.

For a GitHub clone, the central architectural insight is to keep stacks in the **forge’s metadata and operation layer**, while giving the Git data plane strong generic primitives for commit-graph queries, replay, object retention, and transactional compare-and-swap ref updates.

[1]: https://github.blog/changelog/2026-07-30-stacked-pull-requests-are-now-in-public-preview/ "https://github.blog/changelog/2026-07-30-stacked-pull-requests-are-now-in-public-preview/"
[2]: https://docs.github.com/en/pull-requests/get-started/about-stacked-prs "https://docs.github.com/en/pull-requests/get-started/about-stacked-prs"
[3]: https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/optimizing-ci-for-stacked-pull-requests "https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/optimizing-ci-for-stacked-pull-requests"
[4]: https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/merging-stacked-pull-requests "https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/merging-stacked-pull-requests"
[5]: https://docs.github.com/en/rest/pulls/stacks "https://docs.github.com/en/rest/pulls/stacks"
[6]: https://docs.github.com/en/graphql/reference/pulls "https://docs.github.com/en/graphql/reference/pulls"
[7]: https://github.com/github/gh-stack/blob/main/internal/stack/stack.go "https://github.com/github/gh-stack/blob/main/internal/stack/stack.go"
[8]: https://github.com/github/gh-stack "https://github.com/github/gh-stack"
[9]: https://docs.github.com/en/rest/pulls/pulls?apiVersion=2022-11-28 "https://docs.github.com/en/rest/pulls/pulls?apiVersion=2022-11-28"
[10]: https://docs.github.com/en/pull-requests/reference/stacked-pull-requests "https://docs.github.com/en/pull-requests/reference/stacked-pull-requests"
[11]: https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-stacked-pull-requests "https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-stacked-pull-requests"
[12]: https://docs.github.com/en/pull-requests/reference/branches "https://docs.github.com/en/pull-requests/reference/branches"
[13]: https://git-scm.com/docs/git-rebase "https://git-scm.com/docs/git-rebase"
[14]: https://git-scm.com/docs/git-update-ref "https://git-scm.com/docs/git-update-ref"
[15]: https://git-scm.com/docs/git-merge-tree "https://git-scm.com/docs/git-merge-tree"


