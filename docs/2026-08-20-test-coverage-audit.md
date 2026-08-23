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

Completed. Measured after the work landed:

| | before | after |
|---|---|---|
| issues/projects layer, mean coverage | 33.0% | **98.1%** |
| issues/projects modules at 0% | 23 | **0** |
| repo total | 79.14% | **83.14%** |
| suite | 939 passing | **1218 passing** (+9 cluster) |

279 tests added across three parallel efforts:

1. **`/api/v3` steps 6–9** — 81 tests. All six untested controllers and three JSON views went
   from 0% to 89–100%, written against `docs/github-api-issues-projects-assessment.md`,
   including 404/422 error paths since status codes are part of a compatibility promise.
2. **The eight LiveViews** — 57 tests, all from 0% to 97–100%. Mount, seeded records, empty
   state, and every interaction each view has. Assertions target ids, `aria-*`, `role`, and
   visible text rather than CSS classes, since this repo just migrated off DaisyUI.
3. **Domain contexts** — 141 tests. `ProjectFields`, `ProjectItems`, `Projects`, `Milestones`,
   `Labels` to 100%; `Issues` from 37.8% to 96.9%. Both never-executed fixtures verified.

### What writing the tests found

Coverage was not the point; this was. Five defects, three of them user-visible:

- **`ProjectShowLive` was completely broken in production.** `@statuses` is a module
  attribute, but line 109 uses it *inside* `~H`, where `@statuses` means `assigns.statuses` —
  which `mount/3` never assigned (it assigns `:status_options`). Every request to
  `/:owner/:repo/projects/:number` raised `KeyError`. The project board had never rendered
  for anyone. This is the clearest argument for the audit: a 0%-coverage page was 100% broken
  and nothing said so.
- **Two 500s in `ProjectController`:** a missing or non-numeric `issue_number` reached
  `Repo.get_by!(Issue, number: nil)` (`ArgumentError`), and a non-map `values` reached
  `Map.merge` (`BadMapError`). Both now 422. Notably the *create* path already returned a
  correct 422 for the same input — the two paths disagreed.
- **Values silently dropped** in `Projects.create_project_item/2`: an atom-key clause read
  `attrs["values"]`, always `nil` for an atom-keyed map, so values were discarded on insert.
  The clause had no caller and was a strictly worse duplicate of the one below it.

### Findings reported rather than silently encoded

These are GitHub-compatibility gaps a real `gh`/Octokit client would hit. They were pinned as
current behaviour in tests, not "fixed" unilaterally:

- **`ProjectController` ignores `:username`** in `show`, `items`, `create_item`,
  `update_item`, and `fields` — verified, all five destructure it as `_username`; only
  `index` filters by owner. A project owned by `alice` is readable *and writable* at
  `/users/bob/projectsV2/:n`. Consistent across all five, so it reads as deliberate
  simplification, but it is an authorization gap rather than a shape mismatch.
- **`AssigneeController` is a hardcoded stub** — `index` always returns `%{assignees: []}`,
  `show` always 404s, so no user is ever reported assignable, while
  `POST .../issues/:n/assignees` accepts any login.
- `PATCH /repos/:owner/:repo/labels/:name` cannot rename a label (GitHub uses `new_name`;
  the path's `name` always wins and `new_name` is silently ignored).
- `POST .../issues/:n/labels` 404s for a label that does not exist yet, where GitHub creates
  it on the fly — and that 404 is indistinguishable from "issue not found".
- `DELETE .../issues/:n/labels/:name` is a silent no-op when the label is not on the issue;
  GitHub returns 404.
- `LabelJSON` renders `url` with `URI.encode_www_form/1` (spaces → `+`) while lookup decodes
  with `URI.decode/1`, so a label named `good first issue` renders a URL its own `show`
  endpoint cannot resolve.

### Dead code identified

`OpenAgents.ProjectItems` and `OpenAgents.ProjectFields` (the *context* modules, not the
schemas) have **zero callers in `lib/`** — generator scaffolding. The live paths go through
`Projects.*` instead. They are duplication with divergent semantics:
`ProjectItems.update_project_item/2` replaces `values` where `Projects.update_project_item/2`
merges them. Candidates for deletion. `Projects.create_project_field/1` also has no caller.

Left open, deliberately:

- **SCV baseline:** The SCV run test passed on clean pre-#109 revision `7146389`
  and on a fresh build of the current tree. The earlier full-suite failure was
  a stale-build or full-suite artifact, not a source defect; no SCV source
  change was required.
- **The recovery workers.** Worth its own task with the invariants in hand
  (`TURN-005`, `WORK-001`, `VOICE-009` all describe recovery behaviour that should be
  assertable). It needs upstream Sarah's design intent, not just a coverage number.
- **A coverage floor in CI.** `mix test --cover` currently exits non-zero against the default
  threshold but nothing gates on it. Once the issues/projects work above lands, setting a
  floor in `mix.exs` `test_coverage` would stop this recurring — the gap here did not appear
  suddenly, it accumulated unmeasured.
