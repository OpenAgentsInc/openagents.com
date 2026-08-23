# REST API

OpenAgents serves a bounded GitHub-shaped API under `/api/v3`. The paths make
familiar repository tooling easier to adapt, but OpenAgents does not implement
the complete GitHub API.

## Authenticate

API writes require an `oa_pat_` bearer token with `forge:write` scope. Create
and revoke tokens on [API tokens](/docs/api-tokens).

```sh
curl -H "Authorization: Bearer $OPENAGENTS_TOKEN" \
  https://openagents.com/api/v3/repos/OpenAgentsInc/openagents.com/issues
```

Public repositories allow anonymous reads. The repository, issue, and project
base read routes also accept an optional bearer token so a member can read a
private repository. Ancillary comment, label, assignee, and milestone read
routes remain public-repository reads in the current subset.

Use [Call the API with the CLI](/docs/cli-api) when you want the CLI to select
the API origin, load your stored credential, and return JSON.

## Repositories

```text
GET    /api/v3/user
GET    /api/v3/user/repos
POST   /api/v3/user/repos
POST   /api/v3/orgs/:org/repos
GET    /api/v3/repos/:owner/:repo
DELETE /api/v3/repos/:owner/:repo
POST   /api/v3/user/repos/imports
POST   /api/v3/orgs/:org/repos/imports
GET    /api/v3/repository-imports/:id
```

Repository writes require an `Idempotency-Key` header. The published
[`openagents.repositories.v1` contract](/api/contracts/repositories-v1.json)
defines request authority, lifecycle states, pagination, and stable error
codes. Only a repository owner can delete it. A successful deletion returns
`204 No Content`.

## Issues and comments

```text
GET    /api/v3/repos/:owner/:repo/issues
POST   /api/v3/repos/:owner/:repo/issues
GET    /api/v3/repos/:owner/:repo/issues/:issue_number
PUT    /api/v3/repos/:owner/:repo/issues/:issue_number
PATCH  /api/v3/repos/:owner/:repo/issues/:issue_number

GET    /api/v3/repos/:owner/:repo/issues/:issue_number/comments
POST   /api/v3/repos/:owner/:repo/issues/:issue_number/comments
GET    /api/v3/repos/:owner/:repo/issues/comments/:id
PUT    /api/v3/repos/:owner/:repo/issues/comments/:id
PATCH  /api/v3/repos/:owner/:repo/issues/comments/:id
DELETE /api/v3/repos/:owner/:repo/issues/comments/:id
```

List responses use named envelopes. For example, the issue list returns an
object with an `issues` array.

## Issue prerequisites

An issue can wait on other issues in the same repository.

```text
GET    /api/v3/repos/:owner/:repo/issues/:issue_number/dependencies
POST   /api/v3/repos/:owner/:repo/issues/:issue_number/dependencies
DELETE /api/v3/repos/:owner/:repo/issues/:issue_number/dependencies/:blocked_by_number
```

`POST` takes the issue numbers this issue waits on and returns the resulting
graph:

```json
{ "blocked_by": [9, 12] }
```

```json
{
  "blocked": true,
  "blocked_by": [{ "number": 9, "title": "Deliver the work system", "state": "open" }],
  "blocks": []
}
```

Every issue response carries the same object under `openagents`, and a response
that carries it names the namespace in the `x-openagents-extensions` header.
`GET /api/v3` lists the extension fields this deployment serves.

`blocked` is derived from the prerequisites' own state, so closing the last open
prerequisite unblocks the issue with no second write. The issue list filters on
it, which answers "what can an agent start right now":

```text
GET /api/v3/repos/:owner/:repo/issues?blocked=false
GET /api/v3/repos/:owner/:repo/issues?blocked=true
```

Prerequisites stay inside one repository. An unknown number, a self reference,
and an edge that would close a cycle each return `422 Unprocessable Entity`,
and none of the batch is recorded. Reading the graph needs the same access as
reading the issue. Recording or removing an edge needs repository write access.

## Labels

