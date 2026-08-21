# Release deployment fallbacks

Date: 2026-08-20

Status: Implemented. The isolated staging fleet uses the coordinated rolling
lane, and production uses the same one-node-at-a-time health boundary.

## Purpose

Use this runbook when a candidate cannot use the direct BEAM transaction. The
classifier must choose one strategy for the complete candidate:

- Use a relup only for the supported `0.1.0` to `0.2.0` application transition
  and its tested reverse transition.
- Use rolling replacement for ERTS, OTP, dependency, native-code, asset,
  configuration, migration, module-deletion, or otherwise unclassified
  changes.

The relup lane is not production-approved. Use rolling replacement in
production only with explicit operator authority, an immutable image digest,
two remaining healthy nodes, and exact revision checks after each replacement.

## Local release gate

Install the repository hook once on each owned development or release machine:

```sh
git config core.hooksPath .githooks
```

The hook refuses any push aimed somewhere other than the forge before it
considers the gate, so an installed hook enforces REPOSITORY-002 as well.

Provision a disposable PostgreSQL database with pgvector already installed,
then run the complete exact-SHA gate:

```sh
OPENAGENTS_RELEASE_SMOKE_DISPOSABLE=1 \
OPENAGENTS_RELEASE_SMOKE_DATABASE_URL='ecto://USER:PASSWORD@HOST/DATABASE' \
ops/ci/gate.sh
```

The gate requires a clean worktree. It runs warning-free test and production
compilation, `mix precommit`, distributed tests, browser tests, the direct transaction,
forward and reverse relup proofs, interrupted-install recovery, rolling
replacement tests, repository contracts, and packaged release startup. It
writes a content-free receipt to
`.git/openagents/release-gate-receipts/<full-sha>.json` only after every stage
passes without an automatic retry.

Both deployment coordinators call `OpenAgents.Forge.GateReceipt.verify/2`
before changing a node. A new commit has a new SHA and therefore invalidates
the prior receipt. The emergency override is an explicit function option with
a bounded reason; it emits a warning and exists only for operator-directed
recovery. Do not use it for an ordinary release.

## Relup lane

### Supported transition

The repository owns one explicit two-way transition:

| Direction | Application version | State schema |
| --- | --- | --- |
| Upgrade | `0.1.0` to `0.2.0` | 1 to 2 |
| Downgrade | `0.2.0` to `0.1.0` | 2 to 1 |

`OpenAgents.ReleaseState` is a supervised, long-lived process with a versioned
`OpenAgents.ReleaseState.State` struct. `code_change/3` preserves the PID and
bounded observations in both directions. `rel/openagents.appup.exs` names the
advanced update explicitly. Do not add a version transition until its forward,
reverse, and re-upgrade state paths have focused tests and a real packaged-node
proof.

Build the release pair and relup:

```sh
ops/relup-proof/run.sh
```

The script builds explicit release versions, generates both directions with
`mix openagents.relup`, embeds the generated `relup` in the candidate tar, and
caches checksummed proof artifacts under `.git/openagents/relup-proof/<sha>/`.
It never deletes a shared release directory.

Run the live state and interruption drills against a disposable database:

```sh
OPENAGENTS_RELUP_PROOF_DISPOSABLE=1 \
OPENAGENTS_RELUP_PROOF_DATABASE_URL='ecto://USER:PASSWORD@HOST/DATABASE' \
ops/relup-proof/version-chain.sh

OPENAGENTS_RELUP_PROOF_DISPOSABLE=1 \
OPENAGENTS_RELUP_PROOF_DATABASE_URL='ecto://USER:PASSWORD@HOST/DATABASE' \
ops/relup-proof/kill-during-install.sh
```

### Fleet sequence

`OpenAgents.Forge.RelupDeployment` performs this sequence:

1. Verify the complete local gate receipt for the candidate SHA.
2. Snapshot the exact sorted member set and configured fleet size.
3. Stage one node's release tar in a digest-addressed cache.
4. Verify the cached and consumable tar digests.
5. Restore the consumable tar from cache, then unpack it.
6. Generate version-specific runtime configuration and run
   `release_handler.check_install_release/1`.
