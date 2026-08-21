# REST API

The API is shaped after GitHub's REST API and served under `/api/v3`. Check the
implemented paths and known differences before you point an existing client at
OpenAgents.

## Authentication

Bearer token. See [API tokens](/docs/api-tokens).

```
curl -H "Authorization: Bearer $OPENAGENTS_TOKEN" \
  https://openagents.com/api/v3/repos/OpenAgentsInc/openagents.com/issues
```

## Issues

```
GET    /api/v3/repos/:owner/:repo/issues
POST   /api/v3/repos/:owner/:repo/issues
GET    /api/v3/repos/:owner/:repo/issues/:issue_number
PATCH  /api/v3/repos/:owner/:repo/issues/:issue_number
```

## Repositories

```text
GET    /api/v3/user
GET    /api/v3/user/repos
GET    /api/v3/repos/:owner/:repo
DELETE /api/v3/repos/:owner/:repo
POST   /api/v3/user/repos
POST   /api/v3/orgs/:org/repos
POST   /api/v3/user/repos/imports
POST   /api/v3/orgs/:org/repos/imports
GET    /api/v3/repository-imports/:id
```

Repository writes require an `Idempotency-Key` header. The published
[`openagents.repositories.v1` contract](/api/contracts/repositories-v1.json)
defines request authority, lifecycle states, pagination, and stable error
codes. The [OpenAgents CLI](/docs/openagents-cli) implements this contract.
Only a repository owner can delete it. A successful deletion returns
`204 No Content`.

## Comments

```
GET    /api/v3/repos/:owner/:repo/issues/:issue_number/comments
POST   /api/v3/repos/:owner/:repo/issues/:issue_number/comments
GET    /api/v3/repos/:owner/:repo/issues/comments/:id
```

## Labels, milestones, assignees

```
GET    /api/v3/repos/:owner/:repo/labels
POST   /api/v3/repos/:owner/:repo/labels
GET    /api/v3/repos/:owner/:repo/milestones
GET    /api/v3/repos/:owner/:repo/issues/:issue_number/labels
POST   /api/v3/repos/:owner/:repo/issues/:issue_number/assignees
```

## Projects

```
GET    /api/v3/users/:username/projectsV2
GET    /api/v3/users/:username/projectsV2/:project_number
GET    /api/v3/users/:username/projectsV2/:project_number/items
GET    /api/v3/users/:username/projectsV2/:project_number/fields
```

## Known differences from GitHub

These are gaps, not design decisions, and they are listed so a client author
finds them here rather than in production:

- Renaming a label via `new_name` is accepted and ignored; the path name wins.
- Applying a label that does not exist returns 404. GitHub creates it.
- Removing a label an issue does not carry succeeds silently. GitHub returns 404.
- The assignable-users endpoint always returns an empty list.
- Project endpoints ignore the `:username` in the path.
- A non-numeric issue, milestone, or project number is a 500 rather than a 404.

## What is not implemented

Pull requests, reviews, webhooks, releases, SSH Git transport, and Git LFS
object storage.
