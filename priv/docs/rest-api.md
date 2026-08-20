# REST API

The API is shaped after GitHub's REST API and served under `/api/v3`. An
existing client usually needs only a base URL change.

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

Pull requests, reviews, webhooks, releases, and Git LFS.
