# Issue, work, and receipt linkage

**Date:** 2026-08-23
**Commit measured:** `198f117` on `openagents/main` (the forge), before this
document's own change
**Issue:** `#10`, "Connect issues to agent work and release receipts"
**Status:** design complete; stage 1 shipped in the same change, stage 4
shipped in `#148`, stage 2 shipped in `#145`
**Question:** `#10` asks to connect issues to durable agent jobs,
conversations, commits, tests, releases, and deployments **without creating a
second work record**. Which of those edges already exist, which exist but are
unlinked, and which do not exist? Where does each one belong?
**Method:** direct reading of every schema and migration that could carry the
edge — `lib/openagents/work/`, `lib/openagents/forge/`,
`lib/openagents/issues/`, `lib/openagents/scv/`,
`lib/openagents/deployments/`, `lib/openagents/settlement/`,
`lib/openagents/changelog/`, `lib/openagents/transparency/`,
`lib/openagents/compensation/`, and all 116 files under
`priv/repo/migrations/` — plus the two surfaces that would read them
(`lib/openagents_web/live/issue_show_live.ex`,
`lib/openagents_web/controllers/issue_json.ex`) and the contracts that bound
them (`INVARIANTS.md`, `docs/taxonomy.md`,
`docs/accepted-outcome-contract.md`). Claims this repository cannot settle
are in section 8 with the command or file that would settle them.

---

## 0. Summary

The edges `#10` needs are mostly present. Almost nothing about this issue is
new storage; it is joining records that already exist and were built by
separate lanes that never met.

Three durable execution records already exist, and they are not redundant:

- **`work_jobs`** (`lib/openagents/work/job.ex:28`) is the execution: steps,
  report, budget, terminal status, five kinds
  (`deep_work delegation coding scv continual_learning`, `job.ex:18`). It is
  scoped to a conversation and an owner. It has no repository column, no
  branch column, no commit column, and **no issue column**.
- **`box_runs`** (`lib/openagents/box/run.ex`) is one detached command run on
  a Box. Also conversation-scoped, also with no issue.
- **`forge_assignments`** (`lib/openagents/forge/assignment.ex:14`) is the
  **attempt**: one issue, one repository, one branch, one target, one
  requesting principal, one terminal commit, one terminal state. It shipped
  for `#108` and was generalized to connected Computers for `#127`.

`forge_assignments` is already the issue-to-work edge `#10` asks for. What was
missing was not the record but the join and the read: the pointer from a work
job back to its assignment lived inside a JSONB map
(`work_jobs.delegation["assignment_id"]`, written at
`lib/openagents/forge/assignments.ex:103`), so nothing could ask an issue
which jobs ran against it without scanning every work job, and no surface
asked.

Four findings shape the staging:

1. **A fourth, dormant issue-to-work record existed, and is gone.**
   `scv_runs` carried `belongs_to :issue, Issue, type: :id` with an
   `[:issue_id, :inserted_at]` index. It was set only through
   `Executions.claim/4` (`lib/openagents/scv/executions.ex`), reached only
   from `SCV.CodexRuns.start/5` (`lib/openagents/scv/codex_runs.ex`), which
   has no caller anywhere in `lib/`, and no test set it either. That was the
   exact shape of the second work record `#10` forbids, and it arrived by
   accident. `#152` dropped the column and the index. Section 8 records the
   reasoning and what would make the Codex lane issue-bound instead.
2. **The issue timeline is prose today.** There is no `issue_events` table.
   `OpenAgentsWeb.IssueShowLive` derives its feed from the columns the issue
   does store and says so in its own moduledoc
   (`lib/openagents_web/live/issue_show_live.ex:22`). Agent activity reaches
   the issue as Markdown comments written by `Assignments.report_claim/1`,
   `report/1`, and `report_release/1` (`assignments.ex:371`, `:338`, `:356`).
   That is precisely what `#69` refuses: "link work jobs and commits through
   stable identifiers, not free-form commit messages alone".
3. **The commit-to-receipt chain is complete and already joined — by sha, not
   by issue.** `changelog_entries` carries `push_receipt_id`,
   `build_receipt_id`, `target_id`, `deploy_receipt_id`, `artifact_link_id`,
   and `transparency_tier` in one row (`lib/openagents/changelog/entry.ex:34`
   to `:39`), and `Forge.receipts_for/2` (`lib/openagents/forge.ex:60`) returns
   every push, build, target, and deploy receipt for a sha. What no record
   carries is an issue: `forge_pushes`, `forge_builds`, and `forge_deploys`
   have zero issue linkage, and all three key on `repo` as a **string** rather
   than a repository foreign key.
4. **The accepted-outcome contract is a function, not a record.**
   `OpenAgents.AcceptedOutcome.evaluate/1` grades a claim map
   (`lib/openagents/accepted_outcome.ex:104`) and nothing stores the claim or
   its result. `compensation_outcome_decisions` — the record `PROMISE-001`
   gates `LIVE` promises on — is keyed on `tool_step_id`
   (`lib/openagents/compensation/outcome_decision.ex:11`), a conversation tool
   step, not an issue. "Close work only from verified outcomes" therefore has
   no durable outcome to read from yet.

