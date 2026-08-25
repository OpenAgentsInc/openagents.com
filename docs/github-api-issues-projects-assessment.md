# GitHub-shaped Issues and Projects API assessment

Date: 2026-08-22

Status: Repository-scoped subset implemented; bounded compatibility gaps remain

## Intent

OpenAgents exposes a bounded `/api/v1` subset so familiar GitHub-shaped clients
can interact with issues and project boards. The shape is a compatibility aid,
not a claim that the application implements the complete GitHub API.

The router and controller tests are the executable source of truth. This
document records the intended subset and known gaps; it must not be used to
infer authorization that the server does not enforce.

## Implemented issue subset

| Concern | Methods and paths |
| --- | --- |
| Issues | `GET, POST /repos/{owner}/{repo}/issues`; `GET, PUT, PATCH /repos/{owner}/{repo}/issues/{number}` |
| Comments | `GET, POST /repos/{owner}/{repo}/issues/{number}/comments`; `GET, PUT, PATCH, DELETE /repos/{owner}/{repo}/issues/comments/{id}` |
| Labels | `GET, POST /repos/{owner}/{repo}/labels`; `GET, PUT, PATCH, DELETE /repos/{owner}/{repo}/labels/{name}` |
| Issue labels | `GET, POST /repos/{owner}/{repo}/issues/{number}/labels`; `DELETE /repos/{owner}/{repo}/issues/{number}/labels/{name}` |
| Assignees | `GET /repos/{owner}/{repo}/assignees`; `GET /repos/{owner}/{repo}/assignees/{login}`; `GET, POST, DELETE /repos/{owner}/{repo}/issues/{number}/assignees` |
| Milestones | `GET, POST /repos/{owner}/{repo}/milestones`; `GET, PUT, PATCH, DELETE /repos/{owner}/{repo}/milestones/{number}` |

Cross-repository issue lists, organization issue lists, event/timeline APIs,
locks, dependencies, sub-issues, and suggestion APIs are not implemented.

### Pull requests in the issue list

A pull request is an issue row with a `pull_requests` record pointing at it, so
the two share one number space, exactly as they do on GitHub.
`GET /repos/{owner}/{repo}/issues` therefore returns both kinds and marks each
pull request the way GitHub does:

- A top-level `pull_request` object with `url`, `html_url`, and `merged_at`.
  Its presence is the fact a client tests for; a plain issue omits the key.
- A top-level `draft` boolean, present only on a pull-request-backed entry.

`diff_url` and `patch_url` are omitted because this forge serves no route for
them, and an advertised URL that answers `404` is worse than an absent one.

GitHub has no parameter that lists one kind without the other, so the
OpenAgents `type` filter (`issue`, `pull_request`, or `all`, defaulting to
`all`) is published under `issue.openagents` at `GET /api/v1` rather than
presented as a GitHub parameter.

## Implemented Projects V2 subset

| Method | Path |
| --- | --- |
| `GET, POST` | `/repos/{owner}/{repo}/projectsV2` |
| `GET, PATCH, DELETE` | `/repos/{owner}/{repo}/projectsV2/{project_number}` |
| `GET, POST` | `/repos/{owner}/{repo}/projectsV2/{project_number}/notes` |
| `PATCH, DELETE` | `/repos/{owner}/{repo}/projectsV2/{project_number}/notes/{note_id}` |
| `GET, POST` | `/repos/{owner}/{repo}/projectsV2/{project_number}/items` |
| `PATCH, DELETE` | `/repos/{owner}/{repo}/projectsV2/{project_number}/items/{item_id}` |
| `POST` | `/repos/{owner}/{repo}/projectsV2/{project_number}/items/{item_id}/move` |
| `GET, POST` | `/repos/{owner}/{repo}/projectsV2/{project_number}/fields` |
| `PATCH, DELETE` | `/repos/{owner}/{repo}/projectsV2/{project_number}/fields/{field_id}` |
| `GET` | `/repos/{owner}/{repo}/projectsV2/{project_number}/items/{item_id}/events` |

