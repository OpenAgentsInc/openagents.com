# SCV planning

Date: 2026-08-20

Status: Proposed architecture; implementation and autonomous deployment remain disabled

## Outcome

Build an Elixir-native, durable SCV that continuously finds bounded codebase
improvements, implements them in isolated repository workspaces, proves each
candidate against an exact Git SHA, and submits admitted candidates to the Forge
deployment pipeline.

SCV means Space Construction Vehicle. Use SCV consistently in code,
documentation, configuration, and the interface. Do not introduce another name
for this subsystem.

An SCV is a logical long-running service, not one immortal process or one
unbounded model response. OTP processes may restart, provider calls may end, and
workspaces may be discarded. PostgreSQL, Forge commits, immutable artifacts, and
receipts preserve the SCV's identity and progress across those events.

The intended end state includes automatic deployment. The first implementation
must not bypass the repository's current safety contracts:

- GitHub remains canonical until the proof-gated cutover in
  [ADR 0007](decisions/0007-cut-over-to-forge-canonical-source-control-after-proof.md).
- Forge fleet deployment remains disabled until the isolated staging gates in
  the [integration hardening plan](2026-08-20-integration-hardening-and-staging-readiness-recommendations.md)
  pass.
- `SELF-EDIT-001` currently requires a human promotion. Enabling an SCV to
  promote a candidate requires an explicit invariant and architecture amendment,
  a typed service principal, and a policy-bound promotion receipt. Do not encode
  an SCV identity in the existing free-form `promoted_by` field and call that
  authorization.

The recommended first milestone is a continuously running, propose-only SCV.
The recommended first autonomous milestone is staging-only deployment of a
narrow, low-risk change class. Production autonomy is a later admission, not a
configuration toggle hidden inside the first release.

## Goals

An SCV should:

- Operate without a browser conversation or a person keeping a process alive.
- Select work from explicit evidence instead of producing undirected code churn.
- Use a versioned, digest-addressed SCV program and policy revision.
- Read and change the exact repository that Forge recognizes as source truth.
- Use an isolated, secret-free workspace with a complete compiler and test
  toolchain.
- Preserve every model request, tool decision, command result, commit, gate,
  promotion, deployment, verification, and rollback as bounded evidence.
- Recover after node, process, provider, and executor failures without repeating
  an uncertain external effect.
- Enforce token, cost, time, CPU, memory, disk, command, diff, commit, and
  deployment budgets outside the model.
- Keep one linear improvement history so later work includes earlier admitted
  improvements.
- Treat no change, refusal, and rollback as valid outcomes.

## Non-goals

The first SCV should not:

- Replace the existing user-scoped coding-job experience.
- Run as a conversational persona or compose user conversation memory into its
  instructions.
- Receive production credentials, user conversation content, profile memory,
  voice transcripts, or unrestricted database access.
- Edit its own authority policy, deployment allowlist, release gates, or
  evaluator and then approve that edit.
- Modify production data, perform destructive migrations, rotate secrets,
  change billing policy, or widen an authorization boundary.
- Run several repository-writing SCVs concurrently.
- Deploy a structural or unclassified candidate automatically in the first
  autonomous release.
- Treat a passing model-authored test as sufficient evidence of correctness.

## Existing foundation

The repository already implements much of the mechanical foundation. Reuse the
contracts, but do not force an SCV into a user-scoped abstraction whose identity
or bounds are wrong.

| Existing capability | Reuse | Required SCV change |
| --- | --- | --- |
| `OpenAgents.Providers.Provider`, `OpenAgents.Providers.Request`, and `OpenAgents.Providers.OpenAI` | Reuse the provider-neutral stream and event normalization | Add an SCV-specific client and program. Do not use the conversational context composer. Admit SCV-specific output and timeout bounds instead of relying on the text-turn defaults. |
| `OpenAgents.Tools.Registry`, `OpenAgents.Tools.Runner`, and tool receipts | Reuse schema validation, authority checks, cancellation, timeout handling, output bounds, and normalized outcomes | Add an `scv` execution surface and an SCV-only tool catalog. The model must never receive promotion, policy-edit, or deployment tools. |
| `OpenAgents.Work.JobServer` and `OpenAgents.Work` | Reuse the durable-step, generation-fence, forced-report, and recovery patterns | Do not add `scv` to `work_jobs.kind`. Work jobs are conversation- and owner-scoped, have a ten-minute limit, run the coding-lieutenant role program, and terminate after one report. |
| `OpenAgents.Work.Coding` and repository tools | Reuse exact-match edit semantics, safe path resolution, commit receipts, and branch confinement | Replace per-user approval receipts and the fixed `openagents/job-<id>` lifecycle with SCV service authority, durable run workspaces, richer Git inspection, and full test execution. |
| `OpenAgents.Inference` | Reuse metering concepts and server-held provider credentials | Add a service-principal ledger or generalize grants to identify an SCV. Do not invent a visitor, conversation, or machine to satisfy the current schema. |
| `OpenAgents.Forge.Pushes` and the WAL | Reuse the push acknowledgment barrier and immutable push receipts | Give an SCV executor a repository-scoped, branch-scoped credential. It must not receive the operator token or a credential that can update arbitrary refs. |
| `OpenAgents.Forge.Builder` and the build worker | Reuse isolated exact-SHA builds, structural classification, artifact verification, and bounded output | Keep the web release compiler-free. Run SCV commands in a separate worker identity and make candidate gate receipts durable outside one worker's `.git` directory. |
| `OpenAgents.Forge.Targets` and deployment coordinators | Reuse newest-target fencing, direct-load transactions, relup, rolling replacement, boot convergence, and receipts | Add a policy-authorized SCV promotion path that remains separate from a push. Preserve human promotion for every class outside the admitted SCV policy. |
| `OpenAgents.Incidents` | Reuse typed failures, bounded context, recurrence tracking, and nonrecursive repair principles | Admit sanitized incidents as possible work-item evidence. Never expose private incident context or allow a failed SCV to recursively create another SCV. |
| Exact-SHA release gate | Reuse `mix precommit`, focused tests, release smoke, direct-load, relup, and rolling proofs | Define which gate is mandatory for each risk class. Store the exact gate definition digest so an SCV cannot weaken the gate in the same candidate. |

