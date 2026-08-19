# Issues and Projects UI roadmap

Date: 2026-08-19

Source: `docs/issues-projects-work-plan.md`, `docs/github-api-issues-projects-assessment.md`, and the GitHub clone harvest under `~/work/projects/repos/githubclones/`.

This roadmap outlines a simple browser UI for the existing OpenAgents issues, labels, assignees, milestones, comments, and Projects V2 API. The implementation uses Phoenix 1.8 LiveView, `OpenAgentsWeb.CoreComponents`, and DaisyUI component classes. The goal is a GitHub-shaped surface that is usable, not a pixel-perfect clone.

## Scope and assumptions

- The JSON API is in place and follows the paths in `docs/github-api-issues-projects-assessment.md`.
- The UI lives on `/:owner/:repo` paths, starting with the surfaces in this document.
- `OpenAgentsWeb.CoreComponents` and DaisyUI are the building blocks.
- `Phoenix.Component.to_form/2` drives forms, and LiveView streams handle issue and comment lists.
- Markdown bodies are rendered as HTML with `OpenAgentsWeb` markdown helpers.

## What is out of scope

- Drag-and-drop project boards.
- Real-time presence and live updates beyond standard PubSub.
- Full-text issue search indexing.
- React-style hovercards and preview cards.
- File browser, code review, and pull request surfaces.
- Pixel-perfect GitHub Primer styling.

## Layout foundation

Build the repo header and subnavigation before any issue page.

### Global navigation and repo header

What the surface shows:

- A top **navbar** with the OpenAgents logo, a search field, and the current user avatar.
- A **repo header** with the owner avatar, owner name, repo name, and a visibility badge.
- A **subnav** row with **Code**, **Issues**, **Pull requests**, **Projects**, and **Settings** tabs. The active tab gets a highlighted underline.

DaisyUI parts:

- `navbar` for the top bar.
- `tabs` for the subnav.
- `avatar` and `badge` for the owner and visibility indicators.
- `btn` for star, fork, and watch actions.
- `input` for the search field.

Clone harvest:

- `gh-next/src/app/(app)/[user]/[repository]/page.tsx`
- `gitea/templates/repo/header.tmpl`
- `gitea/templates/repo/issue/navbar.tmpl`

Acceptance:

- The same `Layouts.app` wrapper is on every page with `current_scope` assigned.
- The subnav links to `/:owner/:repo/issues`, `/:owner/:repo/projects`, and so on.

## Phase 1: Placeholder homepage

What the surface shows:

- A **hero** section with the OpenAgents value proposition.
- A list of owned repositories as cards.
- Primary actions: **Create new repository** and **Create new issue**.
- Optional: a placeholder contribution activity block.

DaisyUI parts:

- `hero` for the welcome section.
- `card` for repository cards.
- `btn btn-primary` for the main call to action.
- `badge` for public or private status.
- `stat` for star and fork counts.
- `avatar` for the owner avatar.

Clone harvest:

- `leoronne-github-ui-clone/src/pages/Profile/index.tsx`
- `TiagoDiass-github-ui-clone/src/pages/Profile/Profile.tsx`
- `gh-next/src/app/(app)/[user]/[repository]/page.tsx`

Acceptance:

- `/` renders without a `current_scope` error.
- The page lists at least one owned repo.
- Each repo card links to `/:owner/:repo`.

## Phase 2: Issues list

What the surface shows:

- A search and filter bar.
- **Open** and **Closed** tabs with counts.
- Issue rows with state icon, title, labels, author, relative time, and comment count.
- Pagination.
- An empty state when no issues match.

DaisyUI parts:

- `tabs` for **Open** and **Closed**.
- `input` for the search field.
- `btn` and `dropdown` for filters and sort.
- `table` or custom flex rows for the issue list.
- `badge` for state and labels.
- `avatar` for assignees.
- `join` for pagination.

Clone harvest:

- `gh-next/src/components/issues/issue-row.tsx`
- `gh-next/src/components/issues/issue-list.tsx`
- `gh-next/src/components/issues/issues-list-header-form.tsx`
- `gitea/templates/repo/issue/list.tmpl`

API to call:

- `GET /api/v3/repos/:owner/:repo/issues`

Acceptance:

- `/:owner/:repo/issues` lists open issues by default.
- Clicking **Closed** lists closed issues.
- Each title links to `/:owner/:repo/issues/:number`.
- The page uses `stream` for the issue list.