Stage 1, the read-only issue-to-job linkage `#10` asks to start with, shipped
in this change and is described in section 7. Stages 2 through 6 are in
section 6, each named with its seam, its size, and which of `#67`, `#69`, and
`#71` it unblocks.

---

## 1. The edges

Every edge `#10`'s planned delivery implies, and the state of each. "Unlinked"
means both endpoints are durable but no indexed relation joins them.

| # | Edge | State | Where it is, or would go |
| --- | --- | --- | --- |
| 1 | issue → execution attempt | **linked (stage 1)** | `forge_assignments.issue_id`, `assignment.ex:17`; index `[:repository_id, :issue_id]`, `20260823141005_create_box_assignments_and_scoped_credentials.exs:39` |
| 2 | attempt → work job | **was unlinked, now typed** | Was `work_jobs.delegation["assignment_id"]` (JSONB, unindexed), written at `assignments.ex:103`, read back at `lib/openagents/work/delegation_server.ex:224`. Now `forge_assignments.work_job_id` |
| 3 | attempt → box run | **exists** | `forge_assignments.run_id`, `assignment.ex:18` |
| 4 | attempt → conversation | **exists** | `forge_assignments.conversation_id`, added by `20260823165145_generalize_assignments_for_computers.exs:11`. Deliberately not projected — see section 4 |
| 5 | issue → commit | **partial, and the weaker half** | `forge_assignments.terminal_commit` (`assignment.ex:23`) is the attempt's own self-report. The authoritative direction — a commit that names its issue, verified against the default branch at push — is `#130`, in flight in another lane |
| 6 | commit → push receipt | **exists, scanned not joined** | `forge_pushes.refs` map, written at `lib/openagents/forge/pushes.ex:206`; matched by sha in `Forge.receipts_for/2` (`forge.ex:60`) and the private `receipt_index/1` (`lib/openagents/changelog.ex:148`) |
| 7 | commit → build receipt | **exists** | `forge_builds.sha`, `lib/openagents/forge/build_receipt.ex:18` |
| 8 | commit → deployment receipt | **exists** | `forge_deploys.sha` plus `target_id` and `deployment_id`, `lib/openagents/forge/deploy_receipt.ex:19` to `:22` |
| 9 | commit → note plus receipt chain | **exists** | `changelog_entries`, `lib/openagents/changelog/entry.ex:22`, joining all four receipt ids in one row |
| 10 | commit → qualification receipt | **exists twice, neither issue-scoped** | `deployment_check_results` keys `{repository, name, commit_sha, artifact_digest}` (`lib/openagents/deployments/check_result.ex:25`); `settlement_verifications` keys `{claim, commit_sha}` and already carries a `work_job_ref` string (`lib/openagents/settlement/verification.ex:23`). `forge_builds.tests` is free text |
| 11 | qualification → coverage manifest | **missing** | `#67` |
| 12 | deployment → release note | **missing** | `#71` |
| 13 | artifact → transparency tier | **exists, and does not cover work** | `artifact_links` from `#70`, `lib/openagents/transparency/artifact_link.ex:19`, with `@artifact_types ~w(changelog release issue build)` at `:15`. No `work_job`, `deployment`, `trace`, or `attempt` member |
| 14 | issue → agent trace | **missing here** | `docs/taxonomy.md` places the shareable trace store and the `/trace/{uuid}` viewer on the Node web app. This repository has no trace table. `changelog_entries.trace_ref` and `.trace_digest` (`entry.ex:31`) are pointers into it |
| 15 | claim → accepted outcome | **exists as a function, missing as a record** | `AcceptedOutcome.evaluate/1`, `lib/openagents/accepted_outcome.ex:104`, is pure. `compensation_outcome_decisions` is keyed on `tool_step_id`, `outcome_decision.ex:11` |
| 16 | issue → who closed it, and from what | **missing** | `issues` has `closed_at` (`lib/openagents/issues/issue.ex:18`) and no actor. `issue_show_live.ex:22` says so plainly: "a close records when but not who" |

Edges 1 through 4 are the E1 foundation of the work-system assessment's
Track E (`docs/2026-08-21-issues-projects-work-system-assessment.md:409`).
Edges 5 through 9 are E4 and E5. Edge 13 is E6. Edges 15 and 16 are E7.

---

## 2. Authority and projection

`#10`'s hard constraint is that no second work record appears. The way to
honor that is to say, for every edge, which row is allowed to be wrong and
which row must agree with it.