The existing coding-job integration test proves the sequence through a pushed
branch and deliberately stops before promotion. An SCV should extend that
receipt chain instead of replacing it with a less governed shortcut.

## Separate bounded context

Create an `OpenAgents.SCV` bounded context. Keep generic SCV control-plane code
out of `OpenAgents.Work` and keep persona-specific code out of `OpenAgents.SCV`.

The context should own:

- durable SCV identity and policy revision;
- work discovery and admission;
- run leases and generation fencing;
- SCV program composition;
- provider continuations and tool-step receipts;
- executor requests and responses;
- repository workspace lifecycle;
- candidate and gate decisions;
- policy-authorized promotion requests;
- post-deployment observation and rollback decisions;
- budgets, circuit breakers, and operator controls.

Forge should continue to own Git, build, target, deployment, rollback, and boot
convergence. An SCV proposes source and presents policy evidence. Forge decides
whether an exact SHA can become a target and whether that target becomes live.

## Architecture

```text
sanitized evidence and operator work
                |
                v
      SCV work-item admission
                |
                v
   durable SCV coordinator and lease
       |                    |
       | provider events    | typed executor requests
       v                    v
server provider adapter   isolated SCV worker
                            |-- exact Forge checkout
                            |-- bounded file tools
                            |-- bounded command runner
                            |-- disposable database and services
                            `-- no production secrets
                                   |
                                   v
                         SCV candidate commit and push
                                   |
                                   v
                        immutable exact-SHA gate receipt
                                   |
                                   v
                     host policy and promotion receipt
                                   |
                                   v
                    Forge build and deployment pipeline
                                   |
                                   v
                    post-deployment verification window
                         |                     |
                         v                     v
                    admit result       promote predecessor
