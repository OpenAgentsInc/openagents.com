# Forge transactional deployment

Date: 2026-08-22

Status: Active in production for verified BEAM-only candidates. Use the packaged
relup or rolling-replacement lane for structural candidates.

## Purpose

The direct-load lane applies one verified BEAM artifact to an exact expected
fleet without exposing a mixed revision as `live`. It treats the database
target, every node's loaded object code, external readiness, and the immutable
terminal receipt as one coordinated deployment outcome.

Use this lane only for artifacts classified as `direct_candidate` whose every
changed module matches the operator-owned allowlist. Send structural changes to
the relup or rolling-replacement lanes.

The source classifier treats nonembedded release-private files under `priv/` as
structural. Direct loading cannot install those files even when the same commit
also changes an allowlisted module. `priv/docs/` is the deliberate exception:
`DocsCatalog` compiles every Markdown file into its allowlisted BEAM artifact.

## Preconditions

The coordinator refuses deployment unless all of these conditions hold:

- The target remains the newest promotion and has status `built`.
- Connected membership exactly matches
  `OPENAGENTS_FORGE_EXPECTED_FLEET_SIZE`.
- Every expected node reports successful boot convergence, no active or
  divergent deployment, and the same current revision.
- Every node can verify the artifact digest, canonical manifest digest,
  repository, full source SHA, build ID, runtime toolchain, classification, and
  allowlist.
- Every node can cache the digest-addressed artifact and recover the exact
  object code that the candidate would replace.

A missing, unexpected, unhealthy, or revision-divergent node blocks the
transaction before any candidate becomes live.

Claiming deployment ownership changes the newest target from `built` to
`deploying` and removes the fleet from ordinary external readiness. The
coordinator then uses a target-scoped internal health check that accepts only
nodes converged to the prior serving target for that exact deployment. This
separation prevents a late-joining node from serving old code without blocking
the prepared fleet from completing the transaction.

## Transaction protocol

The coordinator runs these phases in order:

1. Snapshot the sorted healthy member set and select the coordinator node as
   the canary when it belongs to that set.
2. Send the immutable artifact and its expected identities to every node.
3. Have each node verify the complete artifact, cache it by SHA-256, capture
   exact prior object code, and return a random 256-bit token.
4. Apply and verify the candidate on the canary.
5. Recheck exact membership.
6. Apply the candidate on every remaining prepared node.
7. Recheck exact membership, then verify loaded BEAM MD5 identities,
   application version, candidate revision, and deployment readiness on every
   node.
8. Recheck membership and commit every expiring token.
9. In one PostgreSQL transaction, advance the target to `live` and insert its
   immutable terminal receipt.
10. Finalize every token and release the nodes into external readiness.

`OpenAgents.Forge.DeploymentNode` keeps its node out of readiness from prepare
through commit. The token binds one deployment ID to its target, build, source
SHA, artifact, manifest, expected member set, candidate binaries, and prior
object code. Another attempt cannot reuse it.

The participant bounds itself to four concurrent prepared transactions. It
automatically resolves expired transactions against their phase and durable
authority. Configure enough token lifetime for all phases and rollback; runtime
validation requires at least eight phase timeouts. It persists the bounded
transaction fence in node-local VM state, so a supervised participant restart
preserves the exact rollback data and keeps the node out of readiness. A VM
restart returns to image code and runs boot convergence before the endpoint
starts.

When a committed token expires, the participant asks PostgreSQL for the exact
target, deployment, and artifact authority. It finalizes the candidate only
after the durable `live` transaction exists. It extends the readiness fence
while that database transaction remains `deploying`, and it restores the prior
code after a durable terminal refusal. If PostgreSQL is unavailable, the node
stays out of readiness and retries the authority check.

## Failure and rollback behavior

Any prepare, apply, verification, commit, membership, or RPC failure triggers
rollback on every node that returned a token. Each participant:

1. Reloads the exact captured binary for a preexisting module or removes a
   module that was absent before the transaction.
2. Verifies the restored module's embedded BEAM MD5 against the captured
   object.
3. Returns `restored` only after every affected module passes verification.

