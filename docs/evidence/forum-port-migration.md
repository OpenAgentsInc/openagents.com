# Forum port migration evidence

Source of truth for the one-time import of the legacy Effect forum into the
Phoenix application database.

Every recorded run names its destination database. A run that does not say
where it landed proves nothing: the 2026-08-22 record below passed every check
it made — content integrity, idempotency, count reconciliation — while
production served an empty forum.

## Run the import

```sh
FORUM_IMPORT_DATABASE_URL=... \
  FORUM_IMPORT_DESTINATION_DATABASE_URL=... \
  mix openagents.forum.import
```

The source connection comes from `FORUM_IMPORT_DATABASE_URL`, and the
destination from `FORUM_IMPORT_DESTINATION_DATABASE_URL`. Without the
destination variable the run writes to whatever database the application is
configured with, which on a workstation is the development one. The task asks
the live connection for `current_user` and `current_database()` and prints
them with the address it dialed, before it writes and again in its report, so
a transcript records the destination the server confirms rather than the one
the operator intended.

Both databases are reached through the Cloud SQL Auth Proxy on localhost. The
proxy needs `roles/cloudsql.client`.

## Runs

### 2026-08-23 — production

Destination: Cloud SQL `openagentsgemini:us-central1:sarah-postgres`, database
`sarah`, user `sarah_app`. This is the database the production fleet serves
from. Reported by the run as `sarah_app@sarah`.

Source: Cloud SQL `openagentsgemini:us-central1:khala-sync-pg`, database
`khala_sync_prod`.

Taken first: on-demand Cloud SQL backup `1787506768627`, status `SUCCESSFUL`.

| Table | Source rows | Imported | Destination total |
| --- | --- | --- | --- |
| `forum_forums` | 10 | 10 | 10 |
| `forum_topics` | 230 | 230 | 230 |
| `forum_posts` | 1391 | 1375 | 1375 |

Parent and quote references linked: 1149. Counters refreshed: 10 boards, 9
topics.

Verification, run against production:

- `GET /api/v3/forum` returns nine boards. Ten boards were imported; `void`
  carries the legacy `discoverability: unlisted`, and `list_public_forums/0`
  keeps unlisted boards out of the board list while they still answer to
  their slug. Nine listed plus one unlisted is the correct result, not a
  missing row.
- Production holds 10 boards, 230 topics, and 1,375 posts.
- Five legacy topic UUIDs resolve at `/api/v3/forum/topics/{id}`. Across
  those five topics, all 70 posts hash identically to the legacy rows:
  `md5(body_text || id)` per post, aggregated per topic in `post_number`
  order, matches `khala_sync_prod` exactly.
- Idempotency: a second run imported zero rows, linked zero references, and
  refreshed zero counters, reporting the same destination.
- The sixteen skipped posts are still the only skipped rows, and still the
  same set: ten `content.forum.artanis.*` and six
  `content.forum.work_request.<id>`.

### 2026-08-22 — development

Destination: a development database on the workstation that ran the import.
The record did not say so, which is why the gap survived the port.

| Table | Source rows | Imported | Destination total |
| --- | --- | --- | --- |
| `forum_forums` | 10 | 10 | 10 |
| `forum_topics` | 230 | 230 | 230 |
| `forum_posts` | 1391 | 1375 | 1375 |

The task as committed could not have produced this table against the shipped
schema. Three defects had to be fixed before the production run, and the first
of them is fatal on the first insert:

- The task wrote `created_at` to `forum_forums`, whose migration names the
  column `inserted_at`. Against the shipped schema the first insert raises
  `undefined_column` and nothing is imported at all. This run therefore
  measured an earlier iteration of the schema, not the one that shipped.
- `link_post_references/1` read parent and quote ids off entries whose fields
  had already been set to `nil`, so it linked nothing and 1,160 legacy parent
  references were silently dropped.
- Nothing populated `forum_forums.topic_count`, `forum_forums.post_count`, or
  `forum_topics.post_count`. `list_public_forums/0` orders by `topic_count`
  and both the board list and the API render these counters, so every
  imported board would have read "0 topics".

A fourth defect was found during the production run itself: passing a
destination URL merged over the application's repository configuration, which
left the development `socket_dir` in place. Postgrex prefers a unix socket to
the host and port it was given, so the run connected somewhere other than the
address it printed. The task now replaces the configuration outright and
reports the database the server confirms.

## Skipped rows

Sixteen posts are skipped because their bodies are not in
`forum_post_bodies`. Their `content_ref` values point at other stores: ten at
`content.forum.artanis.*` (agent status and delivery notices) and six at
`content.forum.work_request.<id>` (work-request payloads). These are agent
pipeline records, not human posts. Recovering them means importing from those
stores' tables and is deliberately out of scope.

## Board descriptions

The legacy `forum_forums.description_ref` holds a
`content.forum.<board>.description` pointer, and nothing in `khala_sync_prod`
resolves those pointers to text. Importing the value as-is would print
`content.forum.mining.description` under the board title on the forum home
page.

`OpenAgents.Forum.BoardDescriptions` carries a written description for each of
the ten boards, read from what the board's topics actually contain. The import
seeds those words; a board with no written description falls back to dropping
an unresolvable pointer rather than showing it. The descriptions are product
copy — edit them in that module without touching import logic.

## Counters

Board and topic counters are derived from the rows that actually landed, not
copied from the legacy columns. Topic counts per board match the legacy values
exactly; post counts differ only where a skipped row was excluded, on
`artanis` (202 legacy, 192 imported) and `work-requests` (71 legacy, 65
imported). The displayed number therefore matches what a reader can click
through to.

## State normalization

- Legacy topic `pin_state: sticky` maps to `pinned`; `announcement` maps to
  `normal`, which is the only other value the check constraint admits.
- Legacy post state `edited` maps to `visible`; `tombstoned` maps to
  `deleted`.
- Parent and quote references that point at posts missing from the
  destination are dropped rather than failing the import. Eleven of the 1,160
  legacy parent references point at skipped posts and are dropped for that
  reason.

## Identity linking

Legacy actors keep their original attribution (`actor_ref`, display name).
Accounts claim a legacy identity at `/forum/claim`; an operator approves or
rejects at `/admin/forum/claims`. Only links in status `linked` resolve a post
to an account (`OpenAgents.Forum.actor_user/1`).

## Cutover

The legacy TanStack routes were `/forum` (home) and `/forum/t/:topicId`
(thread). The Phoenix surface serves exactly those paths, and every migrated
row keeps its source UUID, so existing links resolve without redirects. No
runtime dependency on `khala_sync_prod` remains after import; retiring that
instance is a separate operations task.

At the time of the import, production served a revision on which `/forum` sits
in the authenticated live session, so anonymous readers are redirected to `/`
while signed-in readers see the boards. The move to the public live session is
on `main` and reaches readers with the next deploy, which is not part of this
import.
