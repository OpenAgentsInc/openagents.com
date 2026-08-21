# Issue and project triage assessment and runbook

Date: 2026-08-21

Status: Current. The gap list from the morning assessment is implemented and
covered by tests; this document records what ships, the pull-request product
stance, and how to operate triage day to day.

## Purpose

OpenAgents cut over to production, imported the first repository
(`OpenAgentsInc/openagents.com`), and opened the tracker for a public backlog:
anyone can read issues and, once signed in, file them. Maintainers triage.
Pull requests stay closed on this repository while the backlog forms, and the
product direction for them is written down below.

This document has three parts:

1. What the issues-and-projects system implements now.
2. The pull-request product stance and what deliberately remains unbuilt.
3. A triage process and runbook you can operate today.

## Part 1: What is implemented

### Identity and authority

- Sign-in is GitHub OAuth. Namespaces are keyed to immutable GitHub numeric
  IDs; logins are mutable projections.
- Browser mutations use the signed session. API writes use a personal access
  token (`oa_pat_…`) with the exact `forge:write` scope, created and revoked
  at `/settings/api-tokens`; plaintext is shown once.
- Repository roles are `owner`, `maintainer`, `contributor` (writable), and
  `viewer` (read-only). Membership is explicit and managed through product
  surfaces, not consoles.

### The participation model

Reading and writing split cleanly, GitHub-style:

