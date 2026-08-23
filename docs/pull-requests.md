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

## Chat tool

The `open_pull_request` chat tool opens a pull request from an accepted repository publication receipt. The tool uses the same shared registry for text, voice, and account API turns.

The tool requires a separate, explicit person approval for opening the pull request. Approval for `publish_changes` does not approve `open_pull_request`. The server also verifies all of the following conditions before it creates or updates a pull request:

- The publication belongs to the same account, conversation, repository workspace, and workspace reference as the tool call.
- The publication state is `accepted`.
- The current forge WAL entry still maps the published branch to the exact published commit.
- The branch uses the `openagents/chat/` namespace and differs from the default branch.
- The repository allows pull requests, and the account can write to the repository.

The tool creates a draft pull request by default. Repeating the tool call for the same open source and base branches returns the existing pull request. If a later accepted publication advances the same source branch, the tool updates the existing pull request with the new publication receipt and commit.

The result includes the pull request number, state, draft state, source and base refs, commit IDs, and receipt references. It does not include access tokens, workspace host paths, or other secrets.

## Browser views

Open `/{owner}/{repo}/pulls` to list a repository's pull requests. Select a pull request to open `/{owner}/{repo}/pulls/{pull_number}` and review its source and target refs, description, and state.
