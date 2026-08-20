# Cut over production from Sarah to OpenAgents

Date: 2026-08-20

Status: Production is fenced until the isolated staging gates and database
rehearsal pass for one exact candidate.

This runbook replaces the Sarah release on the existing three-node production
fleet. It preserves the `openagents.com` load balancer and the `sarah`
PostgreSQL database. Treat the first OpenAgents release as a structural
replacement with a maintenance window. Do not use the hot-load or relup lanes
for this boundary.

## Current production boundary

Production currently uses these resources in `openagentsgemini`:

- Cloud SQL instance `sarah-postgres`, database `sarah`, and role `sarah_app`.
- Compute Engine instances `sarah-fleet-1`, `sarah-fleet-2`, and
  `sarah-fleet-3` in three zones.
- Global backend service `sarah-backend` and the existing `openagents.com`
  HTTPS frontend.
- The Sarah release as the serving application and the idle Sarah Cloud Run
  service as the application rollback target.

Do not rename these provider resources during the application cutover. Rename
them only in a later infrastructure migration after OpenAgents passes its
production observation window.

## Production admission conditions

Use one exact Git SHA and application image digest for every condition. Do not
waive a failed condition by rebuilding from another commit during the cutover.

- The exact-SHA release gate passes, including the default, browser, cluster,
  direct-deployment, relup, interrupted-install, rolling-replacement,
  infrastructure, and packaged-release stages.
- The dedicated project `openagents-staging-20260820` passes the isolation
  validator. Staging does not use a production database, service account,
  bucket, or secret.
- The candidate passes all Gate 14 cases on staging.
- The same candidate passes controlled failure injection and a measured
  15-minute soak on the pinned `openagents-staging-release` service. Later
  commits can deploy to another staging service without replacing this release
  candidate or resetting its clock.
- A fresh production backup restores into a disposable Cloud SQL instance.
  The migration-lineage bridge, all remaining migrations, candidate startup,
  last-known-good startup, row-count checks, and integrity checks pass there.
- Production Cloud SQL has daily backups, point-in-time recovery, and deletion
  protection enabled. Record the maintenance window if enabling point-in-time
  recovery restarts the primary.
- The latest on-demand backup finishes successfully before the writer fence.
- You have the exact prior production startup metadata, image digest, database
  backup identifier, and DNS or load-balancer rollback command.

The existing database did not have automated backups, point-in-time recovery,
or deletion protection enabled during the 2026-08-20 audit. Keep production
fenced until an operator enables and verifies all three controls.

## Rehearse the production migration

Run this procedure before scheduling the production window:

1. Create an on-demand backup of `sarah-postgres` and wait for `SUCCESSFUL`.
2. Restore the backup into a new disposable Cloud SQL instance. Do not attach
   an application, scheduler, webhook, queue consumer, or public authorized
   network to the copy.
3. Connect the exact candidate release through Cloud SQL Auth Proxy.
4. Run `bin/migration-lineage check`. Require `prior`, the reviewed map digest,
   14 baseline entries required, zero baseline entries present, and zero
   missing schema facts.
5. Record content-free counts for users, visitors, conversations, messages,
   turns, forge targets, forge builds, forge deploys, voice calls, recordings,
   machines, and coding jobs. Record only counts and integrity statuses.
6. Apply the bridge with the successful backup identifier:

   ```sh
   OPENAGENTS_STAGING_SNAPSHOT_ID='BACKUP_ID' \
     bin/migration-lineage --apply
   ```

7. Require `prior_baselined`, `changed: true`, 14 baseline entries present, and
   zero missing facts.
8. Run `bin/migrate`, then rerun `bin/migration-lineage check`.
9. Run foreign-key, uniqueness, orphan, and invalid-state checks. Compare every
   content-free count with the pre-migration count and explain each expected
   change.
10. Start the candidate against the copy with traffic, Forge deployment,
    scheduled work, voice admission, and SCVs fenced. Require `/health`,
    `/status`, PostgreSQL connectivity, and the exact revision and image
    digest.
