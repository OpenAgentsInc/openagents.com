# Component library

Date: 2026-08-19

This is the master list of reusable HEEx components for the Agent Forge UI.

- **Shipped** components appear on `/components`.
- **Planned** components come from the issues and projects UI roadmap
  (`docs/issues-projects-ui-roadmap.md`) and the GitHub-shaped harvest
  work in `sarah` (`docs/audits/2026-08-19-github-forge-atomic-components.md`,
  `docs/audits/2026-08-19-github-clone-harvest-candidates.md`).

Build new forge-only molecules and organisms in a dedicated module such as
`OpenAgentsWeb.Code` or `OpenAgentsWeb.Issues`. Keep generic atoms in
`OpenAgentsWeb.CoreComponents`. Add every new component to `/components`
when it ships.

Clone root: `~/work/projects/repos/githubclones/`.

## What exists today

These are the reusable function components on `origin/main`. The catalog
at `/components` renders each one.

| Layer | Component | Module | Notes |
| --- | --- | --- | --- |
| Atom | `button/1` | `CoreComponents` | Soft default and `variant="primary"`; supports `navigate` |
| Atom | `input/1` | `CoreComponents` | Text, checkbox, select, textarea, hidden |
| Atom | `icon/1` | `CoreComponents` | Heroicons via `hero-*` class names |
| Atom | `flash/1` | `CoreComponents` | Info and error toasts |
| Molecule | `header/1` | `CoreComponents` | Title, subtitle, actions |
| Molecule | `list/1` | `CoreComponents` | Titled description rows |
| Organism | `table/1` | `CoreComponents` | Zebra table; supports LiveView streams |
| Organism | `flash_group/1` | `Layouts` | Wraps page flashes; do not call outside layouts |
| Organism | `app/1` | `Layouts` | Page chrome |
| Atom | `theme_toggle/1` | `Layouts` | System, light, dark |

Phoenix also provides `<.form>`, `<.link>`, and `<.inputs_for>`. Use those
instead of hand-rolled forms.

## Planned atoms

Generic or tiny forge-only spans. Reuse `button`, `input`, and `icon`
where they already fit.

| Build | Role | Harvest |
| --- | --- | --- |
| `badge/1` | Visibility, issue state, label color | DaisyUI `badge`; Primer `primer-view_components/app/components/primer/beta/label.rb` |
| `avatar/1` | Owner and author faces | DaisyUI `avatar`; `gh-next/src/components/avatar.tsx` |
| `sha/1` | Short commit id that links to `/commit/:sha` | `git.limo/apps/gitgud_web/lib/gitgud_web/live/commit_diff_live.html.heex` |
| `ref_name/1` | Branch or tag pill | `primer-css/src/branch-name/branch-name.scss` |
| `counter/1` | Count beside a nav word | `primer-view_components/app/components/primer/beta/counter.rb` |
| `relative_time/1` | "3 hours ago" with a `datetime` | `primer-view_components/app/components/primer/beta/relative_time.rb` |
| `clipboard_copy/1` | Copy a SHA or clone URL | `primer-view_components/app/components/primer/beta/clipboard_copy.rb` |
| `truncate/1` | Single-line commit or issue title | `primer-view_components/app/components/primer/beta/truncate.rb` |
| `empty/1` | Empty issues, compare, or repo | DaisyUI empty pattern; `CoreComponents` has no empty yet |
| `kbd/1` | Keyboard hints | DaisyUI `kbd` |

## Planned molecules

| Build | Role | Harvest |
| --- | --- | --- |
| `owner_lockup/1` | Avatar + `owner/repo` links | `gh-next/src/app/(app)/[user]/[repository]/page.tsx`; `gitea/templates/repo/header.tmpl` |
| `path_breadcrumb/1` | Path prefixes that `patch` | `git.limo/apps/gitgud_web/lib/gitgud_web/live/tree_browser_live.html.heex`; `primer-view_components/app/components/primer/beta/breadcrumbs.html.erb` |
| `clone_field/1` | Readonly clone URL + copy | `git.limo/.../tree_browser_live.html.heex` (`#clone-repo`); `gitea/templates/repo/clone_panel.tmpl` |
| `branch_picker/1` | Current ref + menu of refs | `git.limo/.../branch_select_live.ex`; `gitea/templates/repo/branch_dropdown.tmpl` |
| `file_row/1` | Name, last commit, age (commit may be nil) | `gitea/templates/repo/view_list.tmpl`; `git.limo/.../tree_browser_live.html.heex` |
| `commit_row/1` | SHA, subject, author, time | `gitea/templates/repo/commits_table.tmpl` |
| `issue_row/1` | State, title, labels, author, comments | `gh-next/src/components/issues/issue-row.tsx`; `gitea/templates/repo/issue/list.tmpl` |
| `ref_row/1` | Branch or tag + SHA | `gitea/templates/repo/branch/list.tmpl` |
| `underline_nav/1` | Repo tabs with an active underline | `primer-view_components/app/components/primer/alpha/underline_nav.html.erb`; `gitea/templates/repo/navbar.tmpl` |
| `label_badge/1` | Colored issue label | `gh-next/src/components/label-badge.tsx`; `gitea/templates/repo/issue/labels/label_list.tmpl` |
| `assignee_stack/1` | Avatar group with overflow | `gh-next/src/components/issues/issue-row-avatar-stack.tsx` |
| `compare_ends/1` | Base picker + `...` + head picker | `gitea/templates/repo/diff/compare.tmpl` |
| `diff_stat/1` | File count and `+n` / `−n` | `gitea/templates/repo/diff/stats.tmpl` |
| `comment_form/1` | Markdown body + submit | `git.limo/.../comment_form_live.html.heex`; `gitea/templates/repo/issue/comment_tab.tmpl` |

