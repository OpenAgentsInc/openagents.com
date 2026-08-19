# Issues and Projects API — work plan

Date: 2026-08-19
Source: `docs/github-api-issues-projects-assessment.md`

This document is a markdown-only tracker. Each `Epic` and `Task` will later become an issue or sub-issue in the OpenAgents forge. It organizes the buildout, lists dependencies, and flags work that can be parallelized or dispatched to subagents.

## Approach

- Drive every endpoint through tests first. Follow the TDD workflow in `AGENTS.md`.
- Build the API in the order shown below. Start each epic with the shared schema and context module.
- Run `mix test test/openagents_web/controllers/<...>` for a single file, or `mix precommit` before a final commit.
- Each task includes acceptance criteria and a `subagent ready` flag. Use `subagent_general` for self-contained implementation tasks and `subagent_explore` for spec research.

## Epic 1: Issue CRUD

Goal: implement the core repository issue endpoints.

### E1-T1: Define the `OpenAgents.Issues` context and `Issue` schema
- Create the Ecto schema and migration for repository issues.
- Fields must match the GitHub `issue` object shape where OpenAgents stores the data.
- Acceptance:
  - `mix ecto.migrate` succeeds.
  - `OpenAgents.Issues.list_issues/1` and `OpenAgents.Issues.get_issue!/1` exist.
- Dependencies: none.
- Subagent ready: no.

### E1-T2: GET /api/v3/repos/{owner}/{repo}/issues
- Return a list of issues for a repo. Support query filters (`state`, `labels`, `assignee`, `milestone`, `sort`, `direction`).
- Acceptance:
  - `GET /api/v3/repos/OpenAgents/openagents/issues` returns 200 and a JSON array.
  - Tests cover open issues, closed issues, and empty repositories.
- Dependencies: E1-T1.
- Subagent ready: yes.

### E1-T3: GET /api/v3/repos/{owner}/{repo}/issues/{issue_number}
- Return a single issue.
- Acceptance:
  - Existing issue returns 200 and the issue JSON.
  - Missing issue returns 404.
- Dependencies: E1-T1.
- Subagent ready: yes.

### E1-T4: POST /api/v3/repos/{owner}/{repo}/issues
- Create an issue with `title`, `body`, `labels`, `assignees`, and `milestone`.
- Acceptance:
  - Valid request returns 201 and the created issue.
  - Invalid request returns 422 with error details.
- Dependencies: E1-T1.
- Subagent ready: yes.

### E1-T5: PATCH /api/v3/repos/{owner}/{repo}/issues/{issue_number}
- Update title, body, state, labels, assignees, and milestone.
- Acceptance:
  - Closing an issue returns the issue with `state: "closed"`.
  - Reopening an issue returns `state: "open"`.
- Dependencies: E1-T4.
- Subagent ready: yes.

## Epic 2: Issue comments

Goal: implement issue comments.

### E2-T1: Add `OpenAgents.Issues.Comment` schema and migration
- Acceptance: `OpenAgents.Issues.create_comment/3` exists.
- Dependencies: E1-T1.
- Subagent ready: no.

### E2-T2: GET /api/v3/repos/{owner}/{repo}/issues/{issue_number}/comments
- Acceptance: returns a list of comments for an issue.
- Dependencies: E2-T1.
- Subagent ready: yes.

### E2-T3: POST /api/v3/repos/{owner}/{repo}/issues/{issue_number}/comments
- Acceptance: returns 201 and the created comment.
- Dependencies: E2-T1.
- Subagent ready: yes.

### E2-T4: GET /api/v3/repos/{owner}/{repo}/issues/comments/{comment_id}
- Acceptance: returns 200 for an existing comment and 404 for a missing one.
- Dependencies: E2-T1.
- Subagent ready: yes.

### E2-T5: PATCH /api/v3/repos/{owner}/{repo}/issues/comments/{comment_id}
- Acceptance: updates body text and returns 200.
- Dependencies: E2-T3.
- Subagent ready: yes.

