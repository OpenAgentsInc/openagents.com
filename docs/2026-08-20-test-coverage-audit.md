# Test coverage audit

**Date:** 2026-08-20
**Commit measured:** `dcbe8a4`
**Method:** `mix test --cover` (Elixir's built-in line coverage), 415 modules measured
**Suite state at measurement:** 939 passed, 0 failed, 9 excluded (`:cluster`, run separately)

---

## 0. Verdict

The question that prompted this audit was: *"we added a bunch of tests for issues/projects, do we have similar coverage for the rest of our codebase?"*

**The premise is inverted. The issues/projects layer is the least-tested code in the
repository — by a wide margin — and everything else is in good shape.**

| | modules | mean coverage | modules at 0% |
|---|---|---|---|
| **issues/projects (openagents.com-native)** | 37 | **33.0%** | **23 (62%)** |
| **everything else (ported from Sarah)** | 372 | **83.8%** | 13 (3%) |
| **Total** | 415 | **79.14%** | 41 (10%) |

The intuition behind the question is understandable: issues/projects is the surface that
was built here, test-first, with a written TDD workflow — so it *feels* like the well-tested
part. And its **domain schemas** genuinely are: `Issues.Issue`, `Labels.Label`,
`Milestones.Milestone`, `Projects.Project` are all at 100%.

What never got written is the **web layer**. Every LiveView, most controllers, and most JSON
views in that surface are at zero.

---

## 1. The gap maps exactly onto an abandoned plan

`AGENTS.md` §"Test-driven development workflow" defines a nine-step build order for this
surface and names `docs/github-api-issues-projects-assessment.md` as *"the source of truth
for paths, status codes, and JSON shape."* It states the discipline plainly:

> One endpoint at a time. Each new endpoint starts with a failing test before the route,
> controller, context, or schema exists.

Measured against that list:

| step | endpoint group | state |
|---|---|---|
| 1–4 | issues list / get / create / update | **covered** — `IssueController` 88.9%, `IssueJSON` 96.2% |
| 5 | comments | **covered** |
| 6 | assignees | **0%** |
| 7 | labels | **0%** |
| 8 | milestones | **0%** |
| 9 | projectsV2 | **0%** |

The discipline held for the first five steps and was dropped for the last four. This is not
a mystery gap; it is a plan that stopped being followed, and the coverage numbers mark the
exact line where it stopped.

## 2. The issues/projects layer, module by module

**Zero coverage (23 modules):**

```
OpenAgents.ProjectFields                 OpenAgentsWeb.IssueIndexLive
OpenAgents.ProjectFields.ProjectField    OpenAgentsWeb.IssueNewLive
OpenAgents.ProjectItems                  OpenAgentsWeb.IssueShowLive
OpenAgents.ProjectItems.ProjectItem      OpenAgentsWeb.LabelIndexLive
OpenAgents.ProjectFieldsFixtures         OpenAgentsWeb.MilestoneIndexLive
OpenAgents.ProjectItemsFixtures          OpenAgentsWeb.ProjectIndexLive
OpenAgentsWeb.AssigneeController         OpenAgentsWeb.ProjectShowLive
OpenAgentsWeb.IssueAssigneeController    OpenAgentsWeb.AssigneeIndexLive
OpenAgentsWeb.IssueLabelController       OpenAgentsWeb.LabelJSON
OpenAgentsWeb.LabelController            OpenAgentsWeb.MilestoneJSON
OpenAgentsWeb.MilestoneController        OpenAgentsWeb.ProjectJSON
OpenAgentsWeb.ProjectController
```

**Partial:** `Projects` 30.6%, `Issues` 37.8%, `Milestones` 78.6%, `Labels` 87.5%.

`OpenAgents.Issues` at 37.8% is the one to worry about: it backs the entire `/api/v3` issues
surface, which is the compatibility promise the GitHub-clone plan rests on.

**Two fixtures are themselves at 0%.** `ProjectFieldsFixtures` and `ProjectItemsFixtures`
exist in `test/support/fixtures/` but are referenced by no test. Fixtures that have never
been executed are not a head start — they are unverified code that looks like a head start.

**All eight LiveViews are at zero.** Not "thinly covered" — never executed by a test. Nothing
asserts that `/OpenAgentsInc/openagents.com/issues` renders at all.

## 3. Everything else is in good shape, with one honest exception

The ported subsystems average 83.8% with 198 modules at or above 90%. That coverage came
across with the code: the Sarah suite was lifted wholesale, and as of `dcbe8a4` every one of
those tests runs (all `@moduletag :skip` tags were deleted and `test_helper.exs` excludes
only `:cluster`).

The 13 non-issues/projects modules at 0% break down as:

- **Four derived `Inspect` implementations** and **two test-support modules**
  (`OpenAgents.Test.HordePeer`, `OpenAgentsWeb.SarahChannelCase`) — not production code.
- **`OpenAgents.Cluster.Drain` and `Cluster.RaBootstrap`** — these are a **measurement
  artifact, not a gap.** The coverage run excludes `:cluster`, and both are exercised by the
  9 tests in `mix test --only cluster`. Their true coverage is not zero; this run simply
  could not see it.
- **`Mix.Tasks.OpenAgents.BackfillVisitors`** — a one-shot backfill task.
- **Provider adapters:** `Memory.OpenAIEmbeddings`, `Voice.OpenAI.Sideband`,
  `Voice.Operations.LoadProbe`. These call out to OpenAI. The suite runs with no network by
  design (fakes are wired in `config/test.exs`), so these are covered through their
  behaviours rather than directly. Defensible.
- **`OpenAgents.Release`** — release-time migration entry point, only meaningful in a release.

**The one real gap: the recovery workers.** `TurnRecovery`, `VoiceRecovery`, `WorkRecovery`,
and `Memory.SemanticWorker` are at 0%. These are the code paths that run *after* something
has already gone wrong — a node died mid-turn, a voice session dropped, a durable job was
orphaned. They are exactly the code you cannot afford to have wrong, and nothing exercises
them.

**Important qualifier: this is inherited, not a port omission.** Verified directly — Sarah
has no tests for `TurnRecovery`, `VoiceRecovery`, `WorkRecovery`, or `SemanticWorker` either.
The port faithfully carried across a gap that already existed upstream. That makes it a
longer-standing risk than the issues/projects gap, not a lesser one, and it is not something
the port can be blamed for or expected to have fixed.

## 4. What this audit does not tell you

- **Line coverage is not test quality.** A module at 90% can still have every assertion
  checking the wrong thing. Treat these numbers as a map of where *nothing* is looking,
  not as a quality score.
- **The `:cluster` exclusion skews two modules** (see §3). Any future coverage run intended
  as a whole-repo number should union `mix test --cover` with
  `mix test --only cluster --cover`.
- **Coverage of a LiveView through a route** counts, so some modules that look covered are
  only incidentally exercised by a test aimed at something else.

## 5. Actions

In progress at the time of writing, in response to this audit. This section states intent,
not completed work — check the commits following `dcbe8a4` for what actually landed:

1. Tests written for the six untested `/api/v3` controllers and three JSON views, against
   `docs/github-api-issues-projects-assessment.md` as the contract — including error paths
   (404, 422), since status codes are part of a compatibility promise.
2. Tests written for all eight issues/projects LiveViews: mount, seeded records, empty
   state, and at least one interaction each. Assertions target ids, `aria-*`, and visible
   text rather than CSS classes, since this repo just migrated off DaisyUI onto basecoat.
3. `ProjectFields` and `ProjectItems` contexts and schemas covered; `Projects` and `Issues`
   raised from 30.6% and 37.8%. The two never-executed fixtures verified rather than assumed.

Left open, deliberately:

- **The recovery workers.** Worth its own task with the invariants in hand
  (`TURN-005`, `WORK-001`, `VOICE-009` all describe recovery behaviour that should be
  assertable). It needs upstream Sarah's design intent, not just a coverage number.
- **A coverage floor in CI.** `mix test --cover` currently exits non-zero against the default
  threshold but nothing gates on it. Once the issues/projects work above lands, setting a
  floor in `mix.exs` `test_coverage` would stop this recurring — the gap here did not appear
  suddenly, it accumulated unmeasured.