The project-creation endpoint and the item move endpoint are OpenAgents
extensions, because the comparable GitHub Projects V2 workflows are not supplied
by the assessed REST surface. Item read by id, field read by id, views, draft
items, and organization projects remain unimplemented.

### The project lifecycle

A project moves along two independent axes:

- `state` is `open` or `closed`, and `PATCH` moves it. Closing says the work the
  board tracked reached an end; reopening says it did not.
- `archived` is a boolean, and `PATCH` moves it too. Archiving says the board
  left the working set, whatever became of the work. It is reversible, and it
  records `archived_at`.

Keeping the archive off `state` means every reader of `open` and `closed` — the
API, the board, the workspace tabs — keeps reading the two values it always
read. A project object reports both `archived` and `archived_at`, so a client
never infers one axis from the other.

`GET /repos/{owner}/{repo}/projectsV2` leaves archived projects out. Pass
`archived=true` to include them.

`DELETE` on a project needs two keys, not one: a writable membership in the
repository, and a project already in the archive. A project that is not archived
returns `422` and is preserved. The board pairs its delete control with a
confirmation prompt; an API caller has no prompt, so archiving is the deliberate
step that stands in for one. Deleting removes the project's fields and items,
never the issues those items referenced, and never the append-only item event
history.

### Project fields

A field declares one stored column of a board. Its `data_type` is `text`,
`number`, `date`, `single_select`, or the OpenAgents `promise_state`, checked in
the changeset and again by a database constraint.

- Names are unique within a project, compared without case. The name is the key
  an item stores its value under, so two fields sharing one would make a stored
  value ambiguous.
- `single_select` and `promise_state` carry a non-empty `options.values` list.
  Every other data type carries no options.
- An option is either a name, where the name is its identifier, or an object
  with a string `id` and `name`, where the identifier survives a relabel. An
  item stores the identifier.
- A `PATCH` rename rewrites the stored key on every item of the project in the
  same transaction, so a rename never empties the column.
- A `PATCH` never changes `data_type`. Values already stored were written
  against the old type, and reinterpreting them is a destructive change wearing
  an edit's clothes.
- A `PATCH` may add options. Dropping an option that items still carry returns
  `422` and names the identifiers still in use.
- A `DELETE` on a field that items still carry returns `422` and preserves both
  the field and the values.

Item values are checked against the fields a project declares: a `single_select`
value must name one of the field's options, a `number` must be a number, and a
`date` must be an ISO 8601 date. A value under a key no field declares passes
through untouched, so a board can carry a value written before its field
existed.

### Project items

An item is a board's view of one issue. The issue stays canonical: adding it to
a board, moving it, and removing it change the board and say nothing about the
work.

- **Membership is a set.** `POST .../items` for an issue the board already
  carries returns `200` and the membership it already has, not `422`. A client
  that retries a request it never saw the answer to has asked for a state that
  already holds. The same issue sits on any number of boards at once, and each
  board keeps its own field values for it.
- **`DELETE .../items/{item_id}` removes the item and keeps the issue.** A
  second `DELETE` on the same item returns `404`: the item is gone and the path
  names nothing. The removal is appended to the item's event log before the row
  goes, and to the project's activity feed as well, because the item log stops
  being reachable through the item once the item is gone.
- **`POST .../items/{item_id}/move` moves one card.** The body carries `values`,
  merged the way `PATCH` merges them, and `position`, a one-based rank within
  the destination column. A body with only `position` is a reorder within the
  current column. A body with only `values` lands the card at the end of the
  column it names. A body with neither reads the item back unchanged.
- **Positions are dense and one-based after every move.** The write takes a row
  lock on the project, reads the whole board inside it, splices the card into
  the order the request asks for, and renumbers the result. Two concurrent moves
  onto the same rank therefore settle to one defined order, and neither loses a
  card.
- **A move that changes nothing appends no event and announces nothing**, so a
  retry is indistinguishable from the request it repeats.
