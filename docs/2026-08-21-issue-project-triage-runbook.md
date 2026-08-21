# Issue and project triage assessment and runbook

Date: 2026-08-21

Status: Assessed against production at commit `a40a799`. The runbook describes
the interim process you can run today; the gap list describes what must change
before community issue submission works without manual steps.

## Purpose

OpenAgents just cut over to production, the first repository
(`OpenAgentsInc/openagents.com`) is being imported, and the goal is to start
building a public backlog: people read issues and submit them, maintainers
triage them, pull requests stay closed to the public for now.

This document has three parts:

1. What the issues-and-projects system implements today.
2. The gaps that stand between that implementation and public triage, ranked.
3. A triage process and runbook you can operate with what ships now.

## Part 1: What is implemented

### Identity and authority

- Sign-in is GitHub OAuth. Namespaces are keyed to immutable GitHub numeric
  IDs; logins are mutable projections.
- Browser mutations use the signed session. API writes use a personal access
  token (`oa_pat_…`) with the exact `forge:write` scope, created and revoked at
  `/settings/api-tokens`; plaintext is shown once.
- Repository roles are `owner`, `maintainer`, `contributor` (writable), and
  `viewer` (read-only). Every GitHub sign-in used to grant `contributor` on the
  initial repository; commit `348dcc8` removed that auto-grant, so membership
  is now explicit.

### Repositories and Git transport

- Create, one-time GitHub import, list, and view work through both the browser
  (`/repositories`, `/repositories/new`, `/repositories/import/github`) and
  the API (`POST /api/v3/user/repos`, `POST /api/v3/user/repos/imports`, and
  organization equivalents). Provisioning runs through a durable outbox.
- Git smart HTTP serves `https://openagents.com/{owner}/{repo}.git` plus a
  legacy `/git` compatibility route. Public repositories allow anonymous clone
  and fetch. Push requires repository membership with a writable role,
  authenticated by PAT over HTTP Basic or the CLI credential helper. Machine
  (`smct_…`) and operator lanes are separate.
- The CLI (`@openagentsinc/cli`, published on npm) handles auth login,
  `repo create|import|list|view|clone`, and Git credential setup.
- Public code browsing (repository home, commit, blob) reads from the WAL and
  requires no sign-in.

### Issues

The GitHub-shaped subset is implemented end to end:

- List, get, create, update, close, reopen with `state_reason`
  (`completed`, `not_planned`, `duplicate`, `reopened`).
- Comments (list, create, edit, delete).
- Issue numbers are repository-local; composite foreign keys make cross-
  repository references impossible at the database level.
- JSON API: anonymous public reads on `/api/v3/repos/{owner}/{repo}/issues`;
  token-authenticated writes.
- Web UI (`/:owner/:repo/issues`) has open/closed tabs, inline state changes
  with close reasons, inline assignee toggles, label and milestone pickers in
  the issue rail, and a comment timeline.

### Labels, milestones, and assignees

- Full CRUD through UI and API for labels and milestones.
- Assignees resolve to active repository members with writable roles;
  assignment of arbitrary logins is rejected.

### Projects V2

- Bounded subset: list, get, create projects; add items; update item field
  values; list fields.
- The board (`/:owner/:repo/projects/:number`) renders columns from the values
  of a "Status" project field ("To Do", "In Progress", "Done") and links items
  to issues.

### Analytics

PostHog captures `issue_created`, `issue_updated`, `issue_commented`,
`label_created`, `milestone_created`, `project_created`, and
`project_item_added` at the domain-context choke points, so triage activity is
measurable from day one.

### Tests

The issues-and-projects layer went from 33% to 98% line coverage in the
August coverage push; 23 previously untested modules including all eight
LiveViews are covered. Two real defects were found and fixed this way
(including a `ProjectShowLive` that had never rendered).

## Part 2: Gaps between here and public triage

Ranked by how much they block the stated goal. Items 1–3 block it outright.

### 1. No membership management surface — the blocker

`OpenAgents.Repositories.add_member/3` exists, writes audit records, and has
no caller anywhere in product code. OAuth no longer auto-grants membership.
Consequence: nobody who signs up from now on can see or touch issues, and
there is no UI, API, or admin page that fixes that. Today the only way to add
a maintainer or reporter is a production console command (see the runbook).

**Recommendation:** ship the smallest possible surface first — an owner-only
"Members" section on the repository settings page that lists members and adds
one by GitHub login with a role. It needs one context function that already
exists, audit records that already exist, and one LiveView.

