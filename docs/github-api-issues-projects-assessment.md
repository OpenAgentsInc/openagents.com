# GitHub-shaped Issues and Projects API assessment

Date: 2026-08-22

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
| Issues | `GET, POST /repos/{owner}/{repo}/issues`; `GET, PUT, PATCH /repos/{owner}/{repo}/issues/{number}` |
| Comments | `GET, POST /repos/{owner}/{repo}/issues/{number}/comments`; `GET, PUT, PATCH, DELETE /repos/{owner}/{repo}/issues/comments/{id}` |
| Labels | `GET, POST /repos/{owner}/{repo}/labels`; `GET, PUT, PATCH, DELETE /repos/{owner}/{repo}/labels/{name}` |
| Issue labels | `GET, POST /repos/{owner}/{repo}/issues/{number}/labels`; `DELETE /repos/{owner}/{repo}/issues/{number}/labels/{name}` |
| Assignees | `GET /repos/{owner}/{repo}/assignees`; `GET /repos/{owner}/{repo}/assignees/{login}`; `GET, POST, DELETE /repos/{owner}/{repo}/issues/{number}/assignees` |
| Milestones | `GET, POST /repos/{owner}/{repo}/milestones`; `GET, PUT, PATCH, DELETE /repos/{owner}/{repo}/milestones/{number}` |

Cross-repository issue lists, organization issue lists, event/timeline APIs,
locks, dependencies, sub-issues, and suggestion APIs are not implemented.

## Implemented Projects V2 subset

| Method | Path |
| --- | --- |
| `GET, POST` | `/repos/{owner}/{repo}/projectsV2` |
| `GET, PATCH` | `/repos/{owner}/{repo}/projectsV2/{project_number}` |
| `GET, POST` | `/repos/{owner}/{repo}/projectsV2/{project_number}/notes` |
| `PATCH, DELETE` | `/repos/{owner}/{repo}/projectsV2/{project_number}/notes/{note_id}` |
| `GET, POST` | `/repos/{owner}/{repo}/projectsV2/{project_number}/items` |
| `PATCH` | `/repos/{owner}/{repo}/projectsV2/{project_number}/items/{item_id}` |
| `GET, POST` | `/repos/{owner}/{repo}/projectsV2/{project_number}/fields` |
| `GET` | `/repos/{owner}/{repo}/projectsV2/{project_number}/items/{item_id}/events` |

The project-creation endpoint is an OpenAgents extension because the comparable
GitHub Projects V2 creation workflow is not supplied by the assessed REST
surface. Project delete, item delete/read, field mutation, views, ordering,
draft items, and organization projects remain unimplemented.

### Differences from GitHub Projects V2

These are deliberate divergences, not gaps waiting on parity work:

- A project carries one Markdown `description`. GitHub Projects V2 splits
  project prose into a short description and a separate README, and exposes both
  only through GraphQL. One canonical field keeps the API, the CLI, and the board
  describing the same thing.
- Project notes are an OpenAgents surface with no GitHub REST equivalent. They
  hold project-wide context — operating assumptions, triage decisions,
  provider-order changes, paused lanes — that would otherwise be filed as an
  issue comment on whichever issue happened to be open at the time.
- Discussion notes and activity entries share one table and one paginated read,
  distinguished by `kind`. An activity entry is immutable and is written in the
  same transaction as the change it records, so the log cannot describe an update
  that did not commit. GitHub keeps its equivalent record in a separate event
  API.
- Edit and delete authority for a discussion note is its author, not repository
  write access. Repository membership stays the authority boundary for the
  project itself.
- Notes are never embedded in the project object. A long-lived board accumulates
  decisions without bound, so the timeline is a separate paginated read.

### Toward a Linear-compatible shape

The longer-term direction is a Linear-shaped tracker, as recorded in
`docs/2026-08-20-linear-design-github-shape.md`. Project descriptions and notes
move that way without breaking the GitHub-shaped subset: a description maps onto
a Linear project's summary, and notes map onto project updates, which Linear
treats as first-class project-level records rather than comments on an issue. The
names stay GitHub-shaped where a GitHub client reads them, and the semantics stay
compatible with where the tracker is going.

## CLI access

`@openagentsinc/cli@0.2.1` exposes the complete implemented surface through
`openagents api`. The published CLI does not yet provide named `issue` or
`project` commands.

```sh
openagents api 'repos/OWNER/REPOSITORY/issues?state=all'
openagents api repos/OWNER/REPOSITORY/projectsV2
```

See [Call the API with the OpenAgents CLI](openagents-cli/api.md) for request
bodies, response envelopes, Issues recipes, and Projects recipes.

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
  assignee links, and milestones. A project item stores separate project and
  source-issue repository identities, so one board can include a readable
  issue from another repository without weakening project write authority.
- Issue and milestone numbers are repository-local. Project numbers are also
  repository-local for the repository-shaped LiveView surface.
- Project list, show, update, item, update-item, field, and note actions resolve
  the repository from the route. Public repositories allow anonymous reads.
  Private reads and every write require membership in that repository.
- A project update accepts only `title`, `description`, and `state`, and rejects
  a `state` other than `open` or `closed` with `422`. Repository and owner
  overrides in the request body are dropped.
- A project note stores both its project and its repository, and reads carry both
  in the query, so a note cannot be read or written across a repository
  boundary. Editing or deleting a note requires authorship: another member with
  write access receives `403`. An activity entry receives `403` for both.
- Item creation accepts either the legacy repository-local `issue_number` or
  an `issue` object with `owner`, `repo`, and `number`. Cross-repository adds
  require write access to the project repository and read access to the source
  repository. Item lists omit source issues that the current viewer cannot
  read. Promise registry items are an OpenAgents-specific extension. They use
  a stored `promise_state` field, state gates, resolvable evidence, and an
  append-only event history. This deliberately differs from GitHub Projects
  V2, which does not define these product-claim semantics.
- Assignee reads return active repository members with writable roles, and
  issue assignment accepts only those members.

## Remaining compatibility gaps

These are compatibility limits, not authorization fallbacks:

- Issue creation with a nonexistent label returns 422; only the
  add-labels-to-issue endpoint creates labels on the fly, matching GitHub.
- Optional-bearer private reads cover repository, issue, and project base
  routes. Comment, label, assignee, and milestone read routes remain
  public-repository reads.
- Nonnumeric issue and milestone numbers can produce `500 Internal Server
  Error` instead of `404 Not Found`.
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
- `test/openagents/project_notes_test.exs`
- `test/openagents_web/live/project_show_live_test.exs`
- `test/openagents_web/controllers/repository_isolation_controller_test.exs`
- `test/openagents/repositories_test.exs`
