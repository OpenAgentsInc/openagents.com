# GitHub Issues and Projects API — implementation assessment

Date: 2026-08-19
Source: `rest-api-description/descriptions/api.github.com/api.github.com.2026-03-10.yaml`

## Goal

Dogfood OpenAgents by using it to track this repo's own issues and projects. We want enough GitHub REST API parity that `gh`, Octokit, and the GitHub CLI can talk to OpenAgents without changes, but we will only build the subset we actually use.

## Summary

The 2026-03-10 OpenAPI spec has 84 endpoints tagged with `issue` or `project`. Most are for advanced features. For day-one use we need the core create/read/update/comment/label/assign/milestone flow, plus the ability to add issues to a project board and update board fields.

## Issues API — what to build

### Phase 1 — must have for dogfooding

These endpoints are enough to open, discuss, label, assign, and close issues in public:

| Method | Path | Why it matters |
| --- | --- | --- |
| GET | `/repos/{owner}/{repo}/issues` | List repository issues |
| GET | `/repos/{owner}/{repo}/issues/{issue_number}` | Get a single issue |
| POST | `/repos/{owner}/{repo}/issues` | Create an issue |
| PATCH | `/repos/{owner}/{repo}/issues/{issue_number}` | Edit, close, or reopen an issue |
| GET | `/repos/{owner}/{repo}/issues/{issue_number}/comments` | List comments on an issue |
| POST | `/repos/{owner}/{repo}/issues/{issue_number}/comments` | Add a comment |
| GET | `/repos/{owner}/{repo}/issues/comments/{comment_id}` | Get a single comment |
| PATCH | `/repos/{owner}/{repo}/issues/comments/{comment_id}` | Edit a comment |
| DELETE | `/repos/{owner}/{repo}/issues/comments/{comment_id}` | Delete a comment |
| GET | `/repos/{owner}/{repo}/labels` | List repository labels |
| GET | `/repos/{owner}/{repo}/labels/{name}` | Get a label |
| POST | `/repos/{owner}/{repo}/labels` | Create a label |
| PATCH | `/repos/{owner}/{repo}/labels/{name}` | Update a label |
| DELETE | `/repos/{owner}/{repo}/labels/{name}` | Delete a label |
| GET | `/repos/{owner}/{repo}/issues/{issue_number}/labels` | List labels on an issue |
| POST | `/repos/{owner}/{repo}/issues/{issue_number}/labels` | Add labels to an issue |
| DELETE | `/repos/{owner}/{repo}/issues/{issue_number}/labels/{name}` | Remove a label from an issue |
| GET | `/repos/{owner}/{repo}/assignees` | List who can be assigned |
| GET | `/repos/{owner}/{repo}/assignees/{assignee}` | Check if a user can be assigned |
| POST | `/repos/{owner}/{repo}/issues/{issue_number}/assignees` | Add assignees |
| DELETE | `/repos/{owner}/{repo}/issues/{issue_number}/assignees` | Remove assignees |
| GET | `/repos/{owner}/{repo}/milestones` | List milestones |
| GET | `/repos/{owner}/{repo}/milestones/{milestone_number}` | Get a milestone |
| POST | `/repos/{owner}/{repo}/milestones` | Create a milestone |
| PATCH | `/repos/{owner}/{repo}/milestones/{milestone_number}` | Update a milestone |
| DELETE | `/repos/{owner}/{repo}/milestones/{milestone_number}` | Delete a milestone |

### Phase 2 — nice to have

| Method | Path | Why it matters |
| --- | --- | --- |
| GET | `/repos/{owner}/{repo}/issues/events` | Activity feed |
| GET | `/repos/{owner}/{repo}/issues/events/{event_id}` | Single event |
| GET | `/repos/{owner}/{repo}/issues/{issue_number}/events` | Issue-specific events |
| GET | `/repos/{owner}/{repo}/issues/{issue_number}/timeline` | Full timeline |
| PUT | `/repos/{owner}/{repo}/issues/{issue_number}/lock` | Lock an issue |
| DELETE | `/repos/{owner}/{repo}/issues/{issue_number}/lock` | Unlock an issue |

### Out for now

- `/issues` and `/user/issues` — cross-repo lists. We can start repo-scoped.
- `/orgs/{org}/issues` — org-level issue list. Not needed for one repo.
- Issue dependencies and sub-issues — useful later, not required for a public tracker.
- Issue suggestions and issue-field-values — tied to newer GitHub custom fields and AI features. Skip until we need them.

## Projects API — what to build

### Important caveat

The 2026-03-10 GitHub REST spec has only a limited Projects V2 surface. It lists projects and items, but it does **not** include a REST endpoint to create or update a project. Board creation and field/schema changes are GraphQL in the official API.

### Phase 1 — implement the existing REST subset

| Method | Path | Why it matters |
| --- | --- | --- |
| GET | `/users/{username}/projectsV2` | List user projects |
| GET | `/users/{username}/projectsV2/{project_number}` | Get a user project |
| GET | `/users/{username}/projectsV2/{project_number}/items` | List project items |
| GET | `/users/{username}/projectsV2/{project_number}/items/{item_id}` | Get a project item |
| POST | `/users/{username}/projectsV2/{project_number}/items` | Add an issue to a project |
| PATCH | `/users/{username}/projectsV2/{project_number}/items/{item_id}` | Update a project item (status, field values) |
| DELETE | `/users/{username}/projectsV2/{project_number}/items/{item_id}` | Remove an item from a project |
| GET | `/users/{username}/projectsV2/{project_number}/fields` | List project fields |
| GET | `/users/{username}/projectsV2/{project_number}/fields/{field_id}` | Get a project field |
| GET | `/users/{username}/projectsV2/{project_number}/views` | Create a view for a user-owned project |

Also implement the same set under `/orgs/{org}/projectsV2` when we are ready for org-scoped projects.

### Phase 1 — add the missing write endpoints

Because the official REST spec is incomplete, add the following non-GitHub-standard OpenAgents-specific project endpoints to unblock day-one board creation and editing:

| Method | Path | Why it matters |
| --- | --- | --- |
| POST | `/{owner}/projectsV2` | Create a new project |
| PATCH | `/{owner}/projectsV2/{project_number}` | Update project title and settings |
| DELETE | `/{owner}/projectsV2/{project_number}` | Delete a project |
| POST | `/{owner}/projectsV2/{project_number}/fields` | Add a custom field |
| POST | `/{owner}/projectsV2/{project_number}/views` | Create a board view |

These are not in the GitHub REST spec, but they are required for a usable project tracker. We can make them GitHub-compatible where it makes sense and document the gap.

### Out for now

- Draft items, project views in detail, and advanced project view item ordering — add once the core board works.
- Organization-level projects — implement after user projects work.

## Recommendation

Build the Issues Phase 1 list first. It is enough for the public to open, discuss, and manage issues on OpenAgents.com. Then add the Projects V2 read endpoints and the non-standard project write endpoints so we can organize those issues into a public board.