## Planned organisms

| Build | Role | Harvest |
| --- | --- | --- |
| `repo_header/1` | Owner lockup, visibility, clone, actions | `gitea/templates/repo/header.tmpl`; `gh-next/.../[repository]/page.tsx` |
| `repo_subnav/1` | Code, Issues, Pull requests, Projects, Settings | `gitea/templates/repo/navbar.tmpl`; `gitea/templates/repo/issue/navbar.tmpl` |
| `issue_list/1` | Open/closed tabs, filters, streamed rows | `gh-next/src/components/issues/issue-list.tsx`; `gitea/templates/repo/issue/list.tmpl` |
| `issue_detail/1` | Title, state, body, sidebar metadata | `gh-next/src/app/(app)/[user]/[repository]/issues/[number]/page.tsx`; `gitea/templates/repo/issue/view.tmpl` |
| `comment_thread/1` | Chronological comments | `gitea/templates/repo/issue/view_content.tmpl`; `git.limo/.../issue_live.html.heex` |
| `issue_form/1` | New and edit issue | `gh-next/src/components/issues/new-issue-form.tsx`; `gitea/templates/repo/issue/new_form.tmpl` |
| `label_manager/1` | Create, edit, delete labels | `gitea/templates/repo/issue/labels/label_list.tmpl` |
| `milestone_list/1` | Progress cards | `gitea/templates/repo/issue/milestones.tmpl` |
| `project_board/1` | Columns of items (no drag-and-drop at first) | GitHub Projects V2 REST in `docs/github-api-issues-projects-assessment.md` |
| `file_table/1` | Directory listing | `gitea/templates/repo/view_list.tmpl`; `git.limo/.../tree_browser_live.ex` |
| `blob_panel/1` | File view + actions | `gitea/templates/repo/view_file.tmpl`; `git.limo/.../blob_viewer_live.ex` |
| `readme_panel/1` | Rendered README | `git.limo/.../tree_browser_live.html.heex` README card |
| `commit_list/1` | Bounded log | `gitea/templates/repo/commits.tmpl` |
| `diff_viewer/1` | Unified hunks | `gitea/templates/repo/diff/box.tmpl`; `section_unified.tmpl` |
| `compare_panel/1` | Compare ends + diff | `gitea/templates/repo/diff/compare.tmpl` |

## Planned pages

Mount these on GitHub-shaped paths. See
`docs/issues-projects-ui-roadmap.md` and the sarah harvest audit.

| Page | Path | First organisms |
| --- | --- | --- |
| Owner | `/:owner` | Repo cards |
| Repo home | `/:owner/:repo` | `repo_header`, `file_table`, `readme_panel` |
| Issues | `/:owner/:repo/issues` | `repo_header`, `issue_list` |
| Issue | `/:owner/:repo/issues/:number` | `issue_detail`, `comment_thread` |
| New issue | `/:owner/:repo/issues/new` | `issue_form` |
| Labels | `/:owner/:repo/labels` | `label_manager` |
| Milestones | `/:owner/:repo/milestones` | `milestone_list` |
| Projects | `/:owner/:repo/projects` | `project_board` |
| Tree | `/:owner/:repo/tree/:ref/*path` | `file_table` |
| Blob | `/:owner/:repo/blob/:ref/*path` | `blob_panel` |
| Commit | `/:owner/:repo/commit/:sha` | `diff_viewer` |
| Compare | `/:owner/:repo/compare/:base...:head` | `compare_panel` |
| Catalog | `/components` | This page |

## Build order

1. Atoms that issues need first: `badge`, `avatar`, `relative_time`,
   `empty`, `label_badge`.
2. Molecules: `owner_lockup`, `issue_row`, `underline_nav`,
   `comment_form`.
3. Organisms: `repo_header`, `repo_subnav`, `issue_list`,
   `issue_detail`, `comment_thread`.
4. Pages on `/:owner/:repo/issues` as in the UI roadmap.
5. Code surfaces (`file_table`, `blob_panel`, `diff_viewer`) after the
   tracker dogfoods.
6. `/api/v3` stays the machine API from
   `docs/github-api-issues-projects-assessment.md`. It is not a
   component.

Do not add Octicons, Primer CSS as a runtime, or a second button
system. DaisyUI plus `CoreComponents` is the kit.

## See also

- `/components` — live catalog of shipped components
- `docs/issues-projects-ui-roadmap.md` — page-level UI plan
- `docs/issues-projects-work-plan.md` — API epics
- `docs/github-api-issues-projects-assessment.md` — GitHub REST subset
