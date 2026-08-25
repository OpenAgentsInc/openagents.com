# Issues and projects UI roadmap

Date: 2026-08-20

Updated: 2026-08-21

Status: Core surfaces, repository boundary, public issue reading, and triage
ergonomics implemented; staging UX validation pending

## Current surface

The Phoenix LiveView application currently ships these pages:

| Surface | Route | Access |
| --- | --- | --- |
| Issue list | `/:owner/:repo/issues` | Public on public repositories; filters, search, pagination, live updates |
| New issue | `/:owner/:repo/issues/new` | Any signed-in person on a public repository |
| Issue detail and comments | `/:owner/:repo/issues/:number` | Public read; participation per the model below |
| Members | `/:owner/:repo/members` | Repository owners only |
| Labels | `/:owner/:repo/labels` | Writable members |
| Milestones | `/:owner/:repo/milestones` | Writable members |
| Assignees | `/:owner/:repo/assignees` | Writable members |
| Project list | `/:owner/:repo/projects` | Writable members |
| Project board | `/:owner/:repo/projects/:number` | Writable members |

The matching `/api/v1` issue, comment, label, assignee, milestone, and Projects
V2 subset is implemented and covered. The dated
[coverage audit](2026-08-20-test-coverage-audit.md) records the original gaps
and the coverage added to close them. The
[triage runbook](2026-08-21-issue-project-triage-runbook.md) records the
participation model and its authority rules.

## Interface rules

- Every page uses `Layouts.app`. The issue list and detail pages mount in a
  public-read session; everything else requires an authenticated session.
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
- Hiding a control for an unauthorized viewer is courtesy, not security:
  every event handler re-checks authority at the server.

The current governed component inventory is documented in
[docs/component-library.md](component-library.md).

## Repository boundary

Gate 7 completed the durable repository boundary:

- `repositories` owns the stable repository ID, display and normalized path,
  visibility, and default branch. The explicit initial repository is
  `OpenAgentsInc/openagents.com`.
- Issues, labels, milestones, comments, projects, project items, issue-label
  links, and issue-assignee links carry repository ownership. Issue,
  milestone, and project numbers are unique within a repository.
- Public API reads resolve only public repositories. PAT writes resolve a
  writable repository membership before changing a resource. Browser issue
  pages follow the participation model recorded in the
  [triage runbook](2026-08-21-issue-project-triage-runbook.md): public read on
  public repositories, filing and commenting for any signed-in person, and
  triage writes for writable members only.
- Assignees are active repository members with a writable role. Arbitrary
  login snapshots are no longer accepted.
- Projects V2 compatibility paths enforce the requested username in show,
  item, update-item, and field actions. The user-shaped API is deliberately
  bounded to the initial repository because its URL has no repository segment.
- Composite PostgreSQL foreign keys prevent a comment, label relation,
  assignee relation, milestone reference, or project item from crossing its
  repository.
- The reversible migration was run down/up, populated with pre-scope rows, run
  up, validated, then run down/up again. It reconstructed repository,
  membership, author, label, assignee, milestone, project-owner, and
  project-item relationships.

Context, controller, and LiveView tests cover same-number resources in multiple
repositories, private-repository hiding, nonmember write refusal, wrong-owner
Projects V2 paths, and database constraint failures.

## Remaining interface work

With the domain boundary established:

1. Extract repeated issue rows, comment threads, label selectors, milestone
   progress, and project columns only where doing so improves behavior and test
   ownership.
2. Run accessibility, keyboard, responsive, compiled-CSS, and browser staging
   checks against the same candidate SHA.

Done on 2026-08-21: bounded search, filtering (label, assignee, milestone),
and pagination on the issue index; PubSub invalidation with database rereads
for issue surfaces; the members management page.

Drag-and-drop boards, advanced project views, notifications, pull requests
with a per-repository enable/disable switch, review workflows,
and pixel-level compatibility with another forge remain planned rather than
current promises.