```

### Runtime placement

Keep the durable coordinator Elixir-native. Implement its lifecycle with OTP,
Ecto, and supervised tasks. Do not make an external coding CLI the SCV's
authority or durable state machine.

Run candidate code and build commands in a separate SCV worker container or
owned worker VM. The worker may also run Elixir, but it must use a separate
runtime identity and mounts from the Phoenix release. This preserves the Forge
build-lane rule that the web release receives no compiler, Docker socket, or
general command-execution authority.

The worker needs:

- read access to exact Forge objects;
- write access only to an SCV run ref;
- access to an atomic request and response channel;
- an ephemeral workspace, build cache, and disposable database;
- bounded CPU, memory, disk, process count, and wall-clock time;
- no production database URL, release cookie, cloud credential, Forge operator
  token, or user credential;
- no network by default, except the narrow internal endpoints required for
  Forge and coordinator communication.

Candidate code is untrusted during evaluation even though the worker runs in an
owned environment. Tests and Mix tasks can execute arbitrary repository code.
Do not mount any credential that candidate code could read or transmit.

## Durable execution model

An SCV remains logically active while its work occurs in bounded runs. The
coordinator repeats this sequence:

1. Wake on a durable work item, admitted signal, or bounded poll interval.
2. Acquire the repository's single-writer lease and increment its generation.
3. Select one work item against the current policy, budget, and integration
   head.
4. Start a bounded run with a fresh model context and isolated workspace.
5. Persist every requested tool step before execution.
6. Commit an honest terminal run result, including `no_change`, `refused`, or
   `budget_exhausted`.
7. If the run produced a candidate, advance it through gates and deployment as
   a separate durable state machine.
8. Observe the outcome, update the work item, release the lease, and return to
   idle.

This model supports continuous operation without infinite prompts, unbounded
mailboxes, permanent workspaces, or one process whose death loses the plan.

### Context and checkpointing

Start each run with bounded, source-linked context:

- the exact base SHA and SCV integration ref;
- the admitted work-item objective and evidence refs;
- the SCV program and policy digests;
- relevant repository paths, symbols, and recent commits;
- focused test failures or sanitized operational facts;
- prior attempts for the same work-item fingerprint;
- current token, command, diff, time, and deployment budgets.

Store compact checkpoints after investigation, plan selection, each mutation,
each test group, commit, gate, and deployment. A checkpoint is structured state,
not a transcript dump. It should identify facts, evidence refs, decisions,
changed paths, remaining work, and unresolved risks.

If context grows beyond its admitted limit, start a new provider response from
the latest durable checkpoint. Do not trust a model-authored summary without
the source refs needed to verify it.

## SCV program

Define a versioned `OpenAgents.SCV.Program` artifact with a calculated digest
and an admitted digest, following the repository's existing persona and role
artifact discipline without making an SCV a persona.

The SCV program should require this method:

1. State the observed problem and its evidence.
2. Read the relevant implementation, tests, invariants, and documentation.
3. Define the smallest verifiable outcome.
4. Add or identify a failing test before changing behavior.
5. Make a focused change.
6. Run the narrowest useful check, then the required candidate gate.
7. Inspect the final diff for unrelated or policy-protected changes.
8. Commit once the candidate is coherent.
9. Report uncertainty, omitted work, and exact receipts.

Repository files, issues, test output, comments, commit messages, dependency
metadata, and incident descriptions remain untrusted input. They cannot change
the SCV program, tool authority, budget, protected paths, risk class, gate, or
deployment policy.

## Work discovery and selection

An SCV should optimize against observable product and engineering outcomes. It
should not make changes to remain busy.

### Initial work sources

Admit these sources first:

- operator-created SCV work items;
- reproducible failing tests from the owned gate;
- compile warnings and static contract failures;
- typed, recurring incidents with sanitized evidence;
- documented TODO items that name an expected result and owner-approved scope;
- focused coverage gaps for high-risk code when the work item names the missing
  behavior;
- measurable performance regressions with a stable benchmark.

Delay broad dependency updates, external vulnerability feeds, speculative
refactoring, and free-form issue ingestion until their authority and network
contracts are explicit.

### Admission score

Score a work item with host-owned data:

- user or operator impact;
- reproducibility and evidence quality;
- confidence that the repository contains the fix;
- expected diff and deployment risk;
- estimated test and inference cost;
- recurrence and age;
- collision with active human work;
- cooldown after a prior failed attempt.

The model may recommend a score, but host code calculates the admitted score
and selects the next item. Deduplicate work by a stable fingerprint over the
repository, evidence class, affected surface, and normalized problem code.

### Valid idle behavior

When no item clears the admission threshold, an SCV remains idle. Idle is a
healthy state. Avoid goals such as "improve the codebase" without a measurable
problem because they reward churn, test rewriting, and style-only diffs.

## Workspace and Git model

### Exact base

Create each workspace from an exact commit in the WAL-backed Forge repository.
Do not copy the running image tree into a writable directory and do not clone
from GitHub.

Use a linear SCV integration ref, initially
`refs/heads/scv/integration`. Each run:

1. Reads the ref and its durable WAL position.
2. Records the exact base SHA in the run.
3. Checks out that SHA detached in a fresh workspace.
4. Creates `refs/heads/scv/runs/<run-id>` for its candidate.
5. Pushes with an expected-old-SHA compare-and-swap condition.

Only one repository-writing SCV runs at first, but the compare-and-swap remains
required. It catches operator changes, restore races, and future concurrency.

### Keeping improvements

Do not base each run on the default branch or current image independently. A
candidate deployed from a run branch can be absent from the next default-branch
clone. The SCV integration ref must advance only after the candidate reaches
its admitted terminal state:

- For a source-only candidate, advance after its source gate passes.
- For a runtime candidate, advance after Forge marks it `live` and the
  observation window passes.
- For a reverted or failed candidate, leave the integration ref on its
  predecessor.

Advance the integration ref through the normal authenticated Forge push path so
the WAL remains ref authority. Use compare-and-swap against the recorded base.
Do not update a bare repository ref directly from application code.

Before Forge becomes canonical, keep an SCV in propose-only mode and reconcile
its run refs through the existing GitHub review process. After the ADR 0007
cutover, decide whether `scv/integration` becomes the default branch or merges
into it through another policy-controlled fast-forward. Do not operate two
writable canonical histories.

### Workspace lifecycle

Keep a run workspace until its candidate reaches a terminal result and retain
only bounded diagnostic artifacts afterward. Remove it after success, refusal,
failure, cancellation, or rollback. Never reuse a dirty workspace for another
run.

## Tool and command design

Reuse repository read, grep, list, exact-edit, write, and commit semantics where
they fit. Add SCV-specific tools for:

- `git status`, diff, log, show, merge-base, and blame projections;
- file creation, deletion, and rename with path and byte bounds;
- focused test discovery and execution;
- Mix help and admitted Mix tasks;
- JavaScript tests through the repository's pinned package command;
- formatting and final diff inspection;
- checkpoint and candidate submission.

Do not expose a raw shell-string tool. The executor should receive an executable
name, argument list, working directory, environment profile, time limit, and
output limit as structured data. Invoke it without a shell.

A small command allowlist is safer but may be too restrictive for useful coding
work. Use policy profiles instead:

- A read profile admits bounded Git and source-inspection commands.
- A focused-test profile admits exact repository-owned test entry points and
  Mix tasks after validating their options.
- A candidate-gate profile admits only the immutable gate definition.
- A networked profile remains disabled in the first release.

Validate environment variables against an allowlist and build a fresh
environment. Never inherit the coordinator's complete environment. Redact
output before persistence and retain full output only in an operator-only,
short-lived store with a digest in the receipt.

Promotion, deployment, rollback, policy changes, budget increases, and
integration-ref advancement are host actions. Do not advertise them as model
tools.

## Durable records

Prefer separate tables over extending user-facing work rows.

### `scvs`

Store one logical SCV identity per repository:

- repository;
- status: `disabled`, `idle`, `running`, `paused`, or `circuit_open`;
- admitted program and policy revisions and digests;
- integration ref and admitted head SHA;
- owner node, lease generation, and lease expiry;
- current run and candidate IDs;
- budget window counters;
- last healthy and last terminal timestamps.

### `scv_work_items`

Store durable candidate work:

- source and source reference;
- stable deduplication fingerprint;
- bounded title, objective, and sanitized evidence refs;
- admitted risk ceiling and repository scope;
- priority inputs and calculated score;
- status: `discovered`, `admitted`, `running`, `completed`, `deferred`,
  `refused`, or `failed`;
- attempt count, cooldown, and terminal reason.

### `scv_runs`

Store one bounded execution episode:

- SCV, work item, base SHA, integration WAL position, and generation;
- program, policy, tool-catalog, evaluator, and gate digests;
- model and provider adapter IDs;
- phase and terminal status;
- token, cost, tool, command, time, CPU, memory, disk, and diff usage;
- structured checkpoint and bounded report;
- candidate ID and error code;
- start and completion timestamps.

### `scv_steps`

Store every provider and tool boundary in order:

- sequence, provider response and call IDs, and prior-response ID;
- tool version, artifact digest, arguments digest, and output digest;
- requested, claimed, terminal, and uncertain timestamps;
- executor identity, status, error code, and receipt refs;
- run generation and idempotency key.

Store large input and output only in a bounded, access-controlled artifact
store when diagnosis requires it. Database rows should contain redacted
excerpts and digests.

### `scv_candidates`

Store the immutable candidate decision:

- run, base SHA, candidate SHA, run ref, and changed paths;
- diff digest, line and byte counts, and semantic risk findings;
- focused-test and gate receipt refs;
- policy decision and policy digest;
- source integration, Forge target, build, deploy, and predecessor refs;
- observation window, measurements, terminal result, and rollback target;
- immutable timestamps for each transition.

Use database constraints and triggers for forward-only terminal states and
immutable receipt fields. Treat PubSub and UI projections as hints.

## Run state machine

Use a state machine that distinguishes source construction from deployment:

```text
queued
  -> claiming
  -> investigating
  -> editing
  -> focused_testing
  -> candidate_committed
  -> candidate_pushed
  -> gating
  -> policy_review
  -> source_admitted
  -> promoting
  -> building
  -> deploying
  -> observing
  -> completed
