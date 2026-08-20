# Issues and projects UI roadmap

Date: 2026-08-20

Status: Core surfaces and repository boundary implemented; staging UX validation pending

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
- Public API reads resolve only public repositories. Authenticated LiveViews
  and PAT writes resolve a writable repository membership before loading or
  changing a resource.
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
2. Add bounded search, filtering, pagination, and useful empty/loading/error
   states.
3. Add PubSub invalidation and database rereads where concurrent users need
   live updates.
4. Run accessibility, keyboard, responsive, compiled-CSS, and browser staging
   checks against the same candidate SHA.

Drag-and-drop boards, advanced project views, pull requests, review workflows,
and pixel-level compatibility with another forge remain planned rather than
current promises.
