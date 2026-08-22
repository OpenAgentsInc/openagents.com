# Call the API with the OpenAgents CLI

The `openagents api` command sends an authenticated request to any OpenAgents
API route and writes the response body as JSON. Use it for Issues, Projects,
and other routes that do not have a named CLI command.

The current release does not provide `openagents issue` or
`openagents project` commands. `openagents api` is the supported terminal path
for those resources.

## Before you begin

Install the CLI and sign in to the profile you intend to use:

```sh
npm install --global @openagentsinc/cli@latest
openagents auth login
openagents auth status
```

You can also set `OPENAGENTS_TOKEN` to an `oa_pat_` user token for one process.
The token must carry the authority required by the route.

## Address a route

A relative path resolves under `/api/v3/`:

```sh
openagents api repos/OWNER/REPOSITORY/issues
```

`repos/OWNER/REPOSITORY/issues` and
`/api/v3/repos/OWNER/REPOSITORY/issues` name the same route. An absolute path
must start with `/api/`. A complete URL must use the exact selected API origin.
The CLI refuses another origin and paths outside the API namespace.

## Select a method and body

Use `-X` or `--method` to select `GET`, `POST`, `PATCH`, `PUT`, or `DELETE`.
Without it, a request without a body uses `GET`, and a request with a body uses
`POST`.

Use repeatable `-f` or `--field` flags for string fields:

```sh
openagents api -X POST \
  -f title="Search returns duplicates" \
  -f body="Include steps to reproduce" \
  repos/OWNER/REPOSITORY/issues
```

Use `--input` for numbers, booleans, arrays, nested objects, or `null`:

```sh
printf '%s' '{"labels":["bug"],"milestone":3}' | \
  openagents api -X PATCH --input - \
  repos/OWNER/REPOSITORY/issues/41
```

`--input` reads a file, or standard input when you pass `-`. `--field` and
`--input` are mutually exclusive. The CLI supplies the bearer credential and
refuses an `Authorization` header override.

## Work with issues

List issues. The response contains an `issues` array:

```sh
openagents api 'repos/OWNER/REPOSITORY/issues?state=all'

openagents api 'repos/OWNER/REPOSITORY/issues?state=all' | \
  jq -r '.issues[] | [.number, .state, .title] | @tsv'
```

Read, create, close, reopen, and comment on an issue:

```sh
openagents api repos/OWNER/REPOSITORY/issues/41

openagents api -X POST -f title="Search returns duplicates" \
  -f body="Steps to reproduce" \
  repos/OWNER/REPOSITORY/issues

printf '%s' '{"state":"closed","state_reason":"completed"}' | \
  openagents api -X PATCH --input - \
  repos/OWNER/REPOSITORY/issues/41

openagents api -X PATCH -f state=open \
  repos/OWNER/REPOSITORY/issues/41

openagents api -X POST -f body="The fix is available in staging." \
  repos/OWNER/REPOSITORY/issues/41/comments
```

## Work with projects

List and read repository projects. The list response contains a `projects`
array:

```sh
openagents api repos/OWNER/REPOSITORY/projectsV2
openagents api repos/OWNER/REPOSITORY/projectsV2/PROJECT_NUMBER
openagents api repos/OWNER/REPOSITORY/projectsV2/PROJECT_NUMBER/items
openagents api repos/OWNER/REPOSITORY/projectsV2/PROJECT_NUMBER/fields
```

Create a project and add an issue. `issue_id` is the numeric database ID in the
issue response, not its repository-local issue number:

```sh
openagents api -X POST -f title="Release readiness" \
  repos/OWNER/REPOSITORY/projectsV2

printf '%s' '{"issue_id":42,"values":{"Status":"To Do"}}' | \
  openagents api -X POST --input - \
  repos/OWNER/REPOSITORY/projectsV2/PROJECT_NUMBER/items
```

Update an item's values:

```sh
printf '%s' '{"values":{"Status":"Done"}}' | \
  openagents api -X PATCH --input - \
  repos/OWNER/REPOSITORY/projectsV2/PROJECT_NUMBER/items/ITEM_ID
```

## Use output in scripts

Standard output contains only a successful response body. `--json` writes the
same JSON on one line. A non-`2xx` response fails the command and writes the API
error and request ID to standard error.

```sh
openagents --json api repos/OWNER/REPOSITORY/issues >issues.json
```

Preserve the request ID when you report a failed API call.

## Related documentation

- [REST API](/docs/rest-api)
- [API tokens](/docs/api-tokens)
- [CLI command reference](/docs/cli-command-reference)
