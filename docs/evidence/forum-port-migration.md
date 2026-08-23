# Forum port migration evidence

Date: 2026-08-22

Source of truth for the one-time import of the legacy Effect forum into the
Phoenix application database. Run with:

```sh
FORUM_IMPORT_PASSWORD=... mix openagents.forum.import
```

## Results

| Table | Source rows | Imported | Destination total |
| --- | --- | --- | --- |
| `forum_forums` | 10 | 10 | 10 |
| `forum_topics` | 230 | 230 | 230 |
| `forum_posts` | 1391 | 1375 | 1375 |

## Verification

- Content integrity: `md5(body_text || id)` over the five oldest posts is
  byte-identical between `khala_sync_prod` and the destination.
- Idempotency: a second run imports zero rows; already-present rows are
  skipped by primary key.
- Counts reconcile: 1391 source posts minus 16 system-pipeline posts equals
  1375 imported.

## Skipped rows

Sixteen posts were skipped because their bodies are not in
`forum_post_bodies`. Their `content_ref` values point at other stores:
`content.forum.artanis.*` (agent status and delivery notices) and
`content.forum.work_request.<id>` (work-request payloads). These are agent
pipeline records, not human posts. Recovering them means importing from those
stores' tables and is deliberately out of scope.

## State normalization

- Legacy topic `pin_state: sticky` maps to `pinned`.
- Legacy post state `edited` maps to `visible`; `tombstoned` maps to `deleted`.
- Parent and quote references that point at posts missing from the source are
  dropped rather than failing the import.

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
