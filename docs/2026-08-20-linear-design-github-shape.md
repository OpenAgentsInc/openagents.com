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

Three places, and only three. Everything else is a false conflict.

### 1. Status: two categories versus six

GitHub's issue has `state`, and it is binary — `open` or `closed` — with
`state_reason` narrowing a close (`completed`, `not_planned`, `duplicate`,
`reopened`). Circle's issue has six: backlog, todo, in progress, in review,
done, cancelled.

The temptation is to add a `status` column. That breaks parity the moment a
client reads it, because the client asked for a GitHub issue.

**GitHub has already solved this, and recently.** The current issue schema
carries `issue_field_values`, an array of typed custom fields:

```
issue-field-value: issue_field_id, issue_field_name, data_type, value,
                   single_select_option, multi_select_options
data_type: text | single_select | multi_select | number | date
```

A `single_select` field named Status, whose options are the six categories, is
**exactly** how GitHub models this today. It is not a workaround. We already
have `project_fields` with `name`, `data_type` and `options`, which is the same
shape one level up.

The mapping that keeps both promises:

| Reading | Writing |
| --- | --- |
| `state` stays derived: anything but done/cancelled is `open` | a client writing `state: "closed"` sets the Status field to done |
| `state_reason` derives too: cancelled → `not_planned` | a client writing `state_reason: "not_planned"` sets cancelled |
| the Status field is the richer truth | the UI writes the field; `state` follows |

A GitHub client sees an issue that opens and closes. A person sees six
categories. Neither is being lied to, because `open` genuinely is "not done and
not cancelled".

### 2. Priority: GitHub has no such field

Circle has four levels. GitHub has none — priority is conventionally a label
(`priority: high`), which is why every GitHub-shaped tool grew a label
convention.

Same answer, and it is the better one: a `single_select` custom field named
Priority. Labels stay labels — a flat, user-defined vocabulary — instead of
being overloaded into an ordered scale they cannot express. `issue_priority/1`
already renders four levels from one shape, so the UI is waiting on the field,
not the other way round.

If a client expects the label convention, emit **both**: the field is the
truth, a `priority: high` label is a projection for tools that only read
labels. Projections are cheap; a second source of truth is not.

### 3. Grouping and cycles

Circle groups by status, assignee, priority, or project, and has cycles.
GitHub's list endpoint filters (`state`, `labels`, `assignee`, `milestone`,
`since`) but does not group, and has milestones rather than cycles.

Grouping is a **view** concern: the list endpoint returns issues, the page
groups them. Nothing to reconcile — do not add a `group_by` parameter to a
GitHub-shaped endpoint.

Cycles are not milestones and should not pretend to be. A milestone has a due
date and a fixed scope; a cycle is a repeating window that rolls unfinished
work forward. Until there is a reason to model cycles, milestones are the
GitHub-shaped answer and the UI should say "milestone".

## What GitHub gives us that Linear's model does not

Worth noting, because the parity constraint is not purely a tax. The current
schema also carries:

- **`type`** — an issue type (bug, feature, task) with a colour, enabled per
  org. Circle's issue has no equivalent.
- **`sub_issues_summary`** — `total`, `completed`, `percent_completed`. Native
  parent/child issues.
- **`issue_dependencies_summary`** — blocking relationships.

Circle's UI has no vocabulary for these, so they are ours to design rather than
port. The progress arc from `issue_status/1` is the obvious renderer for
`sub_issues_summary.percent_completed` — it already fills from a number.

## Rules of thumb

1. **A design decision that changes a payload is not a design decision.** If
   adopting a Linear pattern would add or rename a JSON field, stop: it belongs
   in a custom field, a projection, or the view layer.
2. **Custom fields before columns.** Anything Linear has and GitHub does not is
   a `single_select` field until proven otherwise. That is GitHub's own answer.
3. **Derive the compatibility surface, never the rich one.** `state` is
   computed from Status. Never the reverse, or the two drift and the API starts
   lying.
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

The Circle components exist and are catalogued; nothing renders them on a real
page yet, because doing so needs the Status and Priority fields above. That is
the next decision, and it is a schema decision rather than a UI one — which is
why the port stopped at the component library rather than guessing at it.

Order that follows from this doc:

1. Custom fields on issues (`issue_field_values`-shaped), with Status and
   Priority as the first two.
2. Derive `state` and `state_reason` from Status, both directions, with tests
   that a GitHub-shaped client sees no change.
3. Then wire `issue_row/1`, `issue_group/1` and `issue_toolbar/1` into the
   issue index, which by then is only a view change.