```text
GET    /api/v3/repos/:owner/:repo/labels
POST   /api/v3/repos/:owner/:repo/labels
GET    /api/v3/repos/:owner/:repo/labels/:name
PUT    /api/v3/repos/:owner/:repo/labels/:name
PATCH  /api/v3/repos/:owner/:repo/labels/:name
DELETE /api/v3/repos/:owner/:repo/labels/:name

GET    /api/v3/repos/:owner/:repo/issues/:issue_number/labels
POST   /api/v3/repos/:owner/:repo/issues/:issue_number/labels
DELETE /api/v3/repos/:owner/:repo/issues/:issue_number/labels/:name
```

Adding a label through the issue-label endpoint creates the label when it does
not exist. Creating an issue with an unknown label remains a validation error.

## Assignees and milestones

```text
GET    /api/v3/repos/:owner/:repo/assignees
GET    /api/v3/repos/:owner/:repo/assignees/:assignee
GET    /api/v3/repos/:owner/:repo/issues/:issue_number/assignees
POST   /api/v3/repos/:owner/:repo/issues/:issue_number/assignees
DELETE /api/v3/repos/:owner/:repo/issues/:issue_number/assignees

GET    /api/v3/repos/:owner/:repo/milestones
POST   /api/v3/repos/:owner/:repo/milestones
GET    /api/v3/repos/:owner/:repo/milestones/:milestone_number
PUT    /api/v3/repos/:owner/:repo/milestones/:milestone_number
PATCH  /api/v3/repos/:owner/:repo/milestones/:milestone_number
DELETE /api/v3/repos/:owner/:repo/milestones/:milestone_number
```

## Projects

```text
GET    /api/v3/repos/:owner/:repo/projectsV2
POST   /api/v3/repos/:owner/:repo/projectsV2
GET    /api/v3/repos/:owner/:repo/projectsV2/:project_number
PATCH  /api/v3/repos/:owner/:repo/projectsV2/:project_number
GET    /api/v3/repos/:owner/:repo/projectsV2/:project_number/notes
POST   /api/v3/repos/:owner/:repo/projectsV2/:project_number/notes
PATCH  /api/v3/repos/:owner/:repo/projectsV2/:project_number/notes/:note_id
DELETE /api/v3/repos/:owner/:repo/projectsV2/:project_number/notes/:note_id
GET    /api/v3/repos/:owner/:repo/projectsV2/:project_number/items
POST   /api/v3/repos/:owner/:repo/projectsV2/:project_number/items
PATCH  /api/v3/repos/:owner/:repo/projectsV2/:project_number/items/:item_id
GET    /api/v3/repos/:owner/:repo/projectsV2/:project_number/fields
POST   /api/v3/repos/:owner/:repo/projectsV2/:project_number/fields
```

The repository in the path controls visibility and write authority. Project
numbers are repository-local. Project creation through this REST path is an
OpenAgents extension; GitHub Projects V2 creation is not part of the assessed
GitHub REST surface.

A project update accepts `title`, `description`, and `state`, where `description`
is Markdown and `state` is `open` or `closed`. Each accepted change appends one
immutable activity entry to the project's notes.

The notes read is paginated and takes `page` and `kind`, where `kind` is `note`,
`activity`, or `all`. The response carries `notes`, `page`, `per_page`, and
`total_count`. Editing or deleting a note requires authorship: another member
with write access receives `403 Forbidden`, and an activity entry is never
editable. See [Projects](/docs/projects).

## Know the compatibility limits

- List responses use named envelopes such as `issues`, `comments`, `labels`,
  `milestones`, `assignees`, `projects`, `items`, and `fields`. GitHub commonly
  returns a bare array.
- Pagination, filters, link headers, and error envelopes form a bounded local
  contract. They do not provide complete Octokit or `gh` compatibility.
- Ancillary issue-resource reads do not yet use the optional-bearer pipeline
  for private repositories.
- A nonnumeric issue or milestone number can produce `500 Internal Server
  Error` instead of `404 Not Found`. Project number parsing fails closed with
  `404 Not Found`.
- Project update, archive, delete, item removal and ordering, field mutation,
  views, draft items, and organization projects are not implemented.

## Know what is not implemented

Pull requests, reviews, webhooks, releases, SSH Git transport, and Git LFS
object storage are outside the current subset.