| Concern | Authority | Projection |
| --- | --- | --- |
| The requested outcome | `issues` | The issue page, the API `openagents` object, project items |
| One bound execution attempt | `forge_assignments` | `issue.openagents.work`, the issue timeline's attempt events |
| The execution itself | `work_jobs` (steps, report, budget) and `box_runs` | The attempt's state and terminal fields |
| The commit that exists | the forge WAL and the Git objects it serves | `forge_pushes.refs`, and every sha-keyed read |
| That a commit built | `forge_builds` | `changelog_entries.build_receipt_id` |
| That a commit reached an environment | `forge_deploys` for the OpenAgents release; `deployment_runs` plus `deployment_requests` for a tenant repository | `/status`, `changelog_entries.deploy_receipt_id` |
| That a commit qualified | `deployment_check_results` for the tenant plane; `settlement_verifications` for a settled claim | the issue timeline, once stage 4 joins them |
| Whether an outcome is accepted | `compensation_outcome_decisions` (`PROMISE-001`) | `AcceptedOutcome.public_projection/1` |
| What a viewer may see of a linked artifact | `artifact_links` (`#70`) | every surface that renders the artifact |

Three rules fall out of that table, and they are the reason stage 1 is as
small as it is.

**The issue never stores work.** It stores the request. Every attempt, job,
commit, and receipt is read through a join, so closing an issue cannot orphan
evidence and re-running an attempt cannot rewrite history. This is the same
discipline `#100` used for `blocked`: derived at read time, never stored, so
it cannot go stale (`lib/openagents/issues/issue_dependency.ex:2`).

**The attempt is the only new-ish edge, and it already existed.** An attempt
is not a work record: it has no steps, no report, no budget, and no output. It
records which issue an execution was authorized to change, which is exactly
the "bound attempt" the accepted-outcome contract requires — "the issue
number, the repository, the authority it acted under, its budget, and the
exact revision it produced" (`docs/accepted-outcome-contract.md:21`). Four of
those five are already columns on `forge_assignments`; the budget is on the
work job it now names.

**A receipt is never rewritten to point at an issue.** `forge_deploys` is
immutable in PostgreSQL — a trigger raises on any `UPDATE` or `DELETE`
(`priv/repo/migrations/20260820140000_harden_forge_deployment_transactions.exs:48`).
Any issue-to-receipt edge is therefore a separate row, joined by the sha and
the environment the receipt already carries. `#69` states this as a rule:
"Never treat a push receipt as a deployment receipt", and `docs/taxonomy.md`
states it as a naming rule: "A push is not a deploy."

---

## 3. What the issue timeline reads

The timeline is one derived feed, assembled in
`IssueShowLive.timeline/3` (`lib/openagents_web/live/issue_show_live.ex:597`)
and sorted by time. Before this change it merged three sources: the opened
event from `inserted_at`, the comments, and the closed event from `closed_at`.
It now merges a fourth.

Each attempt contributes at most two events, from
`attempt_events/1` (`issue_show_live.ex:646`):

- **started** — when the attempt has a `started_at` or an `admitted_at`. The
  text names the target and the branch: "started work on a computer, on branch
  `agent/issue-10`".
- **finished** — when the attempt has a `finished_at`. A completed attempt
  names the exact commit, abbreviated: "finished this work at `9606cbc`". A
  failed attempt names its typed reason. A cancelled attempt says so.

An attempt that started and never finished renders as started and nothing
more, which is the honest reading: the row says the attempt is still running,
and inventing a terminal event would be a guess. A failed, cancelled, or
superseded attempt is never removed, because
`forge_assignments_one_active_issue_index` is a **partial** unique index over
`state IN ('admitted','running')`
(`20260823141005_create_box_assignments_and_scoped_credentials.exs:34`): one
attempt may be live at a time, and every terminal attempt stays. That is `#69`'s
"one issue can show several execution and deployment attempts without losing
history", already true in the storage before any surface read it.

**An issue with no linked work shows exactly what it shows today.** The
attempt list is empty, no attempt events join the feed, and the page renders
its opened event, its comments, and its close. In the API the field is
`"work": []` rather than an absent key, because an issue nobody has worked is
a different fact from an issue whose attempts were not asked for — the same
distinction `IssueJSON` already draws for the dependency graph
(`lib/openagents_web/controllers/issue_json.ex:2`).

One duplication is now visible and is deliberate for stage 1: the same
attempt appears both as a derived timeline event and as the Markdown comment
`Assignments.report/1` writes. Stage 3 retires the comment in favor of the
derived event. Doing it in stage 1 would delete history from issues that
already carry those comments, which is a migration, not a read.

---

## 4. Policy-controlled ATIF visibility

`#10` says "apply policy-controlled ATIF visibility". Some older text in this
repository's history describes trace visibility as `public`, `unlisted`, and
`owner_only`, and `docs/taxonomy.md:103` still uses those words for the trace
product object. **The shipped levels are different.** `#70` closed on
2026-08-23 and delivered four tiers in `OpenAgents.Transparency`
(`lib/openagents/transparency.ex:19`):

- `dark` — nothing public
- `pulse` — metadata only
- `ledger` — content and metadata
- `glass` — full access

