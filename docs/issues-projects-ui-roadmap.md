# Issues and projects UI roadmap

Date: 2026-08-20

Status: Core surfaces implemented; tenant and design-system hardening pending

## Current surface

The Phoenix LiveView application currently ships authenticated pages for:

| Surface | Route | LiveView |
| --- | --- | --- |
| Issue list | `/:owner/:repo/issues` | `OpenAgentsWeb.IssueIndexLive` |
| New issue | `/:owner/:repo/issues/new` | `OpenAgentsWeb.IssueNewLive` |
| Issue detail and comments | `/:owner/:repo/issues/:number` | `OpenAgentsWeb.IssueShowLive` |
| Labels | `/:owner/:repo/labels` | `OpenAgentsWeb.LabelIndexLive` |
| Milestones | `/:owner/:repo/milestones` | `OpenAgentsWeb.MilestoneIndexLive` |
| Assignees | `/:owner/:repo/assignees` | `OpenAgentsWeb.AssigneeIndexLive` |
| Project list | `/:owner/:repo/projects` | `OpenAgentsWeb.ProjectIndexLive` |
| Project board | `/:owner/:repo/projects/:number` | `OpenAgentsWeb.ProjectShowLive` |

The matching `/api/v3` issue, comment, label, assignee, milestone, and Projects
V2 subset is implemented and covered. The dated
[coverage audit](2026-08-20-test-coverage-audit.md) records the original gaps
and the coverage added to close them.

## Interface rules

- Every page uses `Layouts.app` and the authenticated LiveView session.
- New reusable primitives come from `OpenAgentsWeb.UI`; domain compositions can
  live in a focused issue, project, or forge component module.
- Basecoat supplies pinned structural CSS and `assets/css/openagents.css`
  supplies product identity. Do not add a second component system.
- Forms use `Phoenix.Component.to_form/2` and stable DOM IDs.
- Issue, comment, and project-item collections use LiveView streams where the
  collection changes in place.
- Model-authored Markdown remains untrusted and passes through the one bounded,
  sanitized Markdown path selected by Gate 4.
- Icons come from the vendored set through `OpenAgentsWeb.UI.icon/1`; icon-only
  controls have accessible names.

The current component inventory and transitional generated helpers are
documented in [docs/component-library.md](component-library.md).

## Blocking domain work

The route shape currently looks repository-scoped, but the durable issue and
project data model does not yet enforce that scope. Gate 7 must complete this
before the tracker is treated as a multi-repository forge:

1. Add a canonical repository entity.
2. Add repository foreign keys and scoped uniqueness to issues, labels,
   milestones, comments, assignees, and repository projects.
3. Resolve every resource through owner, repository, and resource identity in
   one authorized query.
4. Reject cross-repository identifiers in application code and PostgreSQL.
5. Replace the hardcoded assignee projection with repository membership and
   authorization.
6. Enforce project ownership instead of ignoring the username in Projects V2
   routes.
7. Separate public reads from authenticated browser and API writes.
8. Rehearse the backfill of existing rows into the initial repository.

Until this work passes cross-repository isolation tests, the URL is
presentation context rather than a proven tenancy boundary.

## Remaining interface work

After Gate 7 establishes the domain boundary:

1. Reconcile every issue/project surface onto `OpenAgentsWeb.UI` and remove
   transitional generated component callers.
2. Extract repeated issue rows, comment threads, label selectors, milestone
   progress, and project columns only where doing so improves behavior and test
   ownership.
3. Add bounded search, filtering, pagination, and useful empty/loading/error
   states.
4. Add PubSub invalidation and database rereads where concurrent users need
   live updates.
5. Add repository authorization-aware actions and explicit refusal states.
6. Run accessibility, keyboard, responsive, compiled-CSS, and browser staging
   checks against the same candidate SHA.

Drag-and-drop boards, advanced project views, pull requests, review workflows,
and pixel-level compatibility with another forge remain planned rather than
current promises.
