# Release deployment fallbacks

Date: 2026-08-20

Status: Implemented. Production uses the Forge direct-load loop first, a relup
for compatible full releases, and an operator-directed rolling replacement for
remaining structural changes.

## Purpose

Use this runbook only after the Forge classifier refuses a direct BEAM
transaction. The classifier must choose one strategy for the complete
candidate:

- Use a relup for a packaged `X.Y.Z` transition when the generated appup,
  target system, exact revisions, artifact digests, state schemas, and reverse
  path pass validation.
- Use rolling replacement for ERTS, OTP, dependency, native-code, asset,
  configuration, migration, module-deletion, or otherwise unclassified
  changes.

`OpenAgents.Forge.DeploymentLane.classify/2` makes that choice, and it reads
the fleet's relup topology verdict before choosing rather than discovering it
one node at a time. A fleet that cannot support relup is classified onto
rolling replacement with the verdict as its reason, so this runbook's relup
lane is reached only by a fleet that could survive it. `INVARIANTS.md`,
RELEASE-009 states the classification; RELEASE-008 states the preinstall
refusal that remains underneath it.

Production relups and rolling replacements require explicit operator authority.
For a rolling replacement, also require an immutable image digest, two
remaining healthy nodes, and exact revision checks after each replacement.

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

### Supported transitions

`RelupDeployment` accepts any distinct semantic `X.Y.Z` pair when the state
schema remains in the supported range and does not regress. The generated
appup remains the authoritative compatibility check. If it cannot describe
the complete module change, package generation or
`release_handler.check_install_release/1` refuses the transition.

| Direction | Application version | State schema |
| --- | --- | --- |
| Upgrade | `X.Y.Z` to a distinct semantic version | 1 or 2 to the same or a higher supported schema |
| Downgrade | The embedded reverse transition | The target schema back to the packaged source schema |

Use patch versions for routine releases. Reserve a minor-version change for a
deliberate compatibility or feature boundary. Never publish different bytes
under an existing version.

`OpenAgents.ReleaseState` is a supervised, long-lived process with a versioned
`OpenAgents.ReleaseState.State` struct. `code_change/3` preserves the PID and
bounded observations in both directions. `rel/openagents.appup.exs` names the
advanced update explicitly. Do not add a version transition until its forward,
reverse, and re-upgrade state paths have focused tests and a real packaged-node
proof.

Build a digest-addressed release pair and relup:

```sh
ops/forge/package-relup.sh \
  --from-version 0.2.0 \
  --to-version 0.2.1 \
  --from-rev SOURCE_SHA \
  --to-rev TARGET_SHA \
  --out-dir /path/to/package
```

The script builds each exact revision in an isolated worktree, generates both
directions with `mix openagents.relup`, embeds the generated `relup` in the
candidate tar, and writes a `package.json` manifest with source and target
revisions, versions, state schemas, target system, and SHA-256 digests. It
never deletes a shared release directory.

`OpenAgents.Forge.RelupPackage.deploy/2` validates that manifest against the
running revision and system architecture before it reads the bounded target
artifact and calls `RelupDeployment`. A stale package cannot upgrade a fleet
that another deployment has already replaced.

Run the live state and interruption drills against a disposable database:

```sh
OPENAGENTS_RELUP_PROOF_DISPOSABLE=1 \
OPENAGENTS_RELUP_PROOF_DATABASE_URL='ecto://USER:PASSWORD@HOST/DATABASE' \
ops/relup-proof/version-chain.sh

OPENAGENTS_RELUP_PROOF_DISPOSABLE=1 \
OPENAGENTS_RELUP_PROOF_DATABASE_URL='ecto://USER:PASSWORD@HOST/DATABASE' \
ops/relup-proof/kill-during-install.sh
```

### Topology preflight

