# Classify and migrate a staging database

Classify the database before you start a staging candidate. The release
supports three safe paths:

- `empty` identifies a database without application tables. Run all current
  migrations.
- `current` identifies a database that already uses this repository's
  migration lineage. Run the remaining current migrations.
- `prior` identifies the one reviewed nonempty lineage from 2026-08-19. Create
  a snapshot, apply the reviewed baseline bridge, and then run the remaining
  current migrations.

The command refuses `unknown` and `prior_partial` databases. Do not insert
`schema_migrations` rows manually or edit the baseline map during a deployment.

## Understand the reviewed map

The [prior-lineage baseline map](../../priv/migration_lineages/prior-2026-08-19.json)
partitions every current migration into four disjoint groups:

- 38 versions are shared by both lineages and already appear in
  `schema_migrations`.
- 14 current versions have effects that the prior lineage already satisfies.
  These include consolidated create migrations and temporary forge repair
  migrations that would duplicate tables, convert UUIDs, truncate receipts, or
  drop build history if replayed.
- Four reconciliation migrations run normally because they are guarded or
  idempotent.
- 17 versions are genuinely new and run normally after the baseline.

The bridge adds only the nullable `users.browser_key_hash` column and its
partial unique index. It then records the 14 reviewed versions. It preserves
all prior migration rows and all application data.

Classification checks the required prior migration signature, tables,
columns, key column types, constraints, indexes, and absence of temporary forge
foreign keys and legacy tables. The map test fails if a current migration is
unclassified or appears in more than one group.

## Classify the target

Run the command from the exact candidate release with the same staging-only
database configuration that the migration job will use:

```sh
bin/migration-lineage check
```

The command prints one content-free JSON object. Save it with the candidate
evidence. Confirm its `classification`, `map_digest`, fact counts, and baseline
counts. It never returns database names, row contents, credentials, or schema
definitions.

For `empty` or `current`, do not apply a baseline. Run:

```sh
bin/migrate
bin/migration-lineage check
```

An empty database becomes `current` after migration.

## Rehearse a prior-lineage target

Never baseline the live target first. Restore its latest snapshot into the
isolated staging database instance and rehearse on that disposable copy:

1. Stop all writers to the copy.
2. Run `bin/migration-lineage check` and require `prior`.
3. Record content-free row counts and integrity queries for accounts,
   conversations, messages, forge targets, build receipts, and deploy receipts.
4. Create or confirm a snapshot of the copy and record its bounded reference.
5. Apply the baseline bridge:

   ```sh
   OPENAGENTS_STAGING_SNAPSHOT_ID=staging-copy-20260820-0001 \
     bin/migration-lineage --apply
   ```

6. Require `prior_baselined`, `changed: true`, 14 baseline entries, and zero
   missing facts in the JSON result.
7. Run `bin/migrate`. Exactly the reconciliation and genuinely new versions
   that are absent from the copy should run.
8. Run `bin/migration-lineage check` again and require `prior_baselined` with
   zero missing facts.
9. Start the candidate release with high-risk features disabled. Require
   configuration readiness, database connectivity, `/health`, and `/status`.
10. Start the last-known-good release against the migrated copy with traffic and
    workers disabled. This verifies that the additive schema remains rollback
    compatible.
11. Repeat the content-free counts and integrity queries from step 3. Investigate
    any difference before you continue.
12. Delete the disposable copy after you retain the sanitized receipt.

The apply command is idempotent only after the complete bridge succeeds. It
refuses a partial baseline so an operator cannot guess how to repair an
interrupted or manually modified lineage.

## Migrate the actual staging target

After the copy rehearsal passes:

1. Stop staging writers and verify that no old application instance can restart.
2. Create an on-demand Cloud SQL backup or snapshot of the actual staging-only
   instance. Record its identifier and completion state.
3. Repeat `bin/migration-lineage check` against the actual target. Its result
   must match the rehearsed classification and map digest.
4. Apply the baseline only if the classification is `prior`, using the actual
   snapshot identifier.
5. Run `bin/migrate` as a single bounded job. Do not let every application node
   race migration during this deployment.
6. Recheck the lineage, migration versions, integrity counts, and candidate
   startup before you admit traffic.

If any check fails, keep traffic fenced, preserve the database and logs, and
restore the reviewed snapshot into a new isolated target. Do not edit migration
history in place and do not point the candidate at a production database.

## Record evidence

Retain these content-free fields in the Gate 13 report:

- Exact Git SHA, image manifest digest, and release version.
- Baseline map digest and classification before and after migration.
- Snapshot identifier and completion receipt.
- Baseline versions recorded and current versions applied.
- Before-and-after row counts and integrity-check statuses.
- Candidate and last-known-good startup results.
- Migration duration, first failure if any, and rollback disposition.

Do not retain database URLs, passwords, account identifiers, prompts, messages,
transcripts, OAuth material, or query results containing user content.