- **A stale option identifier is refused.** A `values` change naming an option
  the field does not offer returns `422` and changes nothing, the same check
  `PATCH` applies.
- **A source repository the caller cannot read stays invisible.** Every item
  operation resolves the item through the reader's repository visibility, so a
  card sourced from a private repository returns `404` rather than confirming it
  exists.

Every item mutation appends one actor-attributed entry to the item's event log
at `.../items/{item_id}/events`, and announces itself on the repository's
project topic, so a connected board updates without a reload.

### Board columns

A board renders the project's stored fields rather than a fixed set of headings.
The column set is the `promise_state` field's options if the project declares
one, otherwise a `single_select` field named **Status**, otherwise the three
default columns a project has before it declares any field at all.

A column carries the option's identifier and its label separately, because an
item stores the identifier. Relabelling an option renames the heading and leaves
every card where it is. A card whose stored value the field no longer offers is
stale rather than missing, so it renders in a **No status** column that exists
only while something is in it.

Project lifecycle and field changes append an actor-attributed activity entry,
readable at `.../notes?kind=activity`.

### Differences from GitHub Projects V2

These are deliberate divergences, not gaps waiting on parity work:

- A project carries one Markdown `description`. GitHub Projects V2 splits
  project prose into a short description and a separate README, and exposes both
  only through GraphQL. One canonical field keeps the API, the CLI, and the board
  describing the same thing.
- Project notes are an OpenAgents surface with no GitHub REST equivalent. They
  hold project-wide context — operating assumptions, triage decisions,
  provider-order changes, paused lanes — that would otherwise be filed as an
  issue comment on whichever issue happened to be open at the time.
- Discussion notes and activity entries share one table and one paginated read,
  distinguished by `kind`. An activity entry is immutable and is written in the
  same transaction as the change it records, so the log cannot describe an update
  that did not commit. GitHub keeps its equivalent record in a separate event
  API.
- Edit and delete authority for a discussion note is its author, not repository
  write access. Repository membership stays the authority boundary for the
  project itself.
- Notes are never embedded in the project object. A long-lived board accumulates
  decisions without bound, so the timeline is a separate paginated read.

### Toward a Linear-compatible shape

The longer-term direction is a Linear-shaped tracker, as recorded in
`docs/2026-08-20-linear-design-github-shape.md`. Project descriptions and notes
move that way without breaking the GitHub-shaped subset: a description maps onto
a Linear project's summary, and notes map onto project updates, which Linear
treats as first-class project-level records rather than comments on an issue. The
names stay GitHub-shaped where a GitHub client reads them, and the semantics stay
compatible with where the tracker is going.

## Error envelope

Every refusal from an issue-family route answers with one envelope. Before this
contract a caller met six incompatible bodies for the same class of failure, so
reading one refusal taught you nothing about the next.

```json
{
  "message": "Validation Failed",
  "code": "validation_failed",
  "status": 422,
  "documentation_url": "https://openagents.com/api/v1",
  "request_id": "GM5_fLaSSJDluDMAACUh",
  "errors": { "state": ["must be one of: open, closed, all"] }
}
```

| Key | Meaning |
| --- | --- |
| `message` | The human sentence. A GitHub-shaped client reads this key, and a missing resource still reads exactly `Not Found`. |
| `code` | A stable identifier from the table below. Branch on this, not on `message`. |
| `status` | The HTTP status, repeated so a logged body is self-describing. |
| `documentation_url` | This deployment's `GET /api/v1`, which publishes the codes and the routes. |
| `request_id` | The value of the response's `x-request-id`. Name it when you report a failure. |
| `errors` | Field name to an array of messages. Always present, `{}` when the failure is not field-level. |

Each code carries exactly one status, chosen by `OpenAgentsWeb.ApiError` rather
than by the controller, so two routes cannot disagree about what one failure is
worth.