OTP release handling assumes every running application's top process is an OTP
`supervisor`. `release_handler_1:get_master_procs/3` asks
`:supervisor.get_callback_module/1` for it, and that function reads the process
state as a `supervisor` record, so it raises `badrecord` for an Elixir
`DynamicSupervisor`, a Horde supervisor, or a bare `GenServer` returned from
`Application.start/2`. `release_handler` then logs `cannot find top supervisor
for application NAME` and drops that supervisor from the set it suspends and
code-changes. `check_install_release/1` never looks, so nothing refuses before
the install begins.

`libring` is the concrete case, and it is why the `0.2.1` to `0.2.2` production
upgrade on 2026-08-22 failed. `HashRing.App.start/2` returns a
`DynamicSupervisor` pid registered as `HashRing.Supervisor`.

`OpenAgents.Forge.RelupTopology` runs this check on the target node as the
first fleet step, before any artifact is transferred. Read the current verdict
from a running node:

```elixir
OpenAgents.Forge.RelupTopology.report()
#=> %{"schema" => "openagents.relup-topology.v1", "applications" => 62,
#=>   "incompatible" => ["libring:HashRing.Supervisor"]}
```

A refusal is not a fault to work around. It means OTP release handling cannot
express this fleet's topology, so the relup lane is unavailable and the
candidate belongs on the rolling replacement lane below. The refused node keeps
its previous permanent release, nothing was staged or unpacked, and there is no
reverse installation to attempt.

Reaching this refusal means the classifier was bypassed.
`OpenAgents.Forge.DeploymentLane.fleet_topology/1` asks every member the same
question first, so a candidate on an incompatible fleet is routed to rolling
replacement before a lane is chosen. The refusal stays as the backstop for a
fleet whose topology changed between classification and installation.

To make the relup lane available again, the offending application has to start
an OTP `supervisor` as its top process. Do not weaken the preflight instead.

### Fleet sequence

`OpenAgents.Forge.RelupDeployment` performs this sequence:

1. Validate the package source revision, target system, and target artifact
   digest.
2. Verify the complete local gate receipt for the candidate SHA.
3. Snapshot the exact sorted member set and configured fleet size.
4. Refuse when the node's running application topology has a top supervisor OTP
   cannot identify.
5. Stage one node's release tar in a digest-addressed cache.
6. Verify the cached and consumable tar digests.
7. Restore the consumable tar from cache, then unpack it.
8. Generate version-specific runtime configuration and run
   `release_handler.check_install_release/1`.
9. Install the candidate without changing the permanent release.
10. Verify current release status, exact target revision, application readiness,
   and the expected migrated state schema.
11. Make the release permanent, verify permanence, and recheck exact fleet
   membership.
12. Start the next node only after the previous node passes every check.

Steps 4 through 8 run before `install_release/1`. A failure in any of them
leaves the node on its previous permanent release, so the coordinator aborts
without a reverse installation and records the refusing step and its reason,
for example `check_topology:incompatible_topology:libring:HashRing.Supervisor`.

The 2026-08-21 production drill upgraded three nodes from
`0.2.0@81e4c25` to `0.2.1@9763bf7` in 48.838 seconds. All nodes returned
`permanent`, retained `0.2.0` as the reverse release, and preserved their
uptimes.

If post-install health or permanence verification fails, the coordinator
installs the reverse relup, verifies the prior release and state schema, restores
the prior permanent release, and aborts before touching another node. If the
reverse path fails, keep the node out of readiness and move to operator-directed
rolling recovery.

After the coordinator returns, settle its bounded result against the retained
Forge target:

```elixir
OpenAgents.Forge.Targets.finish_relup_deployment(target_id, relup_result)
```

Settlement accepts only the newest target in `needs_rolling_replace`, requires
the target's complete verified build receipt, and verifies the target SHA,
source SHA, package manifest digest, target artifact digest, release versions,
duration, and per-node permanence. It changes the target to `live` or `failed`
and inserts a second immutable deployment receipt in one transaction. A
successful settlement makes that build the baseline for later direct-load
classification.