### E2-T6: DELETE /api/v3/repos/{owner}/{repo}/issues/comments/{comment_id}
- Acceptance: returns 204 and removes the comment.
- Dependencies: E2-T3.
- Subagent ready: yes.

## Epic 3: Labels

Goal: implement repository and issue labels.

### E3-T1: Add `OpenAgents.Issues.Label` schema and migration
- Acceptance: `OpenAgents.Issues.create_label/2` and `OpenAgents.Issues.list_labels/1` exist.
- Dependencies: none.
- Subagent ready: no.

### E3-T2: GET /api/v3/repos/{owner}/{repo}/labels
- Acceptance: returns a list of labels.
- Dependencies: E3-T1.
- Subagent ready: yes.

### E3-T3: POST /api/v3/repos/{owner}/{repo}/labels
- Acceptance: returns 201 and the created label.
- Dependencies: E3-T1.
- Subagent ready: yes.

### E3-T4: GET /api/v3/repos/{owner}/{repo}/labels/{name}
- Acceptance: returns a single label or 404.
- Dependencies: E3-T1.
- Subagent ready: yes.

### E3-T5: PATCH /api/v3/repos/{owner}/{repo}/labels/{name}
- Acceptance: updates name, color, and description.
- Dependencies: E3-T3.
- Subagent ready: yes.

### E3-T6: POST /api/v3/repos/{owner}/{repo}/issues/{issue_number}/labels
- Acceptance: adds labels to an issue and returns the updated issue.
- Dependencies: E1-T1, E3-T1.
- Subagent ready: yes.

### E3-T7: DELETE /api/v3/repos/{owner}/{repo}/issues/{issue_number}/labels/{name}
- Acceptance: removes a label from an issue and returns 204.
- Dependencies: E3-T6.
- Subagent ready: yes.

## Epic 4: Assignees

Goal: implement issue assignment.

### E4-T1: Add `OpenAgents.Issues.Assignee` and user participation model
- Acceptance: `OpenAgents.Issues.list_possible_assignees/1` exists.
- Dependencies: E1-T1.
- Subagent ready: no.

### E4-T2: GET /api/v3/repos/{owner}/{repo}/assignees
- Acceptance: returns a list of users who can be assigned.
- Dependencies: E4-T1.
- Subagent ready: yes.

### E4-T3: GET /api/v3/repos/{owner}/{repo}/assignees/{assignee}
- Acceptance: returns 204 if the user can be assigned and 404 if not.
- Dependencies: E4-T1.
- Subagent ready: yes.

### E4-T4: POST /api/v3/repos/{owner}/{repo}/issues/{issue_number}/assignees
- Acceptance: adds assignees and returns the updated issue.
- Dependencies: E1-T1, E4-T1.
- Subagent ready: yes.

### E4-T5: DELETE /api/v3/repos/{owner}/{repo}/issues/{issue_number}/assignees
- Acceptance: removes assignees and returns the updated issue.
- Dependencies: E4-T4.
- Subagent ready: yes.

## Epic 5: Milestones

Goal: implement milestones.

### E5-T1: Add `OpenAgents.Issues.Milestone` schema and migration
- Acceptance: `OpenAgents.Issues.create_milestone/2` exists.
- Dependencies: E1-T1.
- Subagent ready: no.

### E5-T2: GET /api/v3/repos/{owner}/{repo}/milestones
- Acceptance: returns a list of milestones.
- Dependencies: E5-T1.
- Subagent ready: yes.

### E5-T3: POST /api/v3/repos/{owner}/{repo}/milestones
- Acceptance: returns 201 and the created milestone.
- Dependencies: E5-T1.
- Subagent ready: yes.

### E5-T4: GET /api/v3/repos/{owner}/{repo}/milestones/{milestone_number}
- Acceptance: returns a single milestone or 404.
- Dependencies: E5-T1.
- Subagent ready: yes.

### E5-T5: PATCH /api/v3/repos/{owner}/{repo}/milestones/{milestone_number}
- Acceptance: updates title, state, due date, and description.
- Dependencies: E5-T3.
- Subagent ready: yes.