### 2. Issue pages require writable membership

Every issue LiveView resolves the repository with
`Repositories.get_writable_by_path!/3`, which raises when the viewer lacks a
writable-role membership. A signed-in non-member gets an exception page instead
of a 404 or a read-only view, and an anonymous visitor cannot view issues at
all even on a public repository — while anonymous code browsing works.

The read path already exists: `get_visible_by_path!/3` returns public
repositories to anyone and private ones to any member, including `viewer`.

**Recommendation:** split reads from writes in the issue LiveViews. Read with
`get_visible_by_path!` (plus an anonymous path for public repositories), gate
every mutation behind writability, and render a clean "sign in to interact"
state otherwise. This is also what makes the public backlog readable, which is
the point of having one.

### 3. Submission policy is undecided

Today, opening an issue requires a writable membership, because `contributor`
was the only door in. That conflates two different grants: "can report bugs"
and "can push code". GitHub's model separates them: anyone signed in can open
an issue on a public repository; only collaborators can label, assign,
close, or edit.

**Recommendation:** adopt the GitHub model. Allow any active signed-in user to
create issues and comments on public repositories, recorded with their author
attribution, and keep every other mutation behind membership. This matches the
existing data model (issues already carry an author), keeps the API contract
unchanged, and turns "submit an issue" into a link instead of a manual grant.

Until that lands, the interim policy in Part 3 uses manual grants.

### 4. New repositories have no default labels

A freshly created repository has an empty label set, so the first triage pass
has nothing to attach. **Recommendation:** seed GitHub's default set on
repository creation (`bug`, `documentation`, `duplicate`, `enhancement`,
`good first issue`, `help wanted`, `invalid`, `question`, `wontfix`). Until
then, seed once per repository through the API (scripted in the runbook).

### 5. List ergonomics stop at open/closed tabs

The issue list has state tabs only: no filter by label, assignee, or milestone;
no search; no sorting; no pagination (the list loads every row). The design
ruling in `2026-08-20-linear-design-github-shape.md` notes grouping, sorting,
and filtering are free — arithmetic over existing responses — so these are low
risk. **Recommendation:** filter-by-label and filter-by-assignee first, then
pagination, then text search.

### 6. Concurrent triage has no live updates

Issue pages load once; there is no PubSub subscription, so two maintainers
triaging simultaneously see stale rows until reload. Repository provisioning
already demonstrates the broadcast pattern. **Recommendation:** subscribe the
issue index and show views to a per-repository topic and re-stream on change.

### 7. Known compatibility sharp edges

Pinned by tests, still present at `a40a799`. None block triage, but each will
bite a scripted client eventually:

- `LabelJSON` renders label URLs with `URI.encode_www_form/1`, so a label
  named `good first issue` advertises a URL its own endpoint cannot resolve.
- `PATCH .../labels/:name` ignores `new_name`; renaming is impossible through
  the API.
- Adding a nonexistent label to an issue returns 404 where GitHub creates the
  label.
- Removing a label an issue does not have is a silent no-op where GitHub
  returns 404.

**Recommendation:** fix the URL encoding first (it is a correctness bug in
advertised data), batch the rest into one compatibility pass.

### 8. Notifications do not exist yet

There is no email and no mention machinery; the mailer is development-only.
A backlog stays healthy when reporters hear back. Acceptable to defer while
the community is small and responses happen in chat, but it should not be
deferred past the first hundred external issues.

### 9. Pull requests stay out — deliberately

Pull requests, reviews, and fork workflows are unimplemented, and per the
current direction they should stay that way while the backlog forms. The Git
plane already enforces the useful half of this: only members with writable
roles can push, so external contribution is limited to issues until you decide
otherwise.

## Part 3: Triage runbook

### Roles

| Role | Can do |
| --- | --- |
| `owner` | Everything, plus member management (console until gap 1 closes) |
| `maintainer` | Triage: label, assign, milestone, close, edit any issue |
| `contributor` | Open and comment on issues; push if granted Git access |
| `viewer` | Read private-repository content; no writes |

While gap 2 stands, all of these roles also gate *viewing* the web UI, which
is why setup begins with grants.

### One-time production setup

Run these once, after the import finishes and the repository reports `ready`.

1. Verify the repository exists and is public:

   ```sh
   curl -s https://openagents.com/api/v3/repos/OpenAgentsInc/openagents.com | grep visibility
   ```