```

Every nonterminal state may move to `failed`, `refused`, `cancelled`,
`budget_exhausted`, or `superseded` where appropriate. A deployed candidate may
move from `observing` to `reverted`. `no_change` is a terminal result from
investigation or focused testing.

Do not store one generic `running` status and infer the operation from logs.
Recovery and operator controls need the exact durable phase.

## Change policy

An SCV's most important code is the host-owned change classifier. It should
combine changed paths, diff structure, AST-level findings where practical,
Forge's build classification, and explicit protected-surface rules. A path
allowlist alone cannot recognize an authorization change hidden in a general
module.

### Recommended risk classes

| Class | Examples | Initial action |
| --- | --- | --- |
| Source-only | Documentation, comments, tests that add coverage, and development-only diagnostics | Require human review first. After a separate source-only policy admission, gate and advance the SCV integration ref without creating a fleet target when runtime output is unchanged. |
| Low-risk runtime | Focused bug fix in an explicitly admitted module, no interface or state-shape change, direct-load classification, and strong regression test | Human promotion first; staging autodeploy after policy proof. |
| Moderate runtime | New route, changed API shape, process-state behavior, broad refactor, or cross-context behavior | Require human review and the complete exact-SHA release gate. |
| Structural | Dependencies, assets, runtime configuration, migrations, releases, module deletion, native code, relup, or rolling replacement | Require human review. Admit staging automation only in a later policy revision with independent evidence. |
| Protected | SCV policy, Forge control, authentication, authorization, secrets, billing, data rights, invariant weakening, or release-gate weakening | Never auto-approve. Require an external operator path and independent evaluation. |

### Protected surfaces

The initial policy should refuse automatic promotion when a candidate changes:

- `AGENTS.md`, `INVARIANTS.md`, the SCV program, SCV policy, or SCV evaluator;
- `.githooks/`, `ops/ci/`, release-gate code, coverage floors, or test filters;
- `OpenAgents.Forge`, deployment providers, boot convergence, or release code;
- authentication, authorization, token, vault, secret, route-authority, or
  operator modules;
- migrations, schemas with durable-state meaning, or database triggers;
- provider credential handling, inference pricing, budgets, or metering;
- memory consent, data rights, publication visibility, or private-data bounds;
- dependencies, lockfiles, Dockerfiles, Terraform, runtime configuration, or
  production infrastructure;
- existing tests whose removal or weakening reduces a protected assertion.

An SCV may propose changes in these areas on its run branch, but the candidate
must stop at human review. The automatic lane must evaluate the complete diff,
including generated files and renames.

### Policy independence

Evaluate a candidate with the policy revision that existed at the run's base
SHA and a host-installed minimum policy. If a candidate changes policy code,
tests, or configuration, those changes cannot affect its own decision.

Use a two-key rule for later policy expansion: an operator admits the new
policy digest, and an independent evaluator proves its regression corpus. An
SCV can author a policy change, but it cannot supply either approval key.

## Candidate gates

Run checks in increasing order of cost and stop on the first failure:

1. Confirm workspace cleanliness and exact base ancestry.
2. Validate changed paths, diff bounds, generated artifacts, and protected
   surfaces.
3. Run formatting and focused regression tests.
4. Run compile with warnings as errors.
5. Run `mix precommit`.
6. Commit and push the exact candidate SHA.
7. Run the required exact-SHA release gate in a fresh checkout.
8. Verify that the gate definition digest matches the base policy.
9. Have Forge build and classify the exact pushed SHA independently.
10. Compare Forge's manifest and structural findings with the SCV policy
    decision.

The final gate must run after commit because the repository's release receipts
bind an exact SHA. Run it in a fresh checkout so ignored files, a dirty worktree,
or the SCV's build cache cannot change the result.

For a low-risk automatic candidate, require all of these facts:

- the candidate descends from the admitted integration head;
- focused tests prove the reported defect or improvement;
- no protected surface changed;
- `mix precommit` passes without retries or modified thresholds;
- the exact-SHA gate passes in the trusted evaluator;
- Forge independently classifies the complete candidate as `direct_candidate`;
- every changed runtime module matches the narrower SCV allowlist and Forge's
  operator-owned allowlist;
- the deployment budget and cooldown admit another target;
- no active incident, deploy, rollback, or human freeze blocks promotion.

## Automatic promotion

Keep push and promotion separate. A pushed SCV candidate should wake an SCV
policy evaluator, not `OpenAgents.Forge.Targets` directly.

Add a typed promotion principal such as:

```text
principal_type: scv
principal_id: <stable-scv-id>
policy_digest: <admitted-policy-digest>
candidate_id: <immutable-candidate-id>
gate_receipt_ref: <exact-sha-gate-receipt>
decision_digest: <complete-policy-input-digest>
```

The promotion API should accept either an authenticated operator receipt or an
admitted SCV receipt. It should verify the principal and evidence server-side,
then insert the same append-only Forge target used by a human promotion.

This amendment preserves the useful boundary that a push never promotes
itself. The model cannot promote. The repository tools cannot promote. The SCV
coordinator can request promotion only after host code has produced the
admitted receipt.

Record the promotion authority class explicitly in the target schema. Do not
overload a display string such as `operator:scv` because it would make audits
and authorization ambiguous.

## Deployment and verification

### Deployment sequence

After an admitted SCV promotion:

1. Wait for Forge to build the exact SHA and persist its receipt.
2. Require the build classification to match the SCV policy decision.
3. Let Forge select and execute the admitted deployment strategy.
4. Wait for the target and terminal deploy receipt from durable state, not only
   PubSub.
5. Start a post-deployment observation window after the target reaches `live`.
6. Run candidate-specific probes plus common health and readiness checks.
7. Compare bounded operational measurements with the recorded predecessor
   baseline.
8. Mark the candidate complete and advance the integration ref only after the
   observation window passes.

An SCV must never call BEAM loading functions or cloud deployment APIs itself.
Forge owns those effects and their rollback contracts.

### Observation contract

Define the expected signals before promotion. Use candidate-specific signals
where possible:

- the new regression test remains green against the packaged or live target;
- `/healthz` and deployment readiness remain healthy;
- fleet revision and artifact identities remain consistent;
- affected error codes do not regress;
- latency, memory, mailbox, and restart measurements remain within an admitted
  envelope;
- no new anomalous incident correlates with the candidate;
- the candidate's intended product outcome is observable when a safe synthetic
  probe exists.

Avoid a single global "error rate" gate that may miss a focused regression or
react to unrelated traffic. Store baseline interval, candidate interval,
sample size, missing-data result, and comparison policy in the candidate.
Missing required data should refuse admission rather than count as success.

### Rollback

Forge already reverts a failed deployment transaction before it marks a target
`live`. Post-live regression needs a second path: promote the exact predecessor
as a new target with an `scv_automatic_rollback` receipt, run the normal Forge
pipeline, and verify convergence.

Open the SCV circuit when any automatic candidate:

- requires post-live rollback;
- cannot verify rollback;
- leaves fleet identity divergent;
- creates an anomalous incident in a protected plane;
- exceeds its observation budget without enough evidence.

After the circuit opens, an SCV may continue read-only diagnosis if policy
allows it, but it cannot push, integrate, promote, or deploy until an operator
records a resume receipt.

## Control-loop stability

Continuous improvement can become an unstable feedback loop. Add these
controls from the first autonomous release:

- One active repository-writing run and one active candidate per repository.
- A cooldown between live candidates.
- A daily deployment budget and a separate rollback budget.
- A stable work-item fingerprint and retry backoff.
- A limit on changed files, lines, bytes, commits, and modules.
- A maximum number of attempts before operator review.
- A ban on immediately undoing and redoing the same change without new
  evidence.
- A predecessor comparison that detects oscillation between two SHAs.
- A change-frequency cap per subsystem.
- A freeze during incidents, migrations, operator maintenance, or fleet
  degradation.
- An operator pause that takes effect before the next external effect and a
  kill action that cancels current provider and executor work.

Do not use deployment count or lines changed as an SCV success metric. Prefer
resolved reproducible failures, prevented incidents, retained regression
tests, measured performance improvement, rollback-free observation windows,
and operator acceptance.

## Budgets

Use nested budgets:

- **Step budget:** input and output bytes, provider tokens, command output,
  command duration, and retries.
- **Run budget:** model calls, tool calls, continuations, wall time, CPU, memory,
  disk, changed files, diff size, and commits.
- **Candidate budget:** gate time, build attempts, deployment attempts,
  observation duration, and rollback attempts.
- **Window budget:** daily tokens, estimated cost, runs, pushes, promotions,
  deployments, and rollbacks.

Store the budget snapshot on the run before execution. A later configuration
increase must not widen an active run. When a run reaches a bound, refuse new
effects, request a tool-free bounded report when possible, and commit an honest
`budget_exhausted` result.

Start with conservative staging values and tune them from receipts. A useful
initial posture is one 45-minute run at a time, one candidate in flight, a
15-minute post-live observation window, at most four automatic staging
deployments per 24 hours, and an immediate circuit open after one rollback.
Keep these settings operator-owned and runtime-validated instead of hard-coding
them in a prompt.

## Recovery and idempotency

Use PostgreSQL as the run fence, following the existing work recovery contract:

- Claim a run under a row lock, record `owner_node`, increment `generation`,
  and set a bounded lease.
- Require the current generation on every checkpoint and terminal update.
- Reclaim only after the prior lease expires or its node is proven absent.
- Keep completed steps immutable.
- Resume only from committed outcomes.

Classify effects by recovery behavior:

| Effect | Recovery rule |
| --- | --- |
| Repository reads and deterministic analysis | Safe to repeat against the recorded SHA |
| Provider planning call | Safe to replace with a new call from a committed checkpoint; do not claim the interrupted response completed |
| File edit in an isolated workspace | Re-read and verify the expected digest before repeating |
| Test or compile command | Safe to repeat in a clean candidate workspace |
| Commit | Resolve by the run's tree digest and recorded ref before creating another commit |
| Push | Resolve the run ref and WAL receipt before retrying with compare-and-swap |
| Integration-ref advance | Resolve the WAL position and expected predecessor; never repeat blindly |
| Promotion | Deduplicate by candidate ID and promotion-decision digest |
| Deployment | Forge target and deployment IDs are authority; an SCV only observes or requests rollback |

If the executor dies during a command whose external effects cannot be
resolved, mark the step `uncertain`, fail the run closed, and require a new
workspace. Do not infer success from partial output.

## Security boundaries

### Service identity

Give an SCV separate, narrow identities for:

- provider use and usage accounting;
- coordinator-to-executor requests;
- Forge fetch;
- run-ref push;
- promotion receipt signing or verification;
- read-only operational measurements.

Do not reuse a browser session, user API token, machine pairing token, Forge
operator token, release cookie, or cloud deployment identity.

### Repository content and prompt injection

Treat all repository and work-item text as data. Host code must enforce:

- tool names and versions;
- exact repository and workspace roots;
- command profiles and arguments;
- environment variables and network access;
- path and output bounds;
- policy and gate digests;
- promotion and rollback admission.

A comment that says to ignore policy, expose credentials, weaken tests, or
deploy directly is an input-quality incident, not an instruction.

### Candidate execution

Assume candidate tests can read every mounted file and connect to every allowed
network destination. Use a disposable database with synthetic data, an empty
home directory, no forwarded SSH socket, no cloud metadata access, and no inherited
credential helpers. Pin dependencies before disabling external network access
for candidate execution.

### Data minimization

An SCV needs code and content-free operational facts, not user data. Incident
inputs should carry typed codes, affected component, recurrence, timestamps,
and sanitized stack or test refs. Never attach prompts, messages, memory,
transcripts, OAuth data, or arbitrary production rows.

## Observability and operator controls

Add an operator-only SCV surface with stable IDs and bounded projections. Show:

- SCV status, policy and program revision, lease generation, and integration
  head;
- active and recent work items, runs, candidates, and budgets;
- current phase, elapsed time, and cancellation state;
- changed paths and diff summary after a candidate exists;
- focused tests, exact-SHA gate, Forge build, target, deployment, and observation
  receipts;
- terminal result, rollback state, and circuit reason;
- **Pause**, **Resume**, **Cancel run**, **Reject candidate**, **Require human
  review**, and **Open diff** controls.

Do not expose raw prompts, private incident content, credentials, internal node
names, full build logs, or unrestricted command output. Public changelog entries
may name an SCV as the source role only after the existing repository visibility
policy admits the candidate.

Emit content-free telemetry for:

- work discovery and admission;
- run, provider, tool, and command duration;
- token and cost use;
- candidate refusal reasons;
- gate and build outcomes;
- promotion, deploy, observation, and rollback results;
- lease recovery, stale generation refusal, and circuit changes.

## Runtime configuration

Add typed, fail-closed settings such as:

```text
OPENAGENTS_FEATURE_SCV
OPENAGENTS_SCV_MODE=observe|propose|staging_auto|production_auto
OPENAGENTS_SCV_REPOSITORIES=openagents.com
OPENAGENTS_SCV_PROGRAM_REVISION=<revision>
OPENAGENTS_SCV_POLICY_REVISION=<revision>
OPENAGENTS_SCV_EXECUTOR=<adapter>
OPENAGENTS_SCV_EXECUTOR_QUEUE_DIR=<absolute-path>
OPENAGENTS_SCV_WORKSPACE_DIR=<absolute-path>
OPENAGENTS_SCV_MAX_ACTIVE_RUNS=1
OPENAGENTS_SCV_RUN_TIMEOUT_MS=<bounded-integer>
OPENAGENTS_SCV_DAILY_TOKEN_BUDGET=<bounded-integer>
OPENAGENTS_SCV_DAILY_COST_MICROUSD=<bounded-integer>
OPENAGENTS_SCV_DAILY_DEPLOYMENTS=<bounded-integer>
OPENAGENTS_SCV_DEPLOY_COOLDOWN_MS=<bounded-integer>
OPENAGENTS_SCV_OBSERVATION_MS=<bounded-integer>
```

The runtime boundary should reject:

- any enabled mode without admitted program and policy digests;
- an executor path under `/tmp` in staging or production;
- an automatic mode before Forge deployment, boot convergence, durable
  artifacts, and isolated staging are enabled;
- `production_auto` while production deployment remains globally disabled;
- multiple active runs in the first policy revision;
- a deployment budget without an observation window and rollback authority;
- an SCV repository that is absent from the configured Forge repositories.

Readiness should report only enabled mode, admission status, circuit state, and
whether dependencies validate. It must not print paths, URLs, credentials,
work-item content, prompts, or internal identities.

## Suggested module layout

Keep one module per file.

```text
lib/openagents/scv.ex
lib/openagents/scv/instance.ex
lib/openagents/scv/work_item.ex
lib/openagents/scv/run.ex
lib/openagents/scv/step.ex
lib/openagents/scv/candidate.ex
lib/openagents/scv/program.ex
lib/openagents/scv/policy.ex
lib/openagents/scv/change_classifier.ex
lib/openagents/scv/budget.ex
lib/openagents/scv/coordinator.ex
lib/openagents/scv/recovery.ex
lib/openagents/scv/context.ex
lib/openagents/scv/provider_loop.ex
lib/openagents/scv/tool_catalog.ex
lib/openagents/scv/workspace.ex
lib/openagents/scv/executor.ex
lib/openagents/scv/executor/sidecar.ex
lib/openagents/scv/executor_protocol.ex
lib/openagents/scv/gate.ex
lib/openagents/scv/promoter.ex
lib/openagents/scv/observer.ex
lib/openagents/scv/circuit.ex
```

Use test adapters under `test/support`. Keep Forge changes in
`lib/openagents/forge/` when they generalize promotion principals or receipts;
do not make Forge import the SCV context.

## Implementation phases

### Phase 0: Amend contracts

1. Add an ADR for policy-authorized SCV promotion.
2. Amend `SELF-EDIT-001`, `docs/architecture.md`, and the route-authority ledger
   to distinguish human and SCV promotion receipts.
3. Define the first SCV program, policy, protected surfaces, risk classes, and
   evaluator corpus.
4. Define service identities and secret inventory entries.
5. Keep the feature disabled.

**Exit criteria:** Documentation and tests agree on who can admit an SCV
candidate, which changes can qualify, and how the operator stops the system.

### Phase 1: Observe and queue

1. Add SCV, work-item, run, step, and candidate schemas with database guards.
2. Add the coordinator, lease, budgets, recovery, pause, and circuit state.
3. Ingest operator work items and sanitized owned-gate failures.
4. Run selection and planning without repository writes.
5. Add the operator surface and content-free telemetry.

**Exit criteria:** An SCV runs continuously in `observe` mode, survives process
and node loss, deduplicates work, spends within budget, and performs no external
effect.

### Phase 2: Build candidates

1. Add the isolated executor protocol and worker.
2. Add exact Forge checkout, workspace confinement, SCV tools, command profiles,
   and candidate-code sandboxing.
3. Add focused tests, commit resolution, run-ref push, WAL receipt linking, and
   cleanup.
4. Keep every candidate propose-only.

**Exit criteria:** An SCV can reproduce, test, patch, commit, and push a bounded
candidate. Crash tests prove that no uncertain push or command becomes success.

### Phase 3: Gate and review

1. Add the independent change classifier and protected-surface enforcement.
2. Add immutable focused-test, `mix precommit`, exact-SHA release-gate, and
   evaluator receipts.
3. Add human promotion from the SCV candidate surface.
4. Reconstruct the complete chain from work evidence to Forge deploy receipt.

**Exit criteria:** A human can review and promote a low-risk SCV candidate with
all evidence visible, and every refused class stops before promotion.

### Phase 4: Automate isolated staging

Start only after ADR 0007's Forge-canonical cutover and the isolated staging
deployment gates pass.

1. Add typed SCV promotion principals and decision receipts.
2. Admit only the low-risk direct-load class.
3. Add post-live observation, automatic predecessor promotion, cooldown, daily
   deployment budgets, and the circuit breaker.
4. Run failure injection for provider, worker, WAL, database, build, fleet,
   health, observation, and rollback failures.
5. Hold the staging SCV through a defined soak with no unexplained state.

**Exit criteria:** Staging proves repeated exact-SHA improvements and deliberate
failure cases without mixed revisions, lost commits, unreceipted effects, or
continued deployment after rollback.

### Phase 5: Expand admitted scope

Expand one independent policy revision at a time. Possible later admissions
include broader direct-load modules, source-only integration, relup candidates,
and rolling replacement in isolated staging. Require a new regression corpus,
operator approval, and soak for each expansion.

Production autonomy requires a separate plan and approval after production
deployment itself becomes authorized. Do not infer production approval from a
successful staging SCV.

## Test plan

### Lifecycle and recovery

- Prove single-writer lease acquisition, renewal, expiry, and stale-generation
  refusal.
- Kill the coordinator during every phase and recover from durable state.
- Prove completed steps and terminal runs cannot change.
- Prove duplicate work evidence, provider events, executor responses, pushes,
  and promotion requests do not repeat effects.
- Prove uncertain commands fail closed.

### Workspace and executor

- Refuse absolute paths, traversal, symlink escape, invalid refs, stale bases,
  oversized files, and output overflow.
- Prove every run starts from the recorded exact SHA in a clean workspace.
- Prove candidate code receives no coordinator, Forge operator, database,
  cloud, or user credential.
- Prove network and environment profiles fail closed.
- Prove cancellation terminates descendant processes and cleans the workspace.

### Model and tools

- Validate SCV program and tool-catalog digests at boot.
- Reject parallel tool calls when the host supports only serial execution.
- Persist a tool request before execution and continue only from its committed
  outcome.
- Force a bounded report on token, continuation, command, and wall-clock limits.
- Run adversarial repository text that asks an SCV to expose secrets, weaken
  gates, expand authority, or deploy directly.

### Change policy

- Cover every source-only, low-risk, moderate, structural, and protected class.
- Refuse test deletion, assertion weakening, skipped tests, coverage-floor
  reduction, gate edits, renamed protected files, and generated protected
  output.
- Evaluate with the base policy when the candidate changes policy code.
- Require both the narrower SCV allowlist and Forge allowlist.
- Prove an unknown or conflicting classification fails closed.

### Git and receipts

- Prove compare-and-swap run-ref and integration-ref updates.
- Prove a run includes prior admitted SCV changes.
- Prove a failed or reverted candidate does not advance the integration ref.
- Resolve a crash after push from the WAL receipt without pushing twice.
- Reconstruct work item, run, steps, commit, push, gate, target, build, deploy,
  observation, and rollback by immutable refs.

### Deployment

- Prove a push alone never promotes.
- Refuse an SCV promotion without an admitted policy, exact-SHA gate, candidate
  decision, and budget.
- Prove an operator freeze wins every promotion race.
- Prove superseded-target handling and one candidate in flight.
- Inject canary, fleet, readiness, observation, and rollback failures.
- Open the circuit after one rollback and require an operator resume receipt.

### End-to-end proof

Create a fixture defect with a stable failing test. An SCV should:

1. Admit the work item.
2. Read the relevant code and invariant.
3. Add or select the regression test.
4. Make the smallest patch.
5. Pass focused checks and `mix precommit`.
6. Commit and push an exact SHA to its run ref.
7. Pass the independent exact-SHA gate and change policy.
8. Produce a policy-bound promotion receipt.
9. Reach `live` through Forge's transactional lane.
10. Pass the observation window and advance the integration ref.

Repeat with an injected post-live regression. The second proof must promote the
predecessor, verify restoration, leave the integration ref unchanged, and open
the circuit.

## Recommended first release

Ship the first SCV with this deliberately narrow posture:

- one repository: `openagents.com`;
- one logical SCV and one active run;
- `observe` and `propose` modes only;
- operator-created work items plus reproducible owned-gate failures;
- a dedicated SCV program, tool catalog, service principal, and budget ledger;
- a sidecar executor with no production secrets or general network access;
- run branches and complete receipt chains;
- source, diff, focused-test, and `mix precommit` gates;
- no automatic promotion, integration-ref advance, or deployment.

This release validates the difficult lifecycle, sandbox, Git, and evidence
contracts without granting deployment authority. The next release can add
human-reviewed SCV candidates. Staging autodeploy should follow only after the
Forge-canonical and isolated-fleet prerequisites pass.

## Acceptance criteria for staging autonomy

Do not describe an SCV as autonomous until all of these conditions hold:

- An SCV resumes across coordinator and worker loss without duplicate effects.
- Every candidate descends from and conditionally advances one linear
  integration history.
- Candidate code runs without production or operator credentials.
- Host policy, not model output, determines risk, gates, budgets, and promotion.
- Protected changes cannot approve themselves.
- A push cannot directly create a target.
- Every automatic target carries an admitted SCV principal, policy digest,
  candidate ID, exact-SHA gate receipt, and decision digest.
- Forge independently builds, classifies, deploys, and receipts the SHA.
- Post-live verification uses predefined evidence and treats missing evidence as
  failure.
- Automatic rollback promotes and verifies the exact predecessor.
- One rollback opens the circuit and stops further external effects.
- An operator can pause, cancel, reject, and resume an SCV without editing code
  or restarting the fleet.
- The complete staging failure matrix and soak pass against exact retained
  receipts.

An SCV that satisfies these criteria can make rapid iterations without making
the model, workspace, or running process the source of truth. Git commits,
policy decisions, gates, Forge targets, deployment receipts, and verified
runtime state remain the authority at every step.