`OpenAgents.Forge.RelupNode` retains the immutable tar in
`releases/.openagents-relup-cache/<sha256>.tar.gz`. It copies those exact bytes
back to the filename consumed by `unpack_release/1` before every attempt. This
restaging step is mandatory after an interrupted install.

The node also records which artifact each unpacked version came from, in
`releases/.openagents-relup-cache/unpacked-<version>`. Reusing an already
unpacked version requires the recorded digest to match the request, so
re-cutting a version number from a different revision fails with
`unpacked_version_conflict` instead of installing the bytes the node unpacked
the first time. Recover by cutting a new version number for the new revision.

## Rolling replacement lane

Build a local immutable image only after the exact release gate passes:

```sh
ops/deploy/build-image.sh openagents:<full-sha>
```

The script records the content-addressed `sha256:` image ID under
`.git/openagents/images/<full-sha>.json`. A mutable tag is a convenience label,
not deployment identity. Pass only the digest to the replacement provider.

`OpenAgents.Forge.RollingReplacement` owns the provider-neutral rollout.
Staging uses the GCP provider for automated replacement. Production permits no
implicit provider: an operator must execute and verify the immutable image
rollout, then settle the retained Forge target. Keep machine inventory,
credentials, addresses, and provider resource names outside the repository.

The provider reports its exact connected infrastructure inventory through
`members/0`. A hidden controller must not include itself or a temporary RPC
client in that inventory. The GCP provider intersects connected Erlang nodes
with its configured three-node instance map, so every membership check uses
the same bounded fleet identity.

Before it touches the fleet, the coordinator publishes the authorized rolling
identity — the exact source SHA, image digest, previous pair, and expected node
set — onto the Forge target named by the request. Boot convergence admits a
node whose booted image is exactly that identity, so a replacement node enters
readiness on its first attempt and the roll needs no
`OPENAGENTS_FEATURE_BOOT_CONVERGENCE` change and no manual restart of
`OpenAgents.Forge.BootConverge`. A node carrying any other image is authorized
by nothing durable and stays out of the load balancer.

For each node, the coordinator performs this sequence:

1. Verify the exact-SHA release receipt and exact initial member set.
2. Remove the node from external readiness.
3. Drain until no local work singleton remains.
4. Verify that the remaining nodes meet the configured ready-capacity floor
   and retain quorum.
5. Replace the node with the target image digest.
6. Wait for exact BEAM membership, readiness, boot convergence, database
   access, source SHA, and image digest.
7. Record that node's exact observed SHA and image digest against the
   published authority.
8. Recheck exact fleet membership before selecting another node.

An Erlang distribution transport failure is an expected transient state while
a VM reboots. The GCP provider reports that node as unavailable so the
coordinator continues its bounded readiness polling. An invalid probe response
fails immediately, and a node that remains unavailable fails at the bounded
timeout.

If a node does not rejoin, the coordinator asks the provider to restore the
last-known-good SHA and digest, waits for that node's full health, records the
previous identity as that node's observation, and aborts. It never replaces a
second node while the first is missing or unhealthy. The target stays
`needs_rolling_replace` with a per-node record of exactly which image each node
came back on, so an interrupted roll is both auditable and resumable:
republishing the same identity keeps every observation and rerunning `run/2`
finishes the roll.

After the rolling coordinator returns, settle its bounded result against the
Forge target:

```elixir
OpenAgents.Forge.Targets.finish_rolling_replacement(target_id, rolling_result)
```

Settlement accepts only the newest target in `needs_rolling_replace`, requires
the target's complete verified build receipt, and verifies that the result SHA
matches the target. It is also bound to the published authority: the result
must carry the authorized image identity and the exact expected node set, and a
`live` settlement additionally requires an exact-identity observation from every
expected node. A roll that left any node on another identity refuses with
`rolling_nodes_not_converged`. It changes the target to `live` or `failed` and
inserts a second immutable deployment receipt in one transaction. Forge preserves the
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