| Code | Status | Raised when |
| --- | --- | --- |
| `unauthenticated` | `401` | The route needs a bearer token and the request has none, or the token lacks the scope. |
| `forbidden` | `403` | The caller is known but may not act. |
| `agent_participation_forbidden` | `403` | An agent credential may not participate in this repository. |
| `not_found` | `404` | The resource is absent, or it is private and the caller may not read it. These are deliberately indistinguishable. |
| `label_not_on_issue` | `404` | A remove-label call names a label the issue does not wear. |
| `dependency_not_found` | `404` | A remove-dependency call names an issue that is not a prerequisite. |
| `validation_failed` | `422` | A field or filter was rejected. Read `errors` for the detail. |
| `delete_failed` | `422` | The resource exists but could not be removed. |

Two refusals additionally carry a legacy `error` key beside the envelope,
because published clients already read it: the agent and human participation
refusals on issue and comment creation, and the `401` from the bearer-token
pipelines. New clients read `code`. No key that a client already read has been
renamed or removed.

`GET /api/v1` publishes which routes answer with this envelope, under each
route's `errors` field. Routes marked `legacy` there still answer with their own
shape; the repository, deployment, box, forum, and agent families have not been
converged yet, and `priv/api-contracts/repositories-v1.json` remains the
description of the repository family's three-key shape, which the envelope is a
superset of.

## Route inventory

`GET /api/v1` is the root document. It is derived from
`OpenAgentsWeb.Router.__routes__/0` through `OpenAgentsWeb.ApiRouteAuthority`,
never maintained beside it, so it cannot claim a route the router does not
serve or omit one it does.

```sh
openagents api /api/v1
```

It carries:

- `api_version` and `version`, so a client can pin what it read.
- `extensions`, the OpenAgents-specific fields, filters, and endpoints.
- `errors`, the envelope keys and the stable code table above.
- `families`, every resource family the API serves.
- `routes`, one entry per live route:

```json
{
  "method": "GET",
  "path": "/api/v1/repos/{owner}/{repo}/issues/{issue_number}",
  "authority": "optional_bearer",
  "family": "issue",
  "errors": "envelope",
  "mutation": false
}
```

`authority` is `anonymous`, `optional_bearer`, or `required_bearer`. `family`
groups the routes that must agree with one another. `errors` is `envelope` or
`legacy`.

Three tests keep the document honest, and each fails the build rather than
drifting quietly:

- `OpenAgentsWeb.ApiRouteAuthorityTest` fails when the router and the inventory
  disagree in either direction, and when a classification does not match what
  the pipeline does to an anonymous request.
- `OpenAgentsWeb.ApiExtensionControllerTest` fails when the published document
  omits a live route, or when a route is missing an authority, family, or error
  classification.
- `OpenAgentsWeb.ApiErrorContractTest` dispatches every route the document says
  answers with the envelope and fails when the body is anything else.

Adding a route to the router without classifying it fails the first two.
Classifying a route as `envelope` and then rendering a bespoke body fails the
third.

## CLI access

`@openagentsinc/cli@0.2.1` exposes the complete implemented surface through
`openagents api`. The published CLI does not yet provide named `issue` or
`project` commands.

```sh
openagents api 'repos/OWNER/REPOSITORY/issues?state=all'
openagents api repos/OWNER/REPOSITORY/projectsV2
```

See [Call the API with the OpenAgents CLI](openagents-cli/api.md) for request
bodies, response envelopes, Issues recipes, and Projects recipes.

## Enforced authority contract

These are current measured behaviors:

- `/api/v1` anonymous and optional-bearer reads and authenticated writes use
  separate pipelines.
  Writes require an expiring digest-only `oa_pat_…` bearer with exact
  `forge:write` scope. An authenticated person creates and revokes credentials
  at `/settings/api-tokens`; plaintext is shown once.
- Owner and repository path values resolve a canonical repository row. Public
  reads expose only repositories marked public; writes additionally require a
  writable membership for the PAT principal.
- Resource reads and mutations include repository ownership in their database
  query. Composite foreign keys reject cross-repository comments, label and
  assignee links, and milestones. A project item stores separate project and
  source-issue repository identities, so one board can include a readable
  issue from another repository without weakening project write authority.
