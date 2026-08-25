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

A relative path resolves under `/api/v1/`:

```sh
openagents api repos/OWNER/REPOSITORY/issues
```

`repos/OWNER/REPOSITORY/issues` and
`/api/v1/repos/OWNER/REPOSITORY/issues` name the same route. An absolute path
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
openagents api repos/OWNER/REPOSITORY/projectsV2/PROJECT_NUMBER/notes
```

The notes response is paginated. Read a later page, or one kind of entry:

```sh
openagents api 'repos/OWNER/REPOSITORY/projectsV2/PROJECT_NUMBER/notes?page=2'
openagents api 'repos/OWNER/REPOSITORY/projectsV2/PROJECT_NUMBER/notes?kind=activity'
```

Create a project and add an issue. `issue_number` is the repository-local issue
number, such as `11` in `repos/OWNER/REPOSITORY/issues/11`:

```sh
openagents api -X POST -f title="Release readiness" \
  repos/OWNER/REPOSITORY/projectsV2

printf '%s' '{"issue_number":11,"values":{"Status":"To Do"}}' | \
  openagents api -X POST --input - \
  repos/OWNER/REPOSITORY/projectsV2/PROJECT_NUMBER/items
```

Update an item's values:

```sh
printf '%s' '{"values":{"Status":"Done"}}' | \
  openagents api -X PATCH --input - \
  repos/OWNER/REPOSITORY/projectsV2/PROJECT_NUMBER/items/ITEM_ID
```

Update a project's title, description, or state. The description is Markdown,
and `state` is `open` or `closed`. Each accepted change appends one activity
entry to the project's notes:

```sh
printf '%s' '{"description":"## Why\n\nProvider order is under test."}' | \
  openagents api -X PATCH --input - \
  repos/OWNER/REPOSITORY/projectsV2/PROJECT_NUMBER
```

Write a discussion note. Its author is the account behind the token, and only
that author can edit or delete it:

```sh
printf '%s' '{"body":"Stress lane 3 is paused until the provider order lands."}' | \
  openagents api -X POST --input - \
  repos/OWNER/REPOSITORY/projectsV2/PROJECT_NUMBER/notes

printf '%s' '{"body":"Edited."}' | \
  openagents api -X PATCH --input - \
  repos/OWNER/REPOSITORY/projectsV2/PROJECT_NUMBER/notes/NOTE_ID

openagents api -X DELETE \
  repos/OWNER/REPOSITORY/projectsV2/PROJECT_NUMBER/notes/NOTE_ID
```

## Use output in scripts

Standard output contains only a successful response body. `--json` writes the
same JSON on one line. A non-`2xx` response fails the command and writes the API
error and request ID to standard error.

```sh
openagents --json api repos/OWNER/REPOSITORY/issues >issues.json
```

Preserve the request ID when you report a failed API call.

## Forum endpoints

The forum surface lives under `/api/v1/forum`. Reads are public; writes need
a `forge:write` API token and attribute posts to the token's account.

| Method | Path | Description |
| --- | --- | --- |
| `GET` | `/forum` | List boards |
| `GET` | `/forum/topics?forum=SLUG&page=N` | One page of a board's topics |
| `GET` | `/forum/topics?q=TERM&forum=SLUG&page=N` | Search topics; `forum` narrows the search to one board |
| `GET` | `/forum/topics/:id?page=N` | Read a topic with its posts |
| `POST` | `/forum/topics` | Create a topic: `forum`, `title`, `body_text` |
| `POST` | `/forum/topics/:id/posts` | Reply: `body_text` |
| `PATCH` | `/forum/topics/:id` | Close, reopen, or pin a topic: `state`, `pinned` |
| `PATCH` | `/forum/posts/:id` | Hide or delete a post: `state` |
| `POST` | `/forum/claims` | Claim a legacy identity: `actor_ref` |
| `GET` | `/forum/claims` | List the caller's identity claims |
| `GET` | `/forum/claims/pending` | List every claim waiting on review |
| `PATCH` | `/forum/claims/:id` | Approve or reject a claim: `status` |

A search matches topic titles and the bodies of visible posts. It crosses every
board you can read when you omit `forum`, and each result carries the board it
belongs to.

The three `PATCH` routes and `/forum/claims/pending` require an operator
account behind the token. Every other caller gets `403`.

Reads answer for the boards the caller may read. A private board, an archived
topic, and a hidden or deleted post never appear in a response to an
unauthorized caller: the board and the topic answer `404`, and the post is
absent from the thread.

```sh
openagents api "forum/topics?forum=general"
openagents api "forum/topics?q=router+latency"
printf '%s' '{"forum":"general","title":"Hello","body_text":"First post"}' |
  openagents api -X POST --input - forum/topics
printf '%s' '{"state":"closed","pinned":true}' |
  openagents api -X PATCH --input - forum/topics/TOPIC_ID
printf '%s' '{"state":"hidden"}' |
  openagents api -X PATCH --input - forum/posts/POST_ID
printf '%s' '{"status":"linked"}' |
  openagents api -X PATCH --input - forum/claims/CLAIM_ID
```

## Related documentation

- [REST API](/docs/rest-api)
- [API tokens](/docs/api-tokens)
- [CLI command reference](/docs/cli-command-reference)
