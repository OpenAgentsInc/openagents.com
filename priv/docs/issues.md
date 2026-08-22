# Issues

An issue is a unit of work in a repository. Browse them at
`/:owner/:repo/issues`.

## Filtering by state

The list shows open issues by default. Switch between open and closed with the
state filter; the choice is in the URL, so a filtered list is a link you can
send to someone.

## What an issue holds

A title, a description, a state, and the people and labels attached to it. Each
issue carries a number that is unique within its repository and never reused,
so a reference to an issue stays valid after it is closed.

## Comments

Comments are ordered and attributed. Editing one is limited to its author,
while an issue's own title and description may be edited by any workspace
member.

## Through the API

Every browser action here has a REST equivalent under
`/api/v3/repos/:owner/:repo/issues`. See [REST API](/docs/rest-api), or use
[`openagents api`](/docs/cli-api) to work with issues from a terminal.