## Phase 3: Issue detail and comments

What the surface shows:

- A header with the issue number, title, and state badge.
- Author, avatar, and relative time.
- A markdown-rendered body.
- Label, assignee, and milestone sections.
- A chronological comment thread with author avatars and markdown bodies.
- A comment form.

DaisyUI parts:

- `badge` for the open or closed state.
- `avatar` and `card` for comments.
- `textarea` for the comment form.
- `btn` for submit, close, and reopen actions.
- `timeline` for the comment thread.
- `collapse` or `drawer` for the metadata sidebar.

Clone harvest:

- `gh-next/src/app/(app)/[user]/[repository]/issues/[number]/page.tsx`
- `gitea/templates/repo/issue/view.tmpl`
- `gitea/templates/repo/issue/view_content.tmpl`
- `git.limo/apps/gitgud_web/lib/gitgud_web/live/issue_live.html.heex`

API to call:

- `GET /api/v3/repos/:owner/:repo/issues/:issue_number`
- `GET /api/v3/repos/:owner/:repo/issues/:issue_number/comments`
- `POST /api/v3/repos/:owner/:repo/issues/:issue_number/comments`
- `PATCH /api/v3/repos/:owner/:repo/issues/:issue_number/comments/:comment_id`
- `DELETE /api/v3/repos/:owner/:repo/issues/:issue_number/comments/:comment_id`

Acceptance:

- The detail page renders at `/:owner/:repo/issues/:number`.
- Comments appear newest first or oldest first consistently.
- Submitting a comment adds it without a full page reload.

## Phase 4: New and edit issue

### New issue

What the surface shows:

- A title input.
- A body textarea with a live markdown preview.
- Multi-select fields for labels and assignees.
- A single-select milestone field.
- Submit and cancel actions.

DaisyUI parts:

- `input` for the title.
- `textarea` for the body.
- `select` for the milestone.
- `checkbox` for labels and assignees.
- `btn` for submit and cancel.
- `card` to frame the form.

Clone harvest:

- `gh-next/src/components/issues/new-issue-form.tsx`
- `gitea/templates/repo/issue/new.tmpl`
- `gitea/templates/repo/issue/new_form.tmpl`
- `git.limo/apps/gitgud_web/lib/gitgud_web/live/issue_form_live.html.heex`

API to call:

- `POST /api/v3/repos/:owner/:repo/issues`
- `GET /api/v3/repos/:owner/:repo/labels`
- `GET /api/v3/repos/:owner/:repo/assignees`
- `GET /api/v3/repos/:owner/:repo/milestones`

Acceptance:

- `/:owner/:repo/issues/new` renders the form.
- Submitting a valid issue redirects to the detail page.
- Validation errors appear next to the title or body fields.

### Edit issue

What the surface shows:

- Inline editing of the title and body on the detail page.
- A state toggle, label multi-select, assignee multi-select, and milestone select.
- Save and cancel actions.

DaisyUI parts:

- `input` and `textarea` for editable fields.
- `btn` for save, cancel, close, and reopen.
- `modal` only if a separate edit view is preferred.
- `collapse` for compact edit sections.

Clone harvest:

- `git.limo/apps/gitgud_web/lib/gitgud_web/live/issue_live.html.heex`
- `gitea/templates/repo/issue/view_content.tmpl`

API to call:

- `PATCH /api/v3/repos/:owner/:repo/issues/:issue_number`
- `POST /api/v3/repos/:owner/:repo/issues/:issue_number/labels`
- `DELETE /api/v3/repos/:owner/:repo/issues/:issue_number/labels/:name`
- `POST /api/v3/repos/:owner/:repo/issues/:issue_number/assignees`
- `DELETE /api/v3/repos/:owner/:repo/issues/:issue_number/assignees`

Acceptance:

- The detail page allows in-place editing of title and body.
- State changes update the state badge immediately.
- Saving updates the issue and re-renders the page.

## Phase 5: Labels, milestones, and assignees

### Labels

What the surface shows:

- A count header and a sort dropdown.
- Label rows with colored badge, name, description, issue count, and edit and delete actions.
- A create button and an inline or modal create form.

DaisyUI parts:

- `badge` for label colors.
- `table` or `card` for label rows.
- `btn` for edit, delete, and create.
- `input`, `textarea`, and a color picker for the create and edit forms.
- `dropdown` for sorting.
- `modal` for the create and edit forms.

Clone harvest:

