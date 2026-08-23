---
name: openagents-work-management
description: Manage OpenAgents issues, projects, comments, labels, assignees, and milestones through the OpenAgents CLI.
allowed-tools:
  - read
  - exec
  - grep
---

Use this skill when the user asks you to manage OpenAgents issues, projects, comments, labels, assignees, milestones, or Projects V2 boards from the command line. Do not use the `pro-work-management` skill or the Pro Linear/MCP surface. This skill targets the OpenAgents `/api/v3` surface through the `@openagentsinc/cli` package.

The OpenAgents CLI does not provide named `issue`, `project`, `label`, `milestone`, or `assignee` commands. For all work system operations, use `openagents api` and construct the route path manually. The Projects V2 routes must be done manually.

## Before you start

1. Install the CLI:
   ```sh
   npm install --global @openagentsinc/cli@latest
   ```
   Or run one command with `npx --yes @openagentsinc/cli@latest`.
2. Sign in:
   ```sh
   openagents auth login
   ```
3. Confirm the session:
   ```sh
   openagents auth status
   ```
4. Writes require a `forge:write` personal access token. Create one at `/settings/api-tokens` and store it with `openagents auth login --token-stdin`, or set `OPENAGENTS_TOKEN` for a single process. Do not print or commit tokens.

## Route addressing

A relative path for `openagents api` resolves under `/api/v3/`. For example, `repos/OWNER/REPO/issues` is the same as `/api/v3/repos/OWNER/REPO/issues`.

- Method: `-X GET|POST|PATCH|PUT|DELETE`.
- String fields: repeatable `-f KEY=VALUE`. Every value is sent as a JSON string.
- Full JSON body: `--input FILE` or `--input -` for standard input. Use this for numbers, booleans, arrays, nested objects, or `null`. `--field` and `--input` are mutually exclusive.
- Custom headers: `-H 'NAME: VALUE'`. The CLI rejects an `Authorization` header override.

## Issues

Implemented issue routes from `docs/github-api-issues-projects-assessment.md`:

| Resource | Methods | Path |
|---|---|---|
| Issues | `GET`, `POST` | `repos/OWNER/REPO/issues` |
| Issue | `GET`, `PUT`, `PATCH` | `repos/OWNER/REPO/issues/NUMBER` |
| Comments | `GET`, `POST` | `repos/OWNER/REPO/issues/NUMBER/comments` |
| Comment | `GET`, `PUT`, `PATCH`, `DELETE` | `repos/OWNER/REPO/issues/comments/ID` |
| Labels | `GET`, `POST` | `repos/OWNER/REPO/labels` |
| Label | `GET`, `PUT`, `PATCH`, `DELETE` | `repos/OWNER/REPO/labels/NAME` |
| Issue labels | `GET`, `POST` | `repos/OWNER/REPO/issues/NUMBER/labels` |
| Issue label | `DELETE` | `repos/OWNER/REPO/issues/NUMBER/labels/NAME` |
| Assignees | `GET` | `repos/OWNER/REPO/assignees` |
| Issue assignees | `GET`, `POST`, `DELETE` | `repos/OWNER/REPO/issues/NUMBER/assignees` |
| Milestones | `GET`, `POST` | `repos/OWNER/REPO/milestones` |
| Milestone | `GET`, `PUT`, `PATCH`, `DELETE` | `repos/OWNER/REPO/milestones/NUMBER` |

List responses are wrapped: `{"issues":[...]}`, `{"comments":[...]}`, `{"labels":[...]}`, `{"milestones":[...]}`.

Create an issue:

```sh
openagents api -X POST \
  -f title="Search returns duplicates" \
  -f body="Steps to reproduce" \
  repos/OWNER/REPO/issues
```

Close an issue with reason:

```sh
printf '%s' '{"state":"closed","state_reason":"completed"}' | \
  openagents api -X PATCH --input - \
  repos/OWNER/REPO/issues/41
```

Add a comment:

```sh
openagents api -X POST -f body="The fix is available in staging." \
  repos/OWNER/REPO/issues/41/comments
```

## Projects

There are no named `project` commands. Construct every Projects V2 route manually under `repos/OWNER/REPO/projectsV2`.

| Operation | Method | Path |
|---|---|---|
| List | `GET` | `repos/OWNER/REPO/projectsV2` |
| Create | `POST` | `repos/OWNER/REPO/projectsV2` |
| Read | `GET` | `repos/OWNER/REPO/projectsV2/PROJECT_NUMBER` |
| List items | `GET` | `repos/OWNER/REPO/projectsV2/PROJECT_NUMBER/items` |
| Add item | `POST` | `repos/OWNER/REPO/projectsV2/PROJECT_NUMBER/items` |
| Update item | `PATCH` | `repos/OWNER/REPO/projectsV2/PROJECT_NUMBER/items/ITEM_ID` |
| List fields | `GET` | `repos/OWNER/REPO/projectsV2/PROJECT_NUMBER/fields` |
| Create field | `POST` | `repos/OWNER/REPO/projectsV2/PROJECT_NUMBER/fields` |

List projects:

```sh
openagents api repos/OWNER/REPO/projectsV2
```

Create a project:

```sh
openagents api -X POST -f title="Release readiness" \
  repos/OWNER/REPO/projectsV2
```

Add a repository-local issue to a project:

```sh
printf '%s' '{"issue_number":11,"values":{"Status":"To Do"}}' | \
  openagents api -X POST --input - \
  repos/OWNER/REPO/projectsV2/PROJECT_NUMBER/items
```

Add an issue from another repository:

```sh
printf '%s' '{"issue":{"owner":"SOURCE_OWNER","repo":"SOURCE_REPO","number":37},"values":{"Status":"To Do"}}' | \
  openagents api -X POST --input - \
  repos/PROJECT_OWNER/PROJECT_REPO/projectsV2/PROJECT_NUMBER/items
```

Update an item:

```sh
printf '%s' '{"values":{"Status":"Done"}}' | \
  openagents api -X PATCH --input - \
  repos/OWNER/REPO/projectsV2/PROJECT_NUMBER/items/ITEM_ID
```

## Rules and constraints

- Always prefer `openagents api` over inventing named subcommands.
- Use `--json` for noninteractive or script output. `openagents api` always returns the response body as JSON.
- Writes require a `forge:write` token and repository membership. Anonymous reads are allowed only on public repositories.
- Do not print or commit tokens. Use the OS credential store or `OPENAGENTS_TOKEN`.
- Cross-repository project items require write access to the project repository and read access to the source issue repository.
- Issue and milestone numbers are repository-local. Project numbers are also repository-local.
- For the exact request/response envelopes and current known gaps, read `docs/github-api-issues-projects-assessment.md` and `docs/openagents-cli/api.md`.