- Issue and milestone numbers are repository-local. Project numbers are also
  repository-local for the repository-shaped LiveView surface.
- Project list, show, update, item, update-item, field, and note actions resolve
  the repository from the route. Public repositories allow anonymous reads.
  Private reads and every write require membership in that repository.
- A project update accepts only `title`, `description`, `state`, and `archived`,
  and rejects a `state` other than `open` or `closed`, or a non-boolean
  `archived`, with `422`. Repository and owner overrides in the request body are
  dropped.
- Project delete, field update, and field delete resolve the repository from the
  route and require a writable membership in it, the same boundary every other
  project write reads. A non-member receives `404` for all three, so a private
  repository's projects and fields stay indistinguishable from missing ones.
- A project note stores both its project and its repository, and reads carry both
  in the query, so a note cannot be read or written across a repository
  boundary. Editing or deleting a note requires authorship: another member with
  write access receives `403`. An activity entry receives `403` for both.
- Item creation accepts either the legacy repository-local `issue_number` or
  an `issue` object with `owner`, `repo`, and `number`. Cross-repository adds
  require write access to the project repository and read access to the source
  repository. Item lists omit source issues that the current viewer cannot
  read. Promise registry items are an OpenAgents-specific extension. They use
  a stored `promise_state` field, state gates, resolvable evidence, and an
  append-only event history. This deliberately differs from GitHub Projects
  V2, which does not define these product-claim semantics.
- Assignee reads return active repository members with writable roles, and
  issue assignment accepts only those members.

## Remaining compatibility gaps

These are compatibility limits, not authorization fallbacks:

- Issue creation with a nonexistent label returns 422; only the
  add-labels-to-issue endpoint creates labels on the fly, matching GitHub.
- Optional-bearer private reads cover repository, issue, and project base
  routes. Comment, label, assignee, and milestone read routes remain
  public-repository reads.
- Nonnumeric issue and milestone numbers can produce `500 Internal Server
  Error` instead of `404 Not Found`.
- Pagination and link headers are a bounded local contract, not complete
  Octokit or `gh` parity.
- The error envelope is a superset of GitHub's: `message` and `errors` keep
  GitHub-compatible meaning, and `code`, `status`, `documentation_url`, and
  `request_id` are additions. GitHub's `errors` is an array of resource
  objects; this one is a field-to-messages map, which is what the local
  clients already read.
- Families outside the issue family still answer with their own error shapes.
  `GET /api/v1` names which, so a client can tell without probing.

Closed on 2026-08-21, each pinned by tests: label rename through `new_name`,
create-on-add for missing labels at the issue-labels endpoint, 404 for
removing a label an issue does not wear, and path-correct percent-encoding of
label URLs so an advertised label URL resolves through the show endpoint.

Gate 6 supplied the explicit API principal and mutation policy. Gate 7 supplied
repository entities, foreign keys, scoped uniqueness, ownership checks, and
cross-repository isolation tests. Further compatibility work must preserve
those authority boundaries.

## Evidence

- `test/openagents_web/controllers/issue_controller_test.exs`
- `test/openagents_web/controllers/comment_controller_test.exs`
- `test/openagents_web/controllers/label_controller_test.exs`
- `test/openagents_web/controllers/issue_label_controller_test.exs`
- `test/openagents_web/controllers/api_error_contract_test.exs`
- `test/openagents_web/controllers/api_extension_controller_test.exs`
- `test/openagents_web/api_error_test.exs`
- `test/openagents_web/api_route_authority_test.exs`
- `test/openagents_web/controllers/assignee_controller_test.exs`
- `test/openagents_web/controllers/issue_assignee_controller_test.exs`
- `test/openagents_web/controllers/milestone_controller_test.exs`
- `test/openagents_web/controllers/project_controller_test.exs`
- `test/openagents/project_notes_test.exs`
- `test/openagents_web/live/project_show_live_test.exs`
- `test/openagents_web/controllers/repository_isolation_controller_test.exs`
- `test/openagents/repositories_test.exs`
