# Projects

A project is a board of issues. Browse them at `/:owner/:repo/projects`.

## The description

A project carries one `description` field, which is Markdown. Use it for the
context that applies to the whole project: why the project exists, the
assumptions it operates under, and the decisions that outlive any single issue.
The board renders the description above the columns. Members with write access
to the repository edit it in place.

## Discussion and activity

A project also carries notes, which the board shows below the columns:

- A **discussion note** is Markdown prose you write. Its author can edit or
  delete it; nobody else can, even with write access to the repository.
- An **activity entry** records a change to the project's title, description, or
  state. Entries are written when the change commits, and they never change or
  delete.

Issue comments stay on the issue. Project notes carry what applies across
issues.

## The board

Items are grouped into columns by status. Adding an issue to a project creates
an item that points at it — the issue itself is unchanged, so the same issue can
sit on several boards.

## Fields

A project carries fields beyond status. Field values live on the item, not the
issue, so two boards can hold different views of the same work.

## Through the API

Projects are exposed under `/repos/:owner/:repo/projectsV2`. The repository in
the path controls visibility and write authority for every project, item, field,
and note operation. See [REST API](/docs/rest-api), or use
[`openagents api`](/docs/cli-api) to work with projects from a terminal.

A project object carries `description`, `created_at`, and `updated_at` alongside
its `number`, `title`, `owner`, and `state`. `PATCH` on a project accepts
`title`, `description`, and `state`, where `state` is `open` or `closed`.

Notes are a separate paginated read at
`/repos/:owner/:repo/projectsV2/:project_number/notes`, so a long-lived board
does not carry an unbounded timeline inside the project object. The response
carries `notes`, `page`, `per_page`, and `total_count`. Each note carries a
stable `id`, its `kind` (`note` or `activity`), the Markdown `body`, the
`author`, `created_at`, and `updated_at`. Pass `kind=note` or `kind=activity` to
read one side of the feed.
