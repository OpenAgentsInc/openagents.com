# GitHub-shaped Issues and Projects API assessment

Date: 2026-08-20

Status: Repository-scoped subset implemented; bounded compatibility gaps remain

## Intent

OpenAgents exposes a bounded `/api/v3` subset so familiar GitHub-shaped clients
can interact with issues and project boards. The shape is a compatibility aid,
not a claim that the application implements the complete GitHub API.

The router and controller tests are the executable source of truth. This
document records the intended subset and known gaps; it must not be used to
infer authorization that the server does not enforce.

## Implemented issue subset

| Concern | Methods and paths |
| --- | --- |
| Issues | `GET, POST /repos/{owner}/{repo}/issues`; `GET, PATCH /repos/{owner}/{repo}/issues/{number}` |
| Comments | `GET, POST /repos/{owner}/{repo}/issues/{number}/comments`; `GET, PATCH, DELETE /repos/{owner}/{repo}/issues/comments/{id}` |
| Labels | `GET, POST /repos/{owner}/{repo}/labels`; `GET, PATCH, DELETE /repos/{owner}/{repo}/labels/{name}` |
| Issue labels | `GET, POST /repos/{owner}/{repo}/issues/{number}/labels`; `DELETE /repos/{owner}/{repo}/issues/{number}/labels/{name}` |
| Assignees | `GET /repos/{owner}/{repo}/assignees`; `GET /repos/{owner}/{repo}/assignees/{login}`; issue-assignee list/add/remove paths |
| Milestones | `GET, POST /repos/{owner}/{repo}/milestones`; `GET, PATCH, DELETE /repos/{owner}/{repo}/milestones/{number}` |

Cross-repository issue lists, organization issue lists, event/timeline APIs,
locks, dependencies, sub-issues, and suggestion APIs are not implemented.

## Implemented Projects V2 subset

| Method | Path |
| --- | --- |
| `GET, POST` | `/repos/{owner}/{repo}/projectsV2` |
| `GET` | `/repos/{owner}/{repo}/projectsV2/{project_number}` |
| `GET, POST` | `/repos/{owner}/{repo}/projectsV2/{project_number}/items` |
| `PATCH` | `/repos/{owner}/{repo}/projectsV2/{project_number}/items/{item_id}` |
| `GET, POST` | `/repos/{owner}/{repo}/projectsV2/{project_number}/fields` |

The project-creation endpoint is an OpenAgents extension because the comparable
GitHub Projects V2 creation workflow is not supplied by the assessed REST
surface. Project update/delete, item delete/read, field mutation, views,
ordering, draft items, and organization projects remain unimplemented.

## Enforced authority contract

These are current measured behaviors:

- `/api/v3` anonymous and optional-bearer reads and authenticated writes use
  separate pipelines.
  Writes require an expiring digest-only `oa_pat_…` bearer with exact
  `forge:write` scope. An authenticated person creates and revokes credentials
  at `/settings/api-tokens`; plaintext is shown once.
- Owner and repository path values resolve a canonical repository row. Public
  reads expose only repositories marked public; writes additionally require a
  writable membership for the PAT principal.
- Resource reads and mutations include repository ownership in their database
  query. Composite foreign keys reject cross-repository comments, label and
  assignee links, milestones, and project items.
- Issue and milestone numbers are repository-local. Project numbers are also
  repository-local for the repository-shaped LiveView surface.
- Project list, show, item, update-item, and field actions resolve the repository
  from the route. Public repositories allow anonymous reads. Private reads and
  every write require membership in that repository.
- Assignee reads return active repository members with writable roles, and
  issue assignment accepts only those members.

## Remaining compatibility gaps

These are compatibility limits, not authorization fallbacks:

- Issue creation with a nonexistent label returns 422; only the
  add-labels-to-issue endpoint creates labels on the fly, matching GitHub.
- Error envelopes and pagination/link headers are a bounded local contract,
  not complete Octokit or `gh` parity.

Closed on 2026-08-21, each pinned by tests: label rename through `new_name`,
create-on-add for missing labels at the issue-labels endpoint, 404 for
removing a label an issue does not wear, and path-correct percent-encoding of
label URLs so an advertised label URL resolves through the show endpoint.

Gate 6 supplied the explicit API principal and mutation policy. Gate 7 supplied
repository entities, foreign keys, scoped uniqueness, ownership checks, and
cross-repository isolation tests. Further compatibility work must preserve
those authority boundaries.

## Evidence

- `test/openagents_web/controllers/issue_controller_test.exs`
- `test/openagents_web/controllers/comment_controller_test.exs`
- `test/openagents_web/controllers/label_controller_test.exs`
- `test/openagents_web/controllers/issue_label_controller_test.exs`
- `test/openagents_web/controllers/assignee_controller_test.exs`
- `test/openagents_web/controllers/issue_assignee_controller_test.exs`
- `test/openagents_web/controllers/milestone_controller_test.exs`
- `test/openagents_web/controllers/project_controller_test.exs`
- `test/openagents_web/controllers/repository_isolation_controller_test.exs`
- `test/openagents/repositories_test.exs`
