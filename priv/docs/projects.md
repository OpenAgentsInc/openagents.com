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

Projects are exposed under `/users/:username/projectsV2`, shaped after GitHub's
ProjectsV2. See [REST API](/docs/rest-api).

## A current limitation

The project endpoints do not scope by the `:username` in the path, so a project
is reachable under any username. Treat project URLs as unguessable rather than
access-controlled until that is closed.