2. Seed the default labels. Run once per missing label:

   ```sh
   TOKEN=oa_pat_your_token   # created at /settings/api-tokens, forge:write scope
   BASE=https://openagents.com/api/v3/repos/OpenAgentsInc/openagents.com/labels

   for spec in bug:d73a4a documentation:0075ca duplicate:cfd3d7 \
     enhancement:a2eeef "good first issue:7057ff" help wanted:008672 \
     invalid:e4e669 question:d876e3 wontfix:ffffff; do
     name=${spec%%:*}; color=${spec#*:}
     curl -s -X POST "$BASE" -H "Authorization: Bearer $TOKEN" \
       -H "Content-Type: application/json" \
       -d "{\"name\": \"$name\", \"color\": \"$color\"}" >/dev/null
   done
   ```

3. Grant memberships to the initial maintainers. Until gap 1 closes this needs
   a console session on a production node:

   ```elixir
   alias OpenAgents.{Accounts, Repo, Repositories}

   repo = Repositories.get_by_path!("OpenAgentsInc", "openagents.com")
   user = Repo.get_by!(Accounts.User, github_login: "their-github-login")
   Repositories.add_member(repo, user, "maintainer")
   ```

   Grant `maintainer` to everyone who will run triage; keep `owner` to two or
   three people. Each call writes an `Audit` record.

4. Create the first milestone so work has a destination:

   ```sh
   curl -s -X POST "$BASE/../milestones" -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"title": "Backlog hygiene", "description": "First triage sweep", "state": "open"}'
   ```

5. Create a project for the public board:

   ```sh
   curl -s -X POST "https://openagents.com/api/v3/OpenAgentsInc/projectsV2" \
     -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
     -d '{"title": "openagents.com roadmap"}'
   ```

   Then add its Status field values ("To Do", "In Progress", "Done") through
   the project fields API, and pin high-signal issues to the board with
   `project_item_added`.

6. Record who holds which role in your own notes; there is no UI to look it up
   until gap 1 closes.

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
6. Sweep the closed tab briefly: a wrong close is cheaper to catch the same
   day than next week.

Everything above mutates through either the issue rail in the UI or the
equivalent PATCH calls below.

### The weekly review

1. Walk the project board column by column. "In Progress" older than a week
   gets an owner, a milestone, or moves back to "To Do".
2. Check the milestone: scope fixed, due date honest, nothing stuck.
3. Skim PostHog for `issue_created` volume versus `issue_commented` — a rising
   creation rate with flat response rate means triage is falling behind.
4. Confirm every new triage participant has a membership row (console check
   until the members UI exists).
5. File the meta-issue: anything about the triage process itself that hurt
   this week becomes an issue labeled `enhancement` on this same tracker.

### Interim community submission policy

Until gaps 1–3 close, the honest flow for an outside reporter is:

1. They sign in with GitHub at `openagents.com`.
2. You grant their account `contributor` from the console (step 3 of setup).
3. They open issues and comment; they cannot push unless you separately intend
   them to, since Git push checks the same membership table but is a distinct
   decision you control by role.

Publish this expectation wherever you announce the tracker, or hold public
submissions until the GitHub-model change lands — a crash page for eager
first-time reporters is worse than "issue tracker opens next week".

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

Close as not planned:

```sh
curl -s -X PATCH "https://openagents.com/api/v3/repos/OpenAgentsInc/openagents.com/issues/42" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"state": "closed", "state_reason": "not_planned"}'
```

Label and assign in one update: `labels` takes names, `assignees` takes
logins, and both replace the full set, so send the complete desired lists.

### Measuring triage health

PostHog events land at the domain boundary, so the funnel is queryable:

- Median time from `issue_created` to first `issue_commented` by a maintainer:
  your response-time promise.
- `issue_created` count per week versus issues closed per week: backlog
  direction.
- Share of issues carrying zero labels after 24 hours: triage loop discipline.

Track them as three insights on one dashboard before the first announcement;
retrofitting measurement onto a neglected backlog is miserable.

## Guardrails

- Do not widen Git push beyond repository members; that is the mechanism that
  keeps public participation issue-shaped while pull requests remain closed.
- Do not grant `maintainer` casually: triage roles can close and rewrite
  anyone's issues.
- Keep every membership change flowing through `add_member/3` so audit
  records accumulate; when the members UI lands it inherits the trail.
- When you fix gaps 1–3, update this document the same day; a runbook that
  says "use the console" one commit longer than necessary is how stale
  instructions become incident reports.