The coordinator records `reverted` only when at least one node applied the
candidate and every prepared node verified restoration. It records `failed`
for an unverified rollback, timeout, or unreachable participant. A participant
whose restoration fails keeps `ready=false` with reason
`rollback_unverified`; traffic must not return until boot convergence or
rolling replacement repairs it.

If the PostgreSQL target-and-receipt transaction fails after node commit, the
coordinator rolls back the still-fenced tokens before it records the terminal
outcome. It never advances the target to `live` based only on a canary result.

## Immutable receipts

Each `forge_deploys` row records bounded operational evidence:

- deployment, target, build, repository, and full source identities;
- artifact and canonical manifest SHA-256 digests;
- the expected nodes and bounded per-node terminal outcomes;
- canary result, changed module names for the operator surface, and
  push-to-live duration;
- failure code and whether rollback verification succeeded;
- transaction start and completion timestamps.

PostgreSQL rejects every `UPDATE` and `DELETE` on this table. Public status
projects only anonymous node positions, a short SHA, state, module count, and
timing. It does not expose node names, module names, tokens, or free-form
failure data.

## Boot convergence and readiness

Application supervision starts the deployment participant and synchronous
boot convergence after PostgreSQL and before cluster discovery, PubSub, the
runtime supervisor, or the endpoint.

On a cold or replaced node, boot convergence:

1. Reads the newest immutable `live` target.
2. Verifies a local digest-addressed artifact or fetches it from the durable
   WAL artifact store.
3. Applies it through the same participant verifier and exact rollback logic.
4. Verifies and retains the current artifact and immediate live predecessor in
   the local cache.
5. Prunes older digest-addressed cache entries without touching durable
   artifacts or receipts.
6. Publishes a bounded convergence state and enters readiness.

If image code does not match the live target and convergence fails, `/health`
returns `503` and `/status` reports a content-free degraded state. The worker
retries indefinitely with exponential backoff capped by
`OPENAGENTS_FORGE_BOOT_RETRY_MAX_MS`. A missing live target is the only normal
image-only ready state. A live target without immutable artifact identity is a
readiness failure unless the image revision exactly matches that target. After
convergence, the worker periodically rechecks the durable target. Readiness
also rejects an active `deploying` target and performs this identity check, so
a late-joining node cannot continue to serve an older target during the next
convergence interval.

## Runtime settings

| Setting | Purpose |
| --- | --- |
| `OPENAGENTS_FORGE_EXPECTED_FLEET_SIZE` | Exact member count required throughout a transaction |
| `OPENAGENTS_FORGE_DEPLOY_TIMEOUT_MS` | Per-node RPC phase timeout |
| `OPENAGENTS_FORGE_DEPLOY_TOKEN_TTL_MS` | Token lifetime; must cover at least eight phase timeouts |
| `OPENAGENTS_FORGE_BOOT_RETRY_MIN_MS` | Initial convergence retry interval |
| `OPENAGENTS_FORGE_BOOT_RETRY_MAX_MS` | Maximum convergence retry interval |

Production enables `OPENAGENTS_FEATURE_FORGE_DEPLOY` and
`OPENAGENTS_FEATURE_BOOT_CONVERGENCE` after pinning the serving and builder
images. Staging must also configure its isolated rolling provider before it
enables the complete automated fallback lane. `/status` reports the active
state, current stage, timing receipts, boot convergence, and mirror freshness.

## Verification

Run the direct participant, coordinator, boot, and receipt proofs:

```sh
mix test test/openagents/forge/deployment_node_test.exs
mix test test/openagents/forge/hot_loader_test.exs
mix test test/openagents/forge/boot_converge_test.exs
mix test test/openagents/forge/target_lifecycle_test.exs
mix test test/openagents/forge/deployment_cluster_test.exs --only cluster
mix precommit
```

The cluster test starts two real peer nodes beside the test coordinator. It
proves a three-node commit, a remote apply failure with exact fleet rollback, a
unverified rollback that removes the affected node from readiness, a remote
timeout that cannot claim rollback, and membership loss before commit. The boot
suite proves cold-cache durable fetch, current-and-predecessor retention,
old-cache pruning, live-target freshness, and refusal to serve missing,
unidentified, or off-allowlist live code.