7. Install the candidate without changing the permanent release.
8. Verify current release status, application readiness, and the expected
   migrated state schema.
9. Make the release permanent, verify permanence, and recheck exact fleet
   membership.
10. Start the next node only after the previous node passes every check.

If post-install health or permanence verification fails, the coordinator
installs the reverse relup, verifies the prior release and state schema, restores
the prior permanent release, and aborts before touching another node. If the
reverse path fails, keep the node out of readiness and move to operator-directed
rolling recovery.

`OpenAgents.Forge.RelupNode` retains the immutable tar in
`releases/.openagents-relup-cache/<sha256>.tar.gz`. It copies those exact bytes
back to the filename consumed by `unpack_release/1` before every attempt. This
restaging step is mandatory after an interrupted install.

## Rolling replacement lane

Build a local immutable image only after the exact release gate passes:

```sh
ops/deploy/build-image.sh openagents:<full-sha>
```

The script records the content-addressed `sha256:` image ID under
`.git/openagents/images/<full-sha>.json`. A mutable tag is a convenience label,
not deployment identity. Pass only the digest to the replacement provider.

`OpenAgents.Forge.RollingReplacement` owns the provider-neutral rollout. Gate
12 must implement `OpenAgents.Forge.RollingProvider` for the isolated staging
infrastructure. Keep machine inventory, credentials, addresses, and provider
resource names outside the repository.

The provider reports its exact connected infrastructure inventory through
`members/0`. A hidden controller must not include itself or a temporary RPC
client in that inventory. The GCP provider intersects connected Erlang nodes
with its configured three-node instance map, so every membership check uses
the same bounded fleet identity.

For each node, the coordinator performs this sequence:

1. Verify the exact-SHA release receipt and exact initial member set.
2. Remove the node from external readiness.
3. Drain until no local work singleton remains.
4. Verify that the remaining nodes meet the configured ready-capacity floor
   and retain quorum.
5. Replace the node with the target image digest.
6. Wait for exact BEAM membership, readiness, boot convergence, database
   access, source SHA, and image digest.
7. Recheck exact fleet membership before selecting another node.

An Erlang distribution transport failure is an expected transient state while
a VM reboots. The GCP provider reports that node as unavailable so the
coordinator continues its bounded readiness polling. An invalid probe response
fails immediately, and a node that remains unavailable fails at the bounded
timeout.

If a node does not rejoin, the coordinator asks the provider to restore the
last-known-good SHA and digest, waits for that node's full health, records the
recovery result, and aborts. It never replaces a second node while the first is
missing or unhealthy.

After the coordinator returns, settle its bounded result against the Forge
target:

```elixir
OpenAgents.Forge.Targets.finish_rolling_replacement(target_id, rolling_result)
```

Settlement accepts only the newest target in `needs_rolling_replace`, requires
the target's complete verified build receipt, and verifies that the result SHA
matches the target. It changes the target to `live` or `failed` and inserts a
second immutable deployment receipt in one transaction. Forge preserves the
earlier `needs_rolling_replace` classification receipt. A successful settlement
makes that build manifest the baseline for later direct-load classification.

## Database compatibility

Keep schema changes additive while old and new releases overlap. During a
relup or rolling rollout, both versions must be able to read and write the same
schema. Do not combine a reversible application transition with a destructive
column removal, type contraction, trigger removal, or irreversible data
rewrite. Ship contract migrations only in a later release after rollback to
the old application version is no longer supported and staging has proven the
new rollback boundary.

## Staging admission

Do not run either fleet lane against the current web-only staging service. Gate
12 must first provide stable node identities, private distribution, a separate
staging database instance, durable release artifacts, node-local caches,
readiness removal, drain support, and a provider implementation. Then retain
evidence for:

- one complete allowlisted push-to-build-to-canary-to-fleet-to-live direct
  transaction;
- one relup upgrade, downgrade, re-upgrade, health-triggered reverse, and
  interrupted-install retry;
- one no-op digest-addressed rolling rollout;
- one failed rejoin that restores the prior digest and stops before the next
  node;
- additive migration compatibility while both application versions run.

Production rolling replacement requires explicit operator authority. Do not
infer that authority from a successful staging rollout.