| Who | Read issues | File issues | Comment | Triage (label, assign, milestone, close others') |
| --- | --- | --- | --- | --- |
| Anonymous visitor | Public repositories | No | No | No |
| Signed in, not a member | Public repositories | Yes | Yes | No |
| An issue's author | Their issue | Already filed | Yes | Edit title/body, close, reopen their own |
| Repository member with write role | All visible repositories | Yes | Yes | Yes |
| `viewer` member | Including private repositories | Yes | Yes | No |

Rules the server enforces, regardless of what any client renders:

- Issue reading runs behind plain `:browser`; the route ledger classifies it
  `public_read` with scope `forge:issues:web`. A hand-crafted event from a
  viewer without authority is refused with a flash message, never applied.
- Filing requires an identity: `/issues/new` stays behind sign-in, because an
  issue without an author cannot be triaged honestly. The author is recorded
  on the issue.
- Every mutation re-checks authority in the view's event handlers. The
  templates hide controls for viewers who lack them, but hiding is courtesy,
  not security.

### Membership management

`/:owner/:repo/members`, owner-only, lists members with roles and supports:

- Adding a member by GitHub login (the person must have signed in once).
- Changing roles across the four levels.
- Removing members.
- Last-owner protection: the final `owner` cannot be demoted or removed.

Every change flows through `OpenAgents.Repositories` functions that write
audit records naming the actor, subject, action, and role. Non-owners are
redirected; non-members get the same quiet bounce as a nonexistent
repository, so the page never confirms who has access to what.

### Repositories, Git transport, and code browsing

- Create, one-time GitHub import, list, and view work through the browser,
  the API, and the published CLI (`@openagentsinc/cli` on npm). Provisioning
  runs through a durable outbox.
- Git smart HTTP serves `https://openagents.com/{owner}/{repo}.git`. Public
  repositories allow anonymous clone and fetch. Push requires repository
  membership with a write role, authenticated by PAT over HTTP Basic or the
  CLI credential helper.
- Default labels seed automatically on every repository creation and import:
  `bug`, `documentation`, `duplicate`, `enhancement`, `good first issue`,
  `help wanted`, `invalid`, `question`, `wontfix`.

### Issue list ergonomics

The issue index has grown past open/closed tabs:

- Filters by label, assignee, and milestone, plus text search across titles
  and bodies (wildcards escaped; what you type is matched literally).
- Pagination at 25 issues per page with Previous and Next, and a row count.
- The Open and Closed tab counts respect the active filters, so the counts
  and the list always agree — they read the same query.

### Live updates

Every committed issue write broadcasts on a per-repository topic. The index
and detail views subscribe and re-read through the viewer's own authorization,
so two people triaging together converge instead of drifting. The message
carries the repository id and nothing else; subscribers re-read rather than
trust payloads.

### JSON API compatibility

Four pinned deviations from GitHub behavior were closed:

- Label URLs percent-encode as paths (`good%20first%20issue`), and the
  advertised URL resolves through the show endpoint.
- `PATCH .../labels/:name` renames through `new_name`.
- Adding a nonexistent label to an issue creates it with a generated color,
  instead of returning 404.
- Removing a label an issue does not wear returns 404, instead of silently
  succeeding.

Issue creation with unknown labels remains strict (422); the add-to-issue
endpoint creates on the fly, matching GitHub. Cross-repository isolation is
unchanged: composite foreign keys still make cross-repo references
impossible, and a name collision between repositories produces two
independent labels rather than a link.

### Analytics

PostHog captures `issue_created`, `issue_updated`, `issue_commented`,
`label_created`, `milestone_created`, `project_created`, and
`project_item_added` at the domain-context choke points.

### Tests

The suite covers all of the above: the participation matrix for anonymous
visitors, non-member filers, authors, and members; the members page including
last-owner protection; filter, search, and pagination semantics; broadcast
delivery; and each compatibility fix against the endpoint contract it
restores.

## Part 2: The pull-request product stance

Recorded direction, stated plainly so nobody has to rediscover it:

- Pull requests will exist as a general repository capability.
- They will be disable-able per repository.
- New repositories default to **enabled**.
- `OpenAgentsInc/openagents.com` defaults to **disabled**: contribution to
  this repository starts with issues, not patches.
- Priority is explicitly lower than smooth issue interaction, which is why it
  is not part of this pass.

Nothing about that stance needs guarding in the meantime, because the Git
plane already behaves as if pull requests were switched off everywhere: push
requires a writable repository membership, so external participation is
issue-shaped by construction. When the feature lands, the per-repository
switch turns the existing membership gate into a policy knob instead of a
hard rule, and this repository's switch starts at `off`.

Deliberately not built yet, in priority order:

1. Pull requests with a per-repository enable/disable switch.
2. Notifications (email or mentions). Acceptable while the community is small
   and responses happen in chat; revisit before the first hundred external
   issues.

## Part 3: Triage runbook

### Roles

| Role | Can do |
| --- | --- |
| `owner` | Everything, including managing members |
| `maintainer` | Triage: label, assign, set milestones, close, edit any issue |
| `contributor` | Triage, file and comment on issues, and push Git changes |
| `viewer` | Read visible repositories and join their issue conversations |

### One-time setup for this repository

The initial repository was imported before automatic label seeding shipped,
so give it the default vocabulary once. Either use the Labels page
(`/:owner/:repo/labels`) or run the equivalent calls:

```sh
TOKEN=oa_pat_your_token   # created at /settings/api-tokens, forge:write scope
BASE=https://openagents.com/api/v3/repos/OpenAgentsInc/openagents.com/labels

while IFS='|' read -r name color; do
  curl -s -X POST "$BASE" -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"$name\", \"color\": \"$color\"}" >/dev/null
done <<'LABELS'
bug|d73a4a
documentation|0075ca
duplicate|cfd3d7
enhancement|a2eeef
good first issue|7057ff
help wanted|008672
invalid|e4e669
question|d876e3
wontfix|ffffff
LABELS
```

Repositories created from now on get these labels automatically.

Then grant maintainer roles to everyone who will run triage:

1. Each person signs in at `openagents.com` once with GitHub.
2. An owner opens `/:owner/:repo/members`, adds their login with the
   `maintainer` role, and saves.
3. Keep `owner` to two or three people; the last owner is protected, but a
   single-owner repository still has a bus factor of one.

Finally, create a starting milestone and project so triaged work has a
destination:

```sh
curl -s -X POST "$BASE/../milestones" -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"title": "Backlog hygiene", "description": "First triage sweep"}'

curl -s -X POST "https://openagents.com/api/v3/OpenAgentsInc/projectsV2" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"title": "openagents.com roadmap"}'
```

Add the Status field values ("To Do", "In Progress", "Done") through the
project fields API, then pin high-signal issues to the board.

### Label vocabulary

Use GitHub's defaults and nothing else for now. The standing design ruling is
that priority labels are conventions, not contracts, so ordering lives in
milestones and the project board, not in label names.

| Label | Means | Who applies it |
| --- | --- | --- |
| `bug` | Something is broken | Triage |
| `enhancement` | New capability or improvement | Triage |
| `documentation` | Docs only | Triage |
| `good first issue` | Scoped enough for a newcomer | Maintainer |
| `help wanted` | Community input invited | Maintainer |
| `question` | Needs an answer before it is work | Triage; close as completed once answered |
| `duplicate` | Repeats another issue | Triage; close with reason `duplicate` |
| `invalid` | Not a real report | Triage; close with reason `not_planned` |
| `wontfix` | Real but declined | Maintainer; close with reason `not_planned` |

### The daily triage loop

Ten minutes, ideally same time each day:

1. Open `https://openagents.com/OpenAgentsInc/openagents.com/issues?state=open`.
2. For each unlabeled issue: reproduce or reason about the report, then apply
   one primary label (`bug`, `enhancement`, `documentation`, or `question`).
   If the report cannot be evaluated, ask your question as a comment and leave
   it labeled `question`.
3. Assign an owner to everything labeled `bug` or `enhancement` that you
   intend to act on. Unassigned means "nobody owns this"; say that honestly
   rather than leaving it ambiguous.
4. Close what is not work:
   - Duplicate: close with reason `duplicate`, comment with the issue number.
   - Declined: close with reason `not_planned`, apply `wontfix`.
   - Answered questions: close with reason `completed`.
5. Move anything scheduled onto the project board and into a milestone. The
   board is the promise; the milestone is the deadline.
6. Sweep the Closed tab briefly: a wrong close is cheaper to catch the same
   day than next week.

Use the filters to work in slices — `label:bug` for the bug sweep,
`assignee:you` for your queue, the search box to check whether a new report
duplicates an old one before you label it. The page updates live while other
maintainers triage alongside you.

### The weekly review

1. Walk the project board column by column. "In Progress" older than a week
   gets an owner, a milestone, or moves back to "To Do".
2. Check the milestone: scope fixed, due date honest, nothing stuck.
3. Skim PostHog for `issue_created` volume versus `issue_commented` — a
   rising creation rate with flat response rate means triage is falling
   behind.
4. Review the members list on the members page: departed maintainers lose
   their role the week they leave, not someday.
5. File the meta-issue: anything about the triage process itself that hurt
   this week becomes an issue labeled `enhancement` on this same tracker.

### Community submissions

The standing policy, publishable anywhere the tracker is announced:

1. Sign in with GitHub at `openagents.com`.
2. Open issues on any public repository — no invitation, no membership.
3. Expect triage: a maintainer labels and responds. Comments stay open, so
   the conversation continues on your issue.

Reporters who later become contributors get roles through the members page;
that is a deliberate human decision, not an automatic upgrade.

### API recipes

Read (anonymous, public repository):

```sh
curl -s "https://openagents.com/api/v3/repos/OpenAgentsInc/openagents.com/issues?state=open"
```

Create (requires `forge:write` token held by a member):

```sh
curl -s -X POST "https://openagents.com/api/v3/repos/OpenAgentsInc/openagents.com/issues" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"title": "Search returns duplicates", "body": "Steps to reproduce...", "labels": ["bug"]}'
```

Note the difference in kind: the JSON API's write path stays
membership-gated. The participation model is a browser-session contract; PAT
holders remain collaborators.

Close as not planned:

```sh
curl -s -X PATCH "https://openagents.com/api/v3/repos/OpenAgentsInc/openagents.com/issues/42" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"state": "closed", "state_reason": "not_planned"}'
```

Label and assign in one issue update: `labels` takes existing names,
`assignees` takes logins, and both replace the full set, so send the complete
desired lists. Use `POST .../issues/{issue_number}/labels` when you want a
missing label to be created as it is added.

### Measuring triage health

PostHog events land at the domain boundary, so the funnel is queryable:

- Median time from `issue_created` to first `issue_commented` by a
  maintainer: your response-time promise.
- `issue_created` count per week versus issues closed per week: backlog
  direction.
- Share of issues carrying zero labels after 24 hours: triage loop
  discipline.

Track them as three insights on one dashboard before the next announcement;
retrofitting measurement onto a neglected backlog is miserable.

## Guardrails

- Do not widen Git push beyond repository members; that is the mechanism
  that keeps public participation issue-shaped while pull requests remain a
  planned feature.
- Do not grant `maintainer` casually: triage roles can close and rewrite
  anyone's issues.
- Keep every membership change flowing through the members page so audit
  records accumulate; direct console edits skip the trail.
- When the pull-request switch ships, update this document the day it does:
  record where the setting lives, which repositories default which way, and
  flip `OpenAgentsInc/openagents.com` to `off` explicitly rather than relying
  on the default.