### E5-T6: DELETE /api/v3/repos/{owner}/{repo}/milestones/{milestone_number}
- Acceptance: returns 204 and removes the milestone.
- Dependencies: E5-T3.
- Subagent ready: yes.

## Epic 6: Projects V2

Goal: implement the Projects V2 read and write surface.

### E6-T1: Design the project and item schemas
- Define `Project`, `ProjectField`, `ProjectView`, and `ProjectItem` schemas.
- Acceptance: migrations run and `OpenAgents.Projects.create_project/2` exists.
- Dependencies: none.
- Subagent ready: no.

### E6-T2: GET /api/v3/users/{username}/projectsV2
- Acceptance: returns a list of user projects.
- Dependencies: E6-T1.
- Subagent ready: yes.

### E6-T3: GET /api/v3/users/{username}/projectsV2/{project_number}
- Acceptance: returns a single project.
- Dependencies: E6-T1.
- Subagent ready: yes.

### E6-T4: POST /api/v3/{owner}/projectsV2
- Non-standard endpoint to create a project because the GitHub REST spec does not include it.
- Acceptance: returns 201 and the created project.
- Dependencies: E6-T1.
- Subagent ready: yes.

### E6-T5: GET /api/v3/users/{username}/projectsV2/{project_number}/items
- Acceptance: returns a list of project items.
- Dependencies: E6-T1.
- Subagent ready: yes.

### E6-T6: POST /api/v3/users/{username}/projectsV2/{project_number}/items
- Acceptance: adds an issue to a project and returns the item.
- Dependencies: E1-T4, E6-T1.
- Subagent ready: yes.

### E6-T7: PATCH /api/v3/users/{username}/projectsV2/{project_number}/items/{item_id}
- Acceptance: updates field values on a project item.
- Dependencies: E6-T6.
- Subagent ready: yes.

### E6-T8: GET /api/v3/users/{username}/projectsV2/{project_number}/fields
- Acceptance: returns a list of project fields.
- Dependencies: E6-T1.
- Subagent ready: yes.

## Parallelization and subagent dispatch

### Dependencies

| Before | After |
| --- | --- |
| E1-T1 (issue schema) | E1-T2 to E1-T5, E2-T1, E3-T1, E4-T1, E5-T1, E6-T1 can start. |
| E1-T4 (issue create) | E2-T3 to E2-T6, E3-T6, E3-T7, E4-T4, E4-T5, E6-T6. |
| E2-T1 (comment schema) | E2-T2 to E2-T6. |
| E3-T1 (label schema) | E3-T2 to E3-T7. |
| E4-T1 (assignee model) | E4-T2 to E4-T5. |
| E5-T1 (milestone schema) | E5-T2 to E5-T6. |
| E6-T1 (project schema) | E6-T2 to E6-T8. |

### Parallel waves

**Wave 1 — foundation (serial)**
- E1-T1

**Wave 2 — independent contexts and read endpoints (parallel)**
- E1-T2, E1-T3
- E2-T1
- E3-T1, E3-T2, E3-T4
- E4-T1, E4-T2, E4-T3
- E5-T1, E5-T2, E5-T4
- E6-T1, E6-T2, E6-T3, E6-T5, E6-T8

**Wave 3 — write endpoints (parallel after Wave 1 + Wave 2)**
- E1-T4, E1-T5
- E2-T3 to E2-T6
- E3-T3, E3-T5, E3-T6, E3-T7
- E4-T4, E4-T5
- E5-T3, E5-T5, E5-T6
- E6-T4, E6-T6, E6-T7

### Subagent guidance

- Dispatch one `subagent_general` per task marked `subagent ready: yes`.
- Give each subagent the exact `AGENTS.md` rules, the endpoint path, and the expected JSON shape from `docs/github-api-issues-projects-assessment.md`.
- Keep schema and migration work (subagent ready: no) in the main session. Schema is the contract that all other work depends on.
- Before merging parallel work, run `mix precommit` to catch cross-module conflicts and compile warnings.
