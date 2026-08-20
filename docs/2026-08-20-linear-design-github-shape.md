# Linear's design language over GitHub's shape

*2026-08-20*

The principle, stated by the owner:

> Use the Linear/Circle design language as much as possible while keeping the
> UI/API shape at parity with GitHub, at least for now.

This doc says how those two survive each other. It is a strategy note, not a
plan of record: the tracker for the component work is
`docs/2026-08-20-circle-ui-port.md`, and the URL/API compatibility target is
`docs/github-api-issues-projects-assessment.md`.

## The two commitments are about different layers

They only look like they conflict.

**GitHub owns the contract.** Paths, resource names, JSON field names, status
codes. `/:owner/:repo/issues/:number`, `GET /api/v3/repos/:owner/:repo/issues`,
`state: "open" | "closed"`, `state_reason`, `labels[]`, `assignees[]`,
`milestone`. An existing client, a bookmark, a git remote, or a `gh`-shaped
tool should keep working after a hostname swap. That is a compatibility
promise, and compatibility promises are kept in the wire format.

**Linear owns the reading.** Density, type scale, what a row shows at rest and
on hover, how status is signalled, what a keyboard can reach, how much chrome
sits between a person and the work. None of that appears in a JSON payload.

So: **GitHub decides what a thing is called and where it lives. Linear decides
what it looks like and how it is operated.** Almost every design decision falls
cleanly on one side.

## Where they actually collide

Three places. The owner's ruling on all three is the same and it is the
strict one:

> I do not want custom fields. I would rather drop Linear concepts than munge
> them onto GitHub. Let us do GitHub API things only.

So the resolution below is not "find a GitHub-shaped home for every Linear
idea." It is: **if GitHub has no field for it, we do not have the concept.**

### 1. Status: two categories, not six

GitHub's issue has `state` — `open` or `closed` — with `state_reason`
narrowing a close (`completed`, `not_planned`, `duplicate`, `reopened`).
Circle has six categories.

We take GitHub's two. An issue is open or it is closed, and a closed one may
say why. Backlog, todo, in progress and in review are **not modelled**. They
are not renamed, not approximated by labels, and not stored anywhere.

What survives is the *rendering*: `issue_status/1` draws a ring for open and a
filled check for closed, which is a better-looking pair of glyphs than the two
we had, and costs nothing in the contract.

A note for later, recorded because it will come up: the current GitHub schema
does carry `issue_field_values` — typed custom fields with `single_select`
among the data types — and that is genuinely how GitHub itself models a
richer status today. It was the obvious answer and the owner has declined it.
The reason is worth keeping: a field that only our UI writes and only our UI
reads is a second model wearing the first one's clothes, and every client that
does not know about it sees an issue that is subtly wrong. Two honest states
beat six states that only one client understands.

### 2. Priority: dropped

GitHub has no priority field. We do not add one, and we do not adopt the
`priority: high` label convention either — a label is a flat, user-defined
tag, and an ordered scale pushed through it is a convention, not a contract.

`issue_priority/1` stays in the component library unused, the way
`pricing_column/1` does. When there is a GitHub-shaped place for it, the
renderer is ready. Until then the column simply is not there.

### 3. Grouping and cycles

Grouping is free and we take it. The list endpoint returns issues; the page
groups them by state, assignee, label, or milestone. No parameter is added to
a GitHub-shaped endpoint, and no data changes — grouping is arithmetic over a
response.

Cycles are dropped. A milestone has a due date and a fixed scope; a cycle is a
repeating window that rolls unfinished work forward. GitHub has the first, so
we have the first, and the UI calls it a milestone.

## What GitHub gives us that Linear's model does not

Worth stating, because the constraint is not only subtractive. The current
schema also carries:

- **`type`** — an issue type (bug, feature, task) with a colour, enabled per
  org. Circle's issue has no equivalent.
- **`sub_issues_summary`** — `total`, `completed`, `percent_completed`. Native
  parent/child issues.
- **`issue_dependencies_summary`** — blocking relationships.

These are real GitHub fields, so they are all fair game, and Circle has no
vocabulary for any of them. The progress arc in `issue_status/1` already fills
from a number, which makes it the obvious renderer for
`sub_issues_summary.percent_completed` — a Linear-derived control displaying a
GitHub-native fact, which is exactly the shape this whole document is arguing
for.

## Rules of thumb

1. **A design decision that changes a payload is not a design decision.** If
   adopting a Linear pattern would add or rename a JSON field, stop.
2. **No field, no concept.** Anything Linear has and GitHub does not, we do
   not have. Not as a custom field, not as a label convention, not as a column
   nobody else can read. Drop it and render what remains well.
3. **A component may outlive its data.** `issue_priority/1` and
   `project_row/1`'s health cell stay in the library, unused, until GitHub has
   somewhere to put them. An unused component costs a page in a catalogue; an
   invented field costs every client.
4. **Grouping, sorting, density, and keyboard access are free.** They touch no
   contract. Take all of them.
5. **Do not rename GitHub's nouns in the UI.** A milestone is called a
   milestone even if a cycle would be nicer, because the URL and the API say
   milestone and a person who follows one to the other should not have to
   translate.
6. **Tokens, not a second palette.** The same rule the component ports follow:
   Circle's design language arrives as composition and density, never as its
   colour values.

## Where this leaves the current work

The Circle components exist and are catalogued. The port stopped short of
rendering them on a real page because it thought a schema decision was
pending. Under this ruling there is none: the components take GitHub's fields
and leave the rest of their attributes at their defaults, which is what those
defaults are for.

Order that follows from this doc, now that no schema decision is pending:

1. Wire `issue_row/1`, `issue_group/1` and `issue_toolbar/1` into the issue
   index, passing only GitHub-shaped data: state, labels, assignees,
   milestone, comment count, number, title, author, timestamps.
2. The same for `project_row/1` on the project index.
3. Then grouping and sorting on the index, which is arithmetic over the
   existing response.

The blocker that stopped the component port is gone: there was never a schema
decision to make, only a decision not to make one.