- `gitea/templates/repo/issue/labels/label_list.tmpl`
- `primer-view_components/app/components/primer/beta/label.rb`

API to call:

- `GET /api/v3/repos/:owner/:repo/labels`
- `POST /api/v3/repos/:owner/:repo/labels`
- `PATCH /api/v3/repos/:owner/:repo/labels/:name`
- `DELETE /api/v3/repos/:owner/:repo/labels/:name`

Acceptance:

- `/:owner/:repo/labels` lists all labels.
- Creating or editing a label updates the list.

### Milestones

What the surface shows:

- A count header and open or closed filter tabs.
- Milestone cards with title, due date, progress bar, open count, and closed count.
- Edit, close, and delete actions.
- A create form.

DaisyUI parts:

- `progress` for the milestone progress bar.
- `stat` for open and closed counts.
- `card` for milestone cards.
- `badge` for the open or closed state.
- `input` for the create and edit forms.

Clone harvest:

- `gitea/templates/repo/issue/milestones.tmpl`
- `primer-view_components/app/components/primer/beta/counter.rb`

API to call:

- `GET /api/v3/repos/:owner/:repo/milestones`
- `POST /api/v3/repos/:owner/:repo/milestones`
- `PATCH /api/v3/repos/:owner/:repo/milestones/:milestone_number`
- `DELETE /api/v3/repos/:owner/:repo/milestones/:milestone_number`

Acceptance:

- `/:owner/:repo/milestones` renders milestones with progress bars.
- Closing a milestone updates its state badge.

### Assignees

What the surface shows:

- Assignees appear as an avatar stack on issue rows and in the detail view.
- The issue detail page shows an assignee selection dropdown.
- An optional `/:owner/:repo/assignees` page lists users and their assigned issue counts.

DaisyUI parts:

- `avatar` and `avatar-group` for the stack.
- `badge` for overflow counts like `+2`.
- `menu` for the assignee dropdown.

Clone harvest:

- `gh-next/src/components/issues/issue-row.tsx`
- `gh-next/src/components/issues/issue-assignee-filter-action-list.tsx`
- `gitea/templates/repo/issue/sidebar/assignee_list.tmpl`

API to call:

- `GET /api/v3/repos/:owner/:repo/assignees`

## Phase 6: Projects V2 board

What the surface shows:

- A project list page with project cards.
- A simple board view with columns such as **To Do**, **In Progress**, and **Done**.
- Cards inside columns show issue title, labels, and assignees.
- Buttons to create a project and add a column.

DaisyUI parts:

- `card` for project cards and board cards.
- `collapse` for collapsible columns.
- `badge` for labels and status.
- `avatar` for assignees.
- `progress` for project completion.
- `btn` for create actions.

Clone harvest:

- `gitea/templates/repo/projects/list.tmpl`
- `gitea/templates/repo/projects/view.tmpl`
- `gitea/templates/repo/issue/sidebar/project_list.tmpl`

API to call:

- `GET /api/v3/users/:username/projectsV2`
- `POST /:owner/projectsV2`
- `GET /api/v3/users/:username/projectsV2/:project_number`
- `GET /api/v3/users/:username/projectsV2/:project_number/items`
- `POST /api/v3/users/:username/projectsV2/:project_number/items`
- `PATCH /api/v3/users/:username/projectsV2/:project_number/items/:item_id`

Acceptance:

- The project list renders at `/:owner/projects`.
- A project board renders at `/:owner/projects/:project_number`.
- Cards display issue title, labels, and assignees.
- Drag-and-drop is not required for the first pass.

## Component conventions

- Begin every LiveView template with `<Layouts.app flash={@flash} ...>`.
- Use `OpenAgentsWeb.CoreComponents` for `input`, `textarea`, `button`, `table`, and `icon`.
- Use DaisyUI classes only where they make the final layout simpler than the core component.
- Use `Phoenix.Component.to_form/2` for forms.
- Use LiveView `stream` for issue lists, comment lists, and board cards.
- Use `<.icon name="..." />` for icons and avoid hand-written `svg` tags.

## Implementation order

1. Layout foundation and placeholder homepage.
2. Issues list with open and closed tabs.
3. Issue detail and comment thread.
4. New issue and inline edit issue forms.
5. Labels, milestones, and assignee selection.
6. Projects V2 list and simple board view.

Each phase can become its own `mix test` and `mix precommit` cycle. Keep the UI simple, build from the API already in place, and add polish once the core flows are usable.
