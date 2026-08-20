# GitHub-shaped Issues and Projects API assessment

Date: 2026-08-20

Status: Implemented subset with known compatibility and authorization gaps

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
| `GET` | `/users/{username}/projectsV2` |
| `POST` | `/{owner}/projectsV2` |
| `GET` | `/users/{username}/projectsV2/{project_number}` |
| `GET, POST` | `/users/{username}/projectsV2/{project_number}/items` |
| `PATCH` | `/users/{username}/projectsV2/{project_number}/items/{item_id}` |
| `GET` | `/users/{username}/projectsV2/{project_number}/fields` |

The project-creation endpoint is an OpenAgents extension because the comparable
GitHub Projects V2 creation workflow is not supplied by the assessed REST
surface. Project update/delete, item delete/read, field mutation, views,
ordering, draft items, and organization projects remain unimplemented.

## Known blockers

These are current measured behaviors, not hypothetical future concerns:

- `/api/v3` uses the generic API pipeline and does not yet have a deliberate
  bearer/PAT authorization model for CLI clients.
- The route's owner/repository values are not backed by a canonical repository
  foreign key across the issue/project schema.
- Project show, item, update-item, and field actions do not consistently enforce
  the username in the route.
- The assignee read endpoints are placeholders while issue writes accept
  arbitrary login strings.
- Label rename does not implement GitHub's `new_name` behavior.
- Adding a nonexistent label, removing an absent label, and some label URL
  encoding cases differ from GitHub behavior.
- Error envelopes and pagination/link headers are a bounded local contract,
  not complete Octokit or `gh` parity.

Gate 6 must assign an explicit API principal and mutation policy. Gate 7 must
add repository entities, foreign keys, scoped uniqueness, one-query ownership
checks, and cross-repository isolation tests. Compatibility fixes follow those
authority boundaries rather than preceding them.

## Evidence

- `test/openagents_web/controllers/issue_controller_test.exs`
- `test/openagents_web/controllers/comment_controller_test.exs`
- `test/openagents_web/controllers/label_controller_test.exs`
- `test/openagents_web/controllers/issue_label_controller_test.exs`
- `test/openagents_web/controllers/assignee_controller_test.exs`
- `test/openagents_web/controllers/issue_assignee_controller_test.exs`
- `test/openagents_web/controllers/milestone_controller_test.exs`
- `test/openagents_web/controllers/project_controller_test.exs`