11. Start the last-known-good Sarah release against the migrated copy with
    traffic and workers fenced. This proves that the additive schema preserves
    the application rollback boundary.
12. Retain a sanitized receipt and delete the disposable instance after the
    staging and production decisions no longer need it.

Never repair a refused lineage by editing `schema_migrations`. Restore a new
copy, diagnose the mismatch, and update the reviewed migration map through the
normal release gate.

## Prepare the production window

1. Announce a maintenance window that includes the Cloud SQL safety-control
   change, writer drain, migration, three-node replacement, and rollback.
2. Freeze merges and deployments. Verify that local `HEAD`, `origin/main`, the
   release-gate receipt, candidate manifest, staging report, and soak report all
   identify the same SHA and image digest.
3. Drain new voice calls, SCVs, computer jobs, Forge builds, Forge deployments,
   turns, and background work. Wait for active work to reach zero.
4. Remove every Sarah node from external readiness and prevent automatic
   restart with old writer configuration. Verify that no application writer can
   reach the database.
5. Create the final on-demand backup and wait for success. Record the bounded
   backup identifier and completion time.
6. Run the same lineage classification and content-free integrity checks used
   in rehearsal. Abort if the classification, map digest, or schema facts differ.

## Migrate and replace the fleet

Run one migration job. Do not let each application node race the migration.

1. Apply the reviewed lineage bridge with the final backup identifier.
2. Run `bin/migrate` under the release advisory lock.
3. Require the final lineage classification and every integrity check from the
   rehearsal receipt.
4. Start one OpenAgents node with public readiness removed and all high-risk
   admissions fenced. Require database connectivity, exact revision and image
   identity, configuration readiness, boot convergence, and no unexpected
   errors.
5. Start the second node and require a two-node BEAM cluster before starting
   the third node.
6. Start the third node and require `beam=3`, `raft=3`, quorum, exact source SHA,
   exact image digest, and three healthy load-balancer backends.
7. Admit internal smoke traffic. Test health, status, login, one typed turn,
   durable reload, memory, issues, Git clone and fetch, a read-only computer
   job, and operator recording playback.
8. Admit public traffic gradually. Watch error rate, latency, database
   connections, mailbox growth, process count, work queues, voice state, Forge
   receipts, Ra membership, and backend health.
9. Enable voice, computers, work, Forge deployment, and SCVs one at a time only
   after their production canary passes.

Do not enable the SCV production-write profile during the application cutover.
Keep SCVs in read-only or propose mode until the normal production observation
window passes.

## Abort and roll back

Abort before public traffic if migration classification, integrity, candidate
startup, revision identity, cluster membership, or backend health differs from
the rehearsal.

- Before migration, restore Sarah readiness and leave the database unchanged.
- After the additive migration, stop every OpenAgents writer and start the
  recorded Sarah image against the migrated schema. The rehearsal must prove
  this path before the window.
- If the migrated database is damaged or the Sarah compatibility check fails,
  restore the final backup into a new Cloud SQL instance and repoint only after
  verifying its identity. Do not overwrite the failed primary during incident
  response.
- Keep the old Sarah Cloud Run service and startup metadata unchanged until the
  production observation window completes.

After rollback, verify typed chat, authentication, voice admission state,
Forge ref truth, Ra membership, and database integrity. Record the first
failure and rollback result without credentials or private product content.

## Close the cutover

Run the full production smoke after the fleet has served stable traffic. Keep
the backup, prior image, prior startup metadata, and Sarah Cloud Run fallback
through the observation window. Then rotate transitional credentials, remove
the old restart path, enable deletion protection on the fleet instances, and
schedule provider-resource renames as a separate infrastructure change.

Do not declare production ready until the staging soak and the disposable-copy
migration rehearsal complete for the exact candidate. Local parity and a
healthy staging deploy are necessary but do not replace those conditions.