They are stored on `artifact_links` with a database check constraint
(`priv/repo/migrations/20260823150050_create_artifact_links.exs:26`) and
resolved by `Transparency.effective_tier/2` (`transparency.ex:42`), which
clamps the artifact's tier to the viewer's own and always resolves a revoked
link to `dark`. `Transparency.allows?/3` (`:58`) maps the three capabilities
`:metadata`, `:content`, and `:full` onto the minimum tier each needs.

Four things follow for `#10`.

**Repository authority is stronger than any tier.** An attempt on a private
repository's issue is invisible for the same reason the issue is:
`Repositories.readable_by/2` (`lib/openagents/repositories.ex:88`) is the one
predicate every surface composes, and the issue read raises
`Ecto.NoResultsError` before any attempt is loaded. A tier can only ever
narrow what a reader who already passed that predicate sees. `#70`'s own
acceptance criterion says it: "No tier can make a private repository, prompt,
credential, or customer artifact public by implication."

**The tier vocabulary does not yet cover work.**
`ArtifactLink.artifact_types/0` is `~w(changelog release issue build)`
(`lib/openagents/transparency/artifact_link.ex:15`). Attaching a tier to an
attempt, a work job, a trace, or a deployment receipt means adding members to
that list and to the check constraint. That is stage 5, and it is the whole of
E6.

