# Forge cache recovery

Date: 2026-08-22

Status: Active operational procedure.

Use this runbook when the same forge blob, tree, or clone request differs
between fleet nodes or returns `503`. The WAL is the durable push authority.
Each node's bare Git repository is a disposable projection of that authority.

## Expected failure behavior

`OpenAgents.Forge.Sync` serializes synchronization and pushes per repository.
When it detects missing objects, it builds a complete sibling repository,
verifies every authoritative ref, and atomically activates that repository.
Readers never observe the sibling while it is incomplete.

Replay applies one WAL entry at a time and moves the refs to the post-state
that entry recorded before the next entry runs, then proves that every object
ID the entry introduced exists. `git receive-pack` exits `0` even when it
rejects every ref update, so the exit status is not evidence; the object check
is. An entry that fails the check does not advance the applied sequence, and
the node rebuilds from sequence `0` instead. See `INVARIANTS.md`,
REPOSITORY-003.

If WAL replay or activation fails, the node:

- preserves the last complete local repository cache;
- returns `503` for the affected forge read instead of a false `404`;
- reports `forge_cache_ready: false` through the local cluster health report;
- returns `503` from `/health` so the load balancer can stop admitting traffic;
- logs `forge_sync_unavailable` with the repository, operation, and typed cause.

A later successful synchronization clears that repository's failure and
restores readiness without a process restart.

## Diagnose a divergent node

1. Request the same blob or Git ref advertisement directly from every fleet
   node. Record the node name, HTTP status, response size, and revision.
2. Compare the affected repository's applied WAL sequence on every node. A
   sequence of `0` or a sequence behind healthy peers identifies a stale local
   projection; it does not identify a missing durable push.
3. Search the node log for `forge_sync_cache_rebuild` and
   `forge_sync_unavailable`. Record the `operation`, `code`, and repository.
4. Inspect ownership and write permissions from the repository root through
   the failing object's two-character fan-out directory. Run the check as the
   same user that runs the release.
5. Verify that the WAL index and every referenced WAL object remain readable.
   Stop if the authority is unavailable. Do not infer repository absence from
   a cache failure.

The 2026-08-22 incident followed this pattern. One of three production nodes
had a root-owned Git object fan-out directory under a cache otherwise owned by
the release user. WAL replay failed with `EACCES` on that node. Requests through
the load balancer alternated between successful responses from two nodes and
false `404` responses from the damaged node.

## Recover one node

1. Keep the node out of load-balancer admission while
   `forge_cache_ready` is `false`.
2. Confirm that the WAL is readable and that another node can materialize the
   same repository and authoritative refs.
3. Correct the state-directory ownership so the release user can create Git
   object fan-out directories and files. Apply the correction only to the
   affected state path.
4. Move the affected bare repository cache aside. Do not delete or modify WAL
   indexes or WAL objects. Keep the moved cache until verification finishes.
5. Trigger repository synchronization or restart the application so boot
   convergence replays the WAL into a new local cache.
6. Verify the applied WAL sequence, every authoritative ref, the reported blob,
   Git ref advertisement, and `/health` on that node.
7. Restore load-balancer admission only after `forge_cache_ready` and the
   aggregate `ready` value are both `true`.
8. Remove the moved cache after the node passes verification.

## Prevent recurrence

- Create and mount the forge state directory with the release user's numeric
  UID and GID before the application starts.
- Never run cache repair, import, or Git maintenance commands as a different
  user against the live state directory.
- Alert when `forge_cache_ready` becomes `false` or when
  `forge_sync_unavailable` appears.
- Include a multi-node blob and clone comparison in staging resilience tests.
- Treat a forge `503` as retryable. Treat `404` only as an authoritative
  repository, ref, tree, or blob absence after synchronization succeeds.

## Focused verification

Run the cache, Git HTTP, and health contracts together:

```sh
mix test test/openagents/forge/sync_test.exs \
  test/openagents/forge/wal_replay_test.exs \
  test/openagents/forge/git_http_test.exs \
  test/openagents_web/controllers/health_controller_test.exs
```
