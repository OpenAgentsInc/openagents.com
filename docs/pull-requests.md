# Pull requests

OpenAgents pull requests connect an issue to a proposed change between two hosted repository branches. The issue supplies the pull request number, title, body, author, comments, and open or closed state.

## Repository setting

New repositories allow pull requests by default. `OpenAgentsInc/openagents.com` starts with pull requests disabled because changes to the production application use its controlled publication workflow.

A repository owner can change this setting in the repository's **Pull requests** panel or with the repository API:

```http
PATCH /api/v3/repos/{owner}/{repo}
Authorization: Bearer {forge-write-token}
Content-Type: application/json

{"pull_requests_enabled": true}
```

Maintainers, contributors, viewers, and unauthenticated callers cannot change this setting.

## API

Use these endpoints to work with pull requests:

- `GET /api/v3/repos/{owner}/{repo}/pulls`
- `GET /api/v3/repos/{owner}/{repo}/pulls/{pull_number}`
- `POST /api/v3/repos/{owner}/{repo}/pulls`
- `PATCH /api/v3/repos/{owner}/{repo}/pulls/{pull_number}`

Create a pull request with a title, optional body, source repository, source ref, and optional base ref:

```json
{
  "title": "Update the deployment guide",
  "body": "Explains the new receipt fields.",
  "head_repository": "octocat/openagents-fork",
  "head": "docs/deployment-guide",
  "base": "main"
}
```

The source repository and both refs must exist on the forge. The caller must be able to write to the source repository and participate in issues on the target repository. OpenAgents rejects a second open pull request with the same source repository, source ref, target repository, and base ref.

Merging remains a separate publication operation. Creating or closing a pull request does not update a forge ref.

## Browser views

Open `/{owner}/{repo}/pulls` to list a repository's pull requests. Select a pull request to open `/{owner}/{repo}/pulls/{pull_number}` and review its source and target refs, description, and state.