**Until then, stage 1 discloses nothing new.** The attempt projection carries
only the fields the assignment already publishes as a public issue comment
today: target kind, state, branch, exact commit, failure reason, and
timestamps (`Assignments.attempt_summary/1`,
`lib/openagents/forge/assignments.ex:186`). The conversation id, the machine
id, the requesting principal, the prompt, the credential metadata, and the
work job's report are all excluded, and a test asserts the exact key set
(`test/openagents_web/controllers/issue_controller_test.exs`, "an attempt
never carries the prompt, conversation, or credential"). Nothing in stage 1
needs a tier because nothing in stage 1 is newly disclosed.

**Who may see what, once tiers cover work.** The intended reading, which
stage 5 must implement and prove:

| Viewer | Public repository | Private repository |
| --- | --- | --- |
| Anonymous | attempt metadata at `pulse` or above; that restricted evidence exists, never its content | nothing; the issue itself 404s |
| Signed in, no membership | the same as anonymous | nothing |
| Repository member | attempt metadata, plus receipt content at `ledger` | the same |
| The account that owns the work job | its own job's report and trace at `glass`, because `effective_tier/2` grants the owner the maximum | the same |
| Operator | `glass`, by `Transparency.viewer_tier/1` at `transparency.ex:115` | the same |

---

## 5. Closing work from verified outcomes

`#10`'s last delivery line is "close work only from verified outcomes when
policy permits". Three separate mechanisms meet here, and they are not
interchangeable.

**`#130` is the trailer path, and it is a different question.** It closes an
issue when a commit whose message says `Closes #N` becomes reachable from the
default branch, requiring that the pusher can write the issue and attributing
the close to that person. That is not verification — it is a **human
assertion, authenticated and bound to a merge**. It is the right default for
most work and it should not wait for anything in this document.

**`OutcomeDecision` is the verification path, and it is not issue-shaped
yet.** `PROMISE-001` gates a `LIVE` promise on a readable `accepted_outcome`
evidence entry naming a `compensation_outcome_decisions` row whose `decision`
is `accepted` (`INVARIANTS.md`, `PROMISE-001`), checked by
the private `accepted_outcome?/1` helper
(`lib/openagents/projects/promise_registry.ex:311`). But that row is keyed on
`tool_step_id` (`outcome_decision.ex:11`) — one immutable module outcome
inside one conversation. It cannot be reached from an issue, and it is not
what an issue's acceptance criteria were graded against.

**The contract that connects them exists only as a function.**
`AcceptedOutcome.evaluate/1` takes a claim map and returns `{:accepted, …}`,
`{:not_accepted, type, reasons}`, or `{:not_applicable, exemption}`
(`lib/openagents/accepted_outcome.ex:104`). Its only caller in `lib/` is
continual learning (`lib/openagents/continual_learning.ex:1057`). Nothing
stores a claim, and nothing stores a result, so no surface can answer "which
evidence qualified this issue" and no policy can key on it.

The design that follows, for stage 6:

- **Automatic closing stays with `#130`.** Consume its commit-to-issue
  extraction; do not build a second one. A trailer close remains a person's
  assertion, attributed to that person, and is recorded as such.
- **Verified closing is a separate, opt-in policy per repository**, and it
  never *reopens*: an unverified claim leaves the issue open with a typed
  non-accepted result, exactly the vocabulary
  `docs/accepted-outcome-contract.md:36` already fixes — `incomplete`,
  `unauthorized`, `failed`.
- **The claim becomes durable**, keyed on `{issue, attempt, revision}`, so
  the evaluation is reproducible and the issue can name which receipt
  satisfied which acceptance criterion. That is the missing record edge 15
  names, and both `#67` and `#69` need it.
- **The attempt supplies four of the five binding fields already.**
  `AcceptedOutcome.required_attempt_fields/0` is
  `issue_number repository authority budget revision`
  (`accepted_outcome.ex:22`); `forge_assignments` carries the issue, the
  repository, the requesting principal, and the terminal commit, and stage 1's
  `work_job_id` reaches the `budget_snapshot` on the job
  (`lib/openagents/work/job.ex:39`).
- **Producer-verifier separation is a policy read, not a new actor.** The
  contract already refuses a claim whose verifier is not independent when
  policy requires it; the attempt records who produced the revision, so the
  check has both halves.

---

## 6. The staged plan

Each stage names one seam, touches one repository, and is deployable alone.

### Stage 1 — read-only issue-to-job linkage (shipped)

**Seam:** `forge_assignments`, the extension namespace, the issue timeline.
**Size:** one migration, one column, three read functions, one JSON field, one
timeline source. Roughly 400 lines including tests.

Promote the JSONB pointer to a typed indexed column, read attempts through
it, and render them. Details in section 7. This is E1.

### Stage 2 — start bounded agent work from an issue (shipped)

**Seam:** `AssignmentController` and the issue page.
**Size:** medium. One authorized write path, one form, one refusal vocabulary.

`Assignments.create/1` already admits a target, mints a branch-scoped
credential, and starts the run (`lib/openagents/forge/assignments.ex:28`), and
the route exists (`lib/openagents_web/controllers/assignment_controller.ex`).
What is missing is the issue-side entry point: a bounded objective, a branch
policy, a budget, and an executor chosen from the issue rather than from a
conversation. Nothing new stores work; the button reaches the same admission.
This is E2, and `#10`'s "start bounded agent work from an issue".

### Stage 3 — live activity, and retiring the narration

**Seam:** `IssueShowLive` and `Assignments.report*/1`.
**Size:** small, plus one backfill decision.

Subscribe the issue page to the attempt's PubSub topic so a running attempt
updates without a reload, show elapsed time and a cancel control to a viewer
with write authority, and stop writing the three Markdown comments now that
the derived events carry the same facts. Existing comments stay; only new ones
stop. This is E3.

### Stage 4 — bind receipts to the exact commit (shipped)

**Seam:** a new `issue_evidence` edge table, and `#130`'s extraction.
**Size:** the largest stage. One table, one idempotent append path, one
resolution rule per receipt family.

One row per `{issue, commit, receipt family, receipt id, actor}`, unique on
the tuple so replay and reconciliation cannot duplicate it — the property
`#69` demands and that `Pushes.reconcile_receipts/1`
(`lib/openagents/forge/pushes.ex:169`) will exercise on every WAL replay.
Populate it from three sources: `#130`'s trailer extraction for the
commit-to-issue half, `forge_assignments.terminal_commit` for an attempt's
self-reported revision, and a sha-keyed read of the receipt chain for the
rest (`Forge.receipts_for/2`, `forge.ex:60`). Refuse a deployment receipt for
another commit or environment, which is `#69`'s acceptance criterion. Note the
honest bound: `receipts_for/2` scans a window and a sha older than it returns
empty, so the edge must be written when the receipt is written rather than
scanned for later. This is E4 and E5.

### Stage 5 — tiers over work and receipts

**Seam:** `ArtifactLink.artifact_types/0` and every issue-timeline read.
**Size:** small storage change, wide read change.

Add `work_job`, `attempt`, `deployment`, and `trace` to the artifact-type
list and its check constraint, attach a link to each edge stage 4 records, and
route every timeline and API read through `Transparency.allows?/3`. The
acceptance property is `#70`'s: the same viewer gets the same answer on the
web page, the API, and an export. This is E6.

### Stage 6 — close from verified outcomes

**Seam:** a durable claim record and a per-repository policy.
**Size:** medium, and it should be last.

Store the claim keyed on `{issue, attempt, revision}`, evaluate it with
`AcceptedOutcome.evaluate/1`, record the typed result, and let a repository
opt in to closing from an `accepted` result. Trailer-driven closing from
`#130` is unaffected. This is E7.

### What each blocked issue needs, and from where

| Issue | Needs | From |
| --- | --- | --- |
| `#67` — coverage manifests before agent-authored changes qualify | A qualification attempt to bind a manifest to, and an issue timeline that can show what a verifier covered without exposing private source | **Stage 4** for the receipt-to-issue edge and the exact-commit binding; **stage 5** for the redaction. The manifest itself is `#67`'s own storage; it needs the attempt's `{repository, commit, verifier}` triple to hang from, and stage 1's `work_job_id` to reach the verifier's budget and authority snapshot |
| `#69` — exact qualification and deployment receipts on issue timelines | Stable identifiers rather than commit prose; idempotent append; several attempts without losing history; independent artifact visibility | **Stage 1** already gives it the attempt identifiers and the multi-attempt history (the partial unique index preserves terminal attempts). **Stage 4** is the substance: the idempotent evidence table and the exact-commit-and-environment refusal. **Stage 5** gives it the independent visibility. It does not need stages 2, 3, or 6 |
| `#71` — per-deployment release notes from receipt chains | A completed deployment receipt, the issues in its commit range, and a tier per linked artifact | **Stage 4** for the issue-to-commit-to-deployment chain, **stage 5** for the per-artifact tier. `#71` also needs `#130`'s commit-to-issue extraction to resolve a commit range to issues, and the existing `changelog_entries` join (`entry.ex:34`) is the closest working model for the note-over-receipts shape |

`#71` depends on `#69`, which depends on `#10`. Shipping stage 4 unblocks
both, and stage 5 completes them.

---

## 7. What stage 1 shipped

Stage 1 landed with this document. It is read-only from the issue's side: it
adds no route, no write path, and no new work record.

**Storage.**
`priv/repo/migrations/20260823180051_link_forge_assignments_to_work_jobs.exs`
adds a nullable `work_job_id` foreign key to `forge_assignments` with
`on_delete: :nilify_all`, backfills it from
`work_jobs.delegation ->> 'assignment_id'` for delegation-kind jobs, and
indexes it. The migration version is registered in
`priv/migration_lineages/prior-2026-08-19.json` under `new_versions_to_run`,
which `OpenAgents.MigrationLineageTest` requires.

**Write.** One line: `Assignments.start_target/7` records the job id the
moment `ComputerAgentJobs.start/5` returns it
(`lib/openagents/forge/assignments.ex:112`), through `record_work_job/2`
(`:125`), which fails soft — a link that cannot be written never fails the
delegation that was already admitted.

**Read.** `Assignments.attempts_for_issue/1` (`:143`) for one issue, and
`attempts_for_issues/1` (`:161`) for a page in one query, the way
`Issues.dependency_graph/1` reads prerequisites. Both return every issue they
were asked about, with `[]` for an unworked issue.
`Assignments.attempt_summary/1` (`:186`) is the single bounded projection both
surfaces render, so the page and the API cannot disagree.

**API.** `issue.openagents.work` is an array of attempts, oldest first, on
every issue response (`lib/openagents_web/controllers/issue_json.ex:98`),
registered with its type and enums at `GET /api/v3`
(`lib/openagents_web/controllers/api_extension_controller.ex:36` and `:133`).
`OpenAgentsWeb.ApiExtensionGovernanceTest` fails if a served field is not
enumerated there, so the field is governed rather than documented.

**Page.** The attempts join the existing timeline as derived events
(`lib/openagents_web/live/issue_show_live.ex:646`).

**Tests.** `test/openagents/forge/assignment_work_link_test.exs` covers the
empty case, ordering, the terminal commit, the excluded keys, cross-issue
isolation, the job join in both directions, and the foreign-key refusal. The
API extension tests cover the empty array, ordering, the exact key set, and
the index page. The LiveView tests cover both attempt events and the unworked
issue. `POOL_SIZE=8 MIX_TEST_PARTITION=lane10 mix precommit` passes: 3,165
tests, no warnings.

---

## 7b. What stage 2 shipped

Stage 2 landed in `#145`. It adds one authorized write path and no storage.

**The seam.** `OpenAgentsWeb.IssueShowLive` reaches
`OpenAgents.Forge.Assignments.create/1` directly. The API route stays as it
was: `OpenAgentsWeb.AssignmentController` authenticates a bearer token through
`AssignmentControlAuth` and has no session path, so a signed-in page could not
have used it without minting a token. Both surfaces enter the same admission,
which is what stops a second executor from appearing.

**What the control offers.** Connected Computers only. A Box target needs a
conversation-scoped box and `OpenAgents.Box.list_boxes/1` refreshes provider
state per box, which is a network call per row on a page render; the Computer
path from `#127` needs neither. A computer is offered only when it is active,
online, has at least one allowed root, and published at least one ACP agent,
because a computer failing any of the four produces a refusal nobody can act
on.

**What comes from where.** The objective is built from the issue's number,
title, and body. The branch defaults to `agent/issue-{number}` and is never the
default or a protected branch. The working directory and the agent are chosen
from the computer's own `roots` and probed `acp_agents`, so a crafted event
cannot widen the scope the computer published. The deadline is the assignment
TTL, which is the budget the attempt is bounded by.

**One bug fixed on the way.** `Assignments.persist_assignment/7` used
`Repo.insert!`, so `forge_assignments_one_active_issue_index` raised
`Ecto.InvalidChangesetError` instead of returning `:assignment_issue_claimed`.
`claim_error/1` had been written for exactly that case and was unreachable for
it, and no test covered the refusal. The insert now returns its changeset and
rolls back, so an issue with a live attempt is refused by name and the page can
say which branch holds it.

**Contract.** `INVARIANTS.md`, `ISSUE-004`.

**Tests.** `test/openagents_web/live/issue_start_work_live_test.exs` covers who
is offered the control, an anonymous and a signed-in reader refused at the
event rather than only hidden, the attempt reaching the timeline without a
reload, the objective coming from the issue, a protected branch refused by
name, a crafted working directory replaced rather than forwarded, and the live
attempt naming its branch.

**What it does not do.** The page does not subscribe to the running attempt, so
progress and a cancel control still need a reload — that is stage 3.

---

## 7a. What stage 4 shipped

Stage 4 landed in `#148`. It adds one edge table and no work record.

**Storage.** `priv/repo/migrations/20260824011303_create_issue_evidence.exs`
creates `issue_evidence`: one row per `{issue, commit, family, receipt id}`,
with `plane`, `environment`, `result`, `actor`, `source`, and a nullable
`assignment_id`. The unique index is `{issue_id, commit_sha, family,
receipt_id}` rather than the tuple including the actor, because a receipt id is
the identity of the evidence and an actor resolved differently on replay would
otherwise write the edge twice. The migration also indexes `{repo, sha}` on
`forge_builds` and `forge_deploys`, which nothing indexed before, so neither
direction of the join needs a window scan. The version is registered in
`priv/migration_lineages/prior-2026-08-19.json`.

**Write, from the receipt side.** `OpenAgents.Issues.Evidence.record/1` reads
the receipt row back before writing, so a caller that names another commit or
another environment is refused. It is reached from every place a receipt is
created: `ClosingReferences.insert_and_close/6` for the push receipt, in the
same transaction that records the close; `Forge.Builder` on both build
outcomes; `Forge.Targets` and `Forge.HotLoader` for the three forge deployment
receipts; `Deployments.publish_check_result/3` for the qualification receipt;
and `Deployments.transition/4` for a terminal tenant run.

**Write, from the attempt side.** `Evidence.bind_attempt/1` runs when
`Assignments.finish/4` records a terminal commit and sweeps `{repo, sha}` for
receipts that already exist. The two directions meet on the same unique index,
so ordering does not matter and neither writes twice.

**Resolution.** `Evidence.claimants/2` reads `issue_closing_references` first
and `forge_assignments.terminal_commit` second, dropping an issue the trailer
already claimed. There is no second commit-to-issue extractor:
`OpenAgents.Forge.CommitReferences` remains the only reader of commit prose.

**Read.** `Evidence.for_issue/1` and `for_issues/1`, and the bounded projection
`summary/1`, which carries the receipt's identity and outcome and nothing about
the execution that produced it. `issue.openagents.evidence` is an array on
every issue response, registered with its type and enums at `GET /api/v3`.

**Contract.** `INVARIANTS.md`, `ISSUE-003`.

**Tests.** `test/openagents/issues/evidence_test.exs` covers the empty case,
both resolution sources and their precedence, the commit and environment
refusals, a push receipt refused as a deployment receipt, replay through
`ClosingReferences.apply_commit/5` and through `bind_attempt/1`, failed and
reverted receipts surviving, both planes, the bounded projection, and the
absence of any work-record column. The issue controller tests cover the empty
array, ordering, the exact key set, and the index page.

**What it does not do.** The issue page does not render the chain yet, and no
transparency tier gates it — that is `#69` and stage 5. The evidence is served
to a reader who can already read the issue, and to no one else.

---

## 8. Open questions

- **What happens to `scv_runs.issue_id`?** ~~Open.~~ **Settled by `#152`: the
  column is dropped, and its one reader now reads the assignment.**

  Three facts decided it. Nothing wrote the column: `Executions.claim/4` read
  an `:issue_id` option that no caller passed, and `SCV.CodexRuns.start/5` has
  no caller in `lib/` at all, so the edge was unreachable in production.
  Section 2 of this design already names `forge_assignments` as the one row
  allowed to bind an issue to an attempt, so a second binding could only ever
  disagree with it. And `docs/2026-08-23-thread-primitive-audit.md` had
  independently ruled that `scv_runs` cannot be the primary agent record, which
  is why `threads` shipped borrowing its column shape rather than extending it.

  **One reader did exist, and it is the reason this mattered.**
  `OpenAgents.TokenProductivity` — the `/admin/tokens` operator surface —
  graded tokens by outcome through `scv_runs.issue_id`: merged work was "an SCV
  run whose issue carries a merged pull request", and closed issues was the
  same run whose issue closed. Because nothing ever wrote the column, both of
  those buckets were structurally zero and always would be. A column nobody
  writes is cheap; a metric anchored to it is not, because it reports a real
  number that can never move.

  `#152` re-pointed those two buckets at the record that does carry the edge: a
  work job reached through `forge_assignments.work_job_id`, graded on
  `forge_assignments.issue_id`. That edge is written by the `#108` and `#127`
  paths, so the buckets can now be non-zero, and the ids are read as sets so an
  issue with two merged pull requests, or a job two assignments name, still
  counts its usage once. An SCV run keeps the verified-receipt bucket, which
  needs only its own terminal receipt.

  Folding the column in was the other real option, and it was rejected on
  timing rather than on principle. Making a Codex run an assignment target the
  way `#127` made a connected Computer one is the right shape, but there is
  nothing yet to assign: the lane has no dispatcher caller, and wiring an
  attempt record to a dispatcher nothing reaches would add a second unexercised
  path instead of removing one. Keeping the column with a note was rejected
  too — a nullable column nobody can explain is how the fourth record appeared
  in the first place.

  **What would make it live.** A production caller for
  `SCV.CodexRuns.start/5`. When one exists, that caller creates a
  `forge_assignments` row with a Codex target kind, the way `#108` did for a
  Box and `#127` did for a connected Computer, and the assignment points at the
  run. The issue timeline then reads the Codex lane through the same projection
  as every other attempt — `Assignments.attempts_for_issue/1` — and
  `OpenAgents.TokenProductivity` grades it through the same assignment as every
  other execution, rather than through a fourth table.
  `docs/scv-codex-app-server-planning.md` records the same decision next to the
  checkpoint that would have to change.
- **Which qualification record is the one? Settled: `deployment_check_results`.**
  Stage 4 binds it and not `settlement_verifications`, for a reason that is
  structural rather than a preference. A check result is repository-scoped and
  pins `{repository, name, commit, artifact digest}`
  (`lib/openagents/deployments/check_result.ex:25`), so it resolves to an issue
  through the repository the issue lives in. A settlement verification is keyed
  on a **claim** and carries no repository at all
  (`lib/openagents/settlement/verification.ex:23`); it exists only when a
  priced specification is standing behind the work, and its authority is that
  claim. They are two events, not one event with two policies: a check result
  says the bytes qualified, a verification says a claimant earned a payout for
  them. `#67` binds its coverage manifest to the check result, whose artifact
  digest is exactly the anchor a manifest needs.
- **Do the sha-keyed receipt reads survive a stage-4 backfill? Settled: stage 4
  never uses them.** `Forge.receipts_for/2` and the changelog's
  `receipt_index/1` still scan bounded windows
  (`lib/openagents/forge.ex:60`, `lib/openagents/changelog.ex:148`) and are
  untouched. `OpenAgents.Issues.Evidence` writes the edge where each receipt is
  created, and its one catch-up path — an attempt that finishes after its
  receipts — queries `{repo, sha}` through indexes stage 4 added to
  `forge_builds` and `forge_deploys`. A commit's age therefore never changes
  the answer. Evidence written before this change does not exist, so there is
  no backfill to size; the earliest edge is the first receipt after deployment.
- **Should the receipt tables gain a repository foreign key? Settled by `#181`,
  and the answer is two tables, not three.** The three `repo` columns do not
  hold the same kind of value. `forge_pushes.repo` is `Repository.storage_key`,
  which carries a unique index, so a push receipt already names exactly one
  repository; it gained no key, because `EXIT-003` requires every column there
  to be re-derivable from the WAL and a key only PostgreSQL can produce would
  make the database a second opinion. `forge_builds.repo` and
  `forge_deploys.repo` hold `Target.repo` — a repository name, or an
  `owner/name` path — and `repositories` is unique on `{namespace_id,
  name_key}` rather than on `name`, so one string can answer for two
  repositories. Both gained a nullable `repository_id`, backfilled where the
  name settled to exactly one repository. Stage 4's refusal survives where it
  still applies: an unsettled name resolves to nothing, and nothing resolves to
  no evidence rather than to a guess.
- **Does the tenant deployment plane or the forge deployment plane own an
  issue's deployment evidence? Settled: both, and the row says which.** Stage 4
  records `plane` on every edge — `forge` for a `forge_deploys` receipt, whose
  one environment is the fleet, and `tenant` for a terminal `deployment_runs`
  row, whose environment is the one the run named. No reader infers the store
  from the shape of an id, and `#71` reads `plane` to know which deployment a
  release note describes.
- **What closes an issue when both `#130` and stage 6 could?** A commit
  trailer asserts; a verified outcome proves. If both fire, the issue should
  record both and close once. Settle the ordering with whoever owns `#130`
  before stage 6, not before stage 4.
- **Where do issue-linked traces live?** `docs/taxonomy.md:111` records
  "Issue-linked traces (work-system E6) are proposed", and the trace store is
  on the Node web app rather than here. Stage 5 can carry a `trace_ref` the
  way `changelog_entries` already does (`entry.ex:31`) without hosting a
  trace. Settle whether that is sufficient for E6 by checking whether the
  issue page must render a trace or only link to one.

---

## 9. Related records

- The issue: `#10`. Its delivery slices: `#69`, `#67`, `#71`, and `#70`
  (closed).
- The commit-to-issue extraction this design consumes rather than duplicates:
  `#130`.
- The typed-edge and extension-namespace pattern this follows: `#100`.
- Track E: `docs/2026-08-21-issues-projects-work-system-assessment.md`,
  E1 through E7.
- The definition of done for agent work:
  `docs/accepted-outcome-contract.md`, and `INVARIANTS.md`, `OUTCOME-001`.
- Transparency tiers: `INVARIANTS.md`, `TRANSPARENCY-001`, and
  `OpenAgents.Transparency`.
- Vocabulary: `docs/taxonomy.md` — receipt families, work job, attempt,
  the two deployment planes.
