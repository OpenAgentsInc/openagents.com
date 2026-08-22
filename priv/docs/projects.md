# Projects

A project is a board of issues. Browse them at `/:owner/:repo/projects`.

## The board

Items are grouped into columns by status. Adding an issue to a project creates
an item that points at it — the issue itself is unchanged, so the same issue can
sit on several boards.

## Fields

A project carries fields beyond status. Field values live on the item, not the
issue, so two boards can hold different views of the same work.

## Through the API

Projects are exposed under `/repos/:owner/:repo/projectsV2`. The repository in
the path controls visibility and write authority for every project, item, and
field operation. See [REST API](/docs/rest-api).
