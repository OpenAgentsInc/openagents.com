# Call the API with the OpenAgents CLI

The `openagents api` command sends an authenticated request to any OpenAgents
API route and writes the response body as JSON. Use it for Issues, Projects,
and other routes that do not have a named CLI command.

The current release does not provide `openagents issue` or
`openagents project` commands. `openagents api` is the supported terminal path
for those resources.

## Before you begin

Install the CLI and sign in to the API profile you intend to use:

```sh
npm install --global @openagentsinc/cli@latest
openagents auth login
openagents auth status
```

You can also set `OPENAGENTS_TOKEN` to an `oa_pat_` user token for one process.
The token must carry the authority required by the route. Public API reads may
allow anonymous HTTP requests, but `openagents api` still resolves an
authenticated CLI session before it sends a request.

## Address a route

A relative path resolves under `/api/v3/`:

```sh
openagents api repos/OWNER/REPOSITORY/issues
```

These paths name the same route:

```text
repos/OWNER/REPOSITORY/issues
/api/v3/repos/OWNER/REPOSITORY/issues
```

An absolute path must start with `/api/`. A complete URL must use the exact API
origin selected by `--profile`, `--api-url`, or the CLI configuration. The CLI
refuses another origin and refuses paths that escape the API namespace.

## Select a method and body

Use `-X` or `--method` to select `GET`, `POST`, `PATCH`, `PUT`, or `DELETE`.
Without the flag, a request without a body uses `GET`, and a request with a
body uses `POST`.

Use repeatable `-f` or `--field` flags for a flat JSON object whose values are
strings:

```sh
openagents api -X POST \
  -f title="Search returns duplicates" \
  -f body="Include steps to reproduce" \
  repos/OWNER/REPOSITORY/issues
```

Use `--input` for numbers, booleans, arrays, nested objects, or `null`:

```sh
openagents api --input request.json repos/OWNER/REPOSITORY/issues

printf '%s' '{"labels":["bug"],"milestone":3}' | \
  openagents api -X PATCH --input - \
  repos/OWNER/REPOSITORY/issues/41
```

`--input -` reads standard input. `--field` and `--input` are mutually
exclusive.

Use repeatable `-H` or `--header` flags for route-specific headers:

```sh
openagents api -H 'Idempotency-Key: WORK_ITEM_ID' ROUTE
```

The CLI supplies the bearer credential from the selected session and refuses
an `Authorization` header override.

## Work with issues

List open issues. The API returns an object with an `issues` array:

```sh
openagents api repos/OWNER/REPOSITORY/issues

openagents api 'repos/OWNER/REPOSITORY/issues?state=all' | \
  jq -r '.issues[] | [.number, .state, .title] | @tsv'
```

Read one issue and its comments:

```sh
openagents api repos/OWNER/REPOSITORY/issues/41
openagents api repos/OWNER/REPOSITORY/issues/41/comments
```

Create, edit, close, and reopen an issue:

```sh
openagents api -X POST \
  -f title="Search returns duplicates" \
  -f body="Steps to reproduce" \
  repos/OWNER/REPOSITORY/issues

openagents api -X PATCH -f title="Search duplicates results" \
  repos/OWNER/REPOSITORY/issues/41

printf '%s' '{"state":"closed","state_reason":"completed"}' | \
  openagents api -X PATCH --input - \
  repos/OWNER/REPOSITORY/issues/41

openagents api -X PATCH -f state=open \
  repos/OWNER/REPOSITORY/issues/41
```

Add a comment:

```sh
openagents api -X POST -f body="The fix is available in staging." \
  repos/OWNER/REPOSITORY/issues/41/comments
```

The [GitHub-shaped Issues and Projects API
assessment](../github-api-issues-projects-assessment.md) lists the implemented
label, assignee, milestone, comment, and issue-label routes.

## Work with projects

List repository projects. The API returns an object with a `projects` array:

```sh
openagents api repos/OWNER/REPOSITORY/projectsV2
```

Read a project, its items, and its fields:

```sh
openagents api repos/OWNER/REPOSITORY/projectsV2/PROJECT_NUMBER
openagents api repos/OWNER/REPOSITORY/projectsV2/PROJECT_NUMBER/items
openagents api repos/OWNER/REPOSITORY/projectsV2/PROJECT_NUMBER/fields
```

Create a repository project:

```sh
openagents api -X POST -f title="Release readiness" \
  repos/OWNER/REPOSITORY/projectsV2
```

Add an issue to a project. `issue_id` is the issue's numeric database ID from
the issue response, not its repository-local issue number:

```sh
printf '%s' '{"issue_id":42,"values":{"Status":"To Do"}}' | \
  openagents api -X POST --input - \
  repos/OWNER/REPOSITORY/projectsV2/PROJECT_NUMBER/items
```

Update the stored values for an item:

```sh
printf '%s' '{"values":{"Status":"Done"}}' | \
  openagents api -X PATCH --input - \
  repos/OWNER/REPOSITORY/projectsV2/PROJECT_NUMBER/items/ITEM_ID
```

## Use output in scripts

Standard output contains only a successful response body. `--json` writes the
same JSON on one line. Human diagnostics and failed API bodies go to standard
error.

```sh
openagents --json api repos/OWNER/REPOSITORY/issues >issues.json
```

A non-`2xx` response fails the command. The CLI includes the response's request
ID in the error when the server supplies one. Preserve that ID when you report
an API failure.

Do not parse human output from named repository commands as JSON. Add `--json`
to those commands. `openagents api` always returns the response body as JSON.

## Related documentation

- [CLI command reference](command-reference.md)
- [Install the CLI](install.md)
- [REST API assessment](../github-api-issues-projects-assessment.md)
