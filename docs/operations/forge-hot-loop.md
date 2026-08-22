# Forge hot loop runbook

Date: 2026-08-22

Status: Active in production. The Forge loop is the default deployment path
for allowlisted code changes. Relup and rolling replacement remain fallbacks.

This is the operator procedure for the fast deployment lane: push to the owned
forge, promote, and watch a compatible change go live across the fleet in
seconds without an image build. It also describes the production relup path,
the independent GitHub mirror repair worker, and the production activation
evidence.

## Verified state of the lanes

| Path | State | Evidence |
| --- | --- | --- |
| Direct BEAM transaction on production | Works | `fa4b792` loaded across three nodes via the transaction protocol; `live` target and deployment receipt recorded; uptimes unbroken |
| Automated push → promote → build → hot-load loop | Active | The web role runs `Builder`, `HotLoader`, and `Janitor`; every fleet node runs the pinned builder sidecar; `/status` reports the lane as **Active** and exposes target, build, deploy, and timing receipts |
| General relup lane | Active in production | `RelupPackage` binds source and target revisions, release versions, state schemas, target system, and artifact digests before `RelupDeployment` upgrades one node at a time. Production upgraded `0.2.0@81e4c25` to `0.2.1@9763bf7` in 48.838 seconds without restarting the BEAM. |
| Forge-to-GitHub mirror | Active in production | The production mirror uses a write-enabled deploy key. `MirrorWatch` checks immediately at process startup, repairs drift every five minutes, and reports freshness. Forge and GitHub exposed 10 identical refs after the production drill. |
| Rolling image replacement | Available for structural changes | Production requires an operator-directed rollout when the classifier returns `needs_rolling_replace`; staging can use the configured GCP provider |

Two consequences worth stating plainly:

- BEAM-only changes do **not** require an image roll once the loop is enabled;
  the whole web layer is allowlisted.
- Changes to `config/config.exs` or `config/runtime.exs` remain structural.
  The classifier must refuse them for direct loading and route them to a full
  release path.
- Changes under `priv/` remain structural because a BEAM transaction cannot
  install runtime programs, migrations, or other release-private files. The
  classifier preserves the more specific `assets_changed` and
  `migration_changed` reasons for `priv/static/` and `priv/repo/migrations/`.
  `priv/docs/` is the deliberate exception: `DocsCatalog` embeds every page as
  an external compiler resource, so its allowlisted BEAM carries the complete
  immutable documentation snapshot.

## Status reporting

- `/status` shows whether the Forge lane is **Active** or **Off**, the current
  target and stage, the latest build and deployment receipt, the most recent
  and median push-to-live times, boot convergence, and mirror freshness.
- `loop.last_ms` and the median come from automated `live` receipts with an
  integer `push_to_live_ms`. They remain empty until the first automated
  direct-load deployment completes.
- Mirror state `off` means no repository has a configured mirror URL
  (`OPENAGENTS_FORGE_MIRROR_URLS_JSON` defaults to an empty map). Mirroring
  feeds GitHub; it plays no part in the deploy loop.

## The chain, as wired

Every link below exists in code and runs in this order:

1. **Push**: `git push` to the forge git service lands the packfile in the WAL
   and writes a push receipt (`OpenAgents.Forge.Pushes`).
2. **Promote** (operator): the Promote control on `/admin/forge`, or
   `OpenAgents.Forge.Targets.promote/3`, broadcasts on `forge:target`.
3. **Build**: `OpenAgents.Forge.Builder` advances the target to `building`,
   writes a request to the build queue, and waits. The builder sidecar claims
   it, fetches the commit into its warm workspace, compiles incrementally,
   hashes every BEAM, diffs against the baseline manifest, classifies the
   changed set, and writes the response plus a digest-addressed artifact. The
   sidecar uses a fresh source checkout for isolation and a persistent `_build`
   and dependency cache for speed. A new pinned builder image seeds that cache.
   The checkout reuses one repository-scoped absolute path across serial build
   attempts. Mix records source paths in compiler manifests and BEAM line
   tables, so a build-ID-specific path would make unchanged modules appear
   different and force unnecessary rolling replacements.
4. **Verify**: `Builder` re-verifies digest and manifest, advances the target
   to `built` with module list and classification, then broadcasts
   `forge:builds`.
5. **Deploy**: `OpenAgents.Forge.HotLoader` verifies again, refuses anything
   that is not a `direct_candidate` or carries off-allowlist modules, and hands
   the artifact to `OpenAgents.Forge.Deployment` for the transactional
   prepare → canary → fleet apply → verify → commit sequence.
6. **Receipt**: a `live` deployment writes the deploy receipt including
   `push_to_live_ms`, measured from the push receipt. Receipt lookup resolves
   the configured repository name to its canonical storage key because Git
   writes use the opaque storage key while targets use the public name.

## Activation state

The production fleet uses this configuration:

1. **Publish the builder image.** Build the `forge-builder` Docker target from
   the same revision as the serving image and push it to Artifact Registry
   (`ops/staging/publish-candidate.sh` already handles `openagents-builder`
   tags).
2. **Pin the sidecar into fleet metadata.** Set `openagents-builder-image`
   (digest-addressed) and `openagents-builder-digest` on each fleet instance.
   The startup script validates both against the registry path and launches
   the `openagents-builder` container with the shared workspace and artifacts
   volumes plus its own credential env file. An empty value means no builder
   runs, and every promotion then times out at `build_timeout`.
3. **Confirm executor settings on the web role.**
   `OPENAGENTS_FORGE_BUILD_EXECUTOR=sidecar`, with `forge_build_queue_dir`,
   `forge_build_dir`, and `forge_artifact_dir` on durable state disks. Runtime
   configuration validates these when the deploy lane is enabled.
4. **Enable the deploy lane flag** (`OPENAGENTS_FEATURE_FORGE_DEPLOY=true`).
   This starts `Builder`, `HotLoader`, and `Janitor` under
   `OpenAgents.Forge.Supervisor`. `MirrorWatch` runs under the same supervisor
   regardless of this flag. Boot convergence is already proven on this fleet.
5. **Allowlist**: no change needed. Baked configuration already admits the
   whole `OpenAgentsWeb.` layer plus `OpenAgents.Changelog`,
   `OpenAgents.Forge.Browse`, `OpenAgents.Forge.MirrorWatch`,
   `OpenAgents.BuildInfo`, and the scratch prefix, with boot-time
   classification self-tests.
6. **Optional: Turn the mirror on** by configuring a mirror URL for
   `openagents.com`. This only affects the public status projection and GitHub
   mirroring, never deploys.

## Deploy through the Forge loop

Use this procedure for every routine deployment. Do not start with an image
roll.

1. Push the exact commit to the forge remote:
   `git push openagents <sha>:main`. Confirm the push receipt on
   `/admin/forge`.
2. Promote the new SHA from `/admin/forge`.
3. Watch the target walk `promoted → building → built → deploying → live` on
   `/status` or `/admin/forge`.
4. Assert the deploy receipt shows `result: live`, a nonzero module count, and
   a populated `push_to_live_ms`. Then confirm `/api/status` now reports
   `forge.loop.last_ms`.
5. Restart one node after changing the builder or boot-convergence machinery,
   and verify boot convergence restores the same revision
   before it serves.

The first build after replacing the builder image can take minutes while it
seeds the persistent cache. Subsequent web-layer diffs should land in seconds.
Receipts measure pipeline time from push acknowledgment to live, not operator
reaction time.

Keep the application version unchanged for direct BEAM transactions. Use the
next patch version only when a compatible full-release package needs a new
version. Reserve a minor-version change for a deliberate compatibility or
feature boundary.

If classification returns `needs_rolling_replace`, keep that receipt and use
this fallback order:

1. Package and deploy a relup when the complete release pair passes appup,
   digest, state-schema, and reverse-path validation.
2. Use an operator-directed immutable image rollout for configuration,
   dependencies, ERTS, native code, migrations, assets, or another structural
   change that cannot use a relup.
3. Settle the original target with the fallback result so its verified build
   becomes the baseline for later direct-load classification.

## Failure modes

| Symptom | Meaning | Action |
| --- | --- | --- |
| Target stalls at `building`, fails `build_timeout` | No sidecar claimed the request | Check the builder container is running and the queue volume is shared |
| `needs_rolling_replace` with `structural_reasons` | Honest refusal: config, dependencies, assets, or release files changed | Try the packaged relup path; use an operator-directed image rollout when the release is incompatible |
| `needs_rolling_replace` with `release_priv_changed` | Nonembedded runtime content under `priv/` changed | Use a packaged release so every node receives the new private files; do not settle the target from a BEAM-only load |
| `needs_rolling_replace` with `off_allowlist:` reasons | The diff touched modules outside the allowlist | Widen deliberately in config, or route around the change |
| Artifact verification failure | Digest or manifest mismatch between builder and coordinator | Treat as a builder defect; inspect the retained build output |
| A node restarts mid-fleet-deploy | Membership recheck pauses phases | Boot convergence holds the node out until it converges |

A `reverted` outcome still warrants checking fleet convergence even though
this design captures each node's prior object code for exact rollback.

## Use the production relup lane

The mechanism handles arbitrary version pairs:

1. **Coordinator admission is general.** `RelupDeployment` admits any distinct
   `X.Y.Z` pair whose state versions stay within `[1, 2]` and never regress —
   matching what `RelupNode` already enforced per node. The packaged appup on
   the target nodes remains the real gate: `check_install_release` refuses
   honestly when no relup can be produced between two versions.
2. **Appup generation describes the pair it was built from.**
   `rel/openagents.appup.exs` asks `OpenAgents.Release.Appup` to diff the two
   builds' compiled modules and emits one instruction per module that differs,
   plus the advanced `ReleaseState` update carrying each direction's target
   state schema. `mix openagents.relup` then checks the generated relup against
   the same diff, so packaging fails rather than shipping a relup that would
   install part of a revision.
3. **Packaging and install proofs produce deployable artifacts.**
   `ops/forge/package-relup.sh --from-version A --to-version B [--from-rev]
   [--to-rev]` builds both releases in isolated worktrees, generates the
   two-way relup, embeds it, and emits digest-addressed tarballs plus a
   `package.json` ready for deployment requests.
   `ops/relup-proof/install-proof.sh` then proves that package against a live
   single-node release: forward install, permanent commit, reverse rollback,
   and re-upgrade, asserting each `release_handler` result, both state
   schemas, node readiness, and `ReleaseState` retention. It reads the versions
   and schemas from `package.json`, and it creates and drops a database, so it
   refuses to run unless `OPENAGENTS_RELUP_PROOF_DISPOSABLE=1`, the URL host is
   loopback, and the database name contains `proof`, `smoke`, or `test`.

`OpenAgents.Forge.RelupPackage` closes the package-to-deployment boundary. It
rejects a package unless its source revision matches the running revision, its
target system matches the node, and its target tar matches the manifest
digest. It then constructs the bounded fleet request and calls
`RelupDeployment.run/2`. The coordinator verifies the target gate receipt,
rechecks exact membership between nodes, verifies the installed target
revision, and keeps the reverse release when it makes the target permanent.

Use patch versions for routine releases, such as `0.2.0` to `0.2.1`. Change
the minor version only when the release introduces a deliberate compatibility
or feature boundary. Never reuse a release version for different bytes;
`RelupNode` records the artifact digest for every unpacked version and rejects
a conflicting reuse.

The production drill on 2026-08-21 upgraded three nodes from
`0.2.0@81e4c25` to `0.2.1@9763bf7` in 48.838 seconds. Every node returned
`permanent`, retained `0.2.0` as `old`, reported the exact target revision,
and preserved its uptime. The operator used the documented emergency gate
override because the release was an explicitly authorized recovery and
enablement operation. Use a normal exact-SHA gate receipt for routine relups.

Note on scope: hot-load diffs and relups remain different artifact classes.
A BEAM-diff artifact cannot drive `release_handler`; only a full release
package can. That is why the build lane's classification stays two-class and
the relup lane consumes its own packages.

## Operate the GitHub mirror

Set `OPENAGENTS_FORGE_MIRROR_URLS_JSON` to a repository-to-URL JSON object.
Use a credential-free SSH URL such as
`ssh://github.com/OpenAgentsInc/openagents.com.git`; provide authentication
through a node-side SSH key and `GIT_SSH_COMMAND`. Never put a credential in
the URL or instance metadata.

`Pushes.mirror_storage_key/1` resolves the logical repository name to its
canonical storage UUID before reading refs. This distinction matters for
migrated repositories whose display name and storage key differ.
`MirrorWatch` runs even when `OPENAGENTS_FEATURE_FORGE_DEPLOY=false`. It checks
the canonical `main` ref immediately when the process starts and every five
minutes afterward, retries a full mirror push on drift, and publishes
`current` or `lagging` status.

## Production activation evidence

The 2026-08-22 activation established this baseline:

- The exact-SHA release gate passed all 13 stages in 163 seconds, including
  2,040 tests, direct transaction, relup, rolling replacement, infrastructure
  contracts, and disposable PostgreSQL release smoke tests.
- All three production nodes first ran structural baseline revision `3479f12` from
  immutable application digest
  `sha256:f85db0085f33d8ad9f0b5823ec8276d5d4ee6b9b09765d98f5480a7be9009459`
  with builder digest
  `sha256:a259afaa7899e535e08edf78782be15871939beea67730553572189928c87642`.
- The fleet then moved to compiler-workspace baseline `2ab95a2`, application
  digest
  `sha256:2f992f90222068dbe4d3d31db20b0c28e2cd786be18047ff36342f3dbd8309f5`,
  and builder digest
  `sha256:fadd181dd0cde5efaa848090b7513dc9e08110ae7a1bafb132b1bae1109376de`.
  The exact-SHA gate passed 2,042 tests. The operator rebuilt the same SHA
  once with the new builder and settled that no-byte-change target against
  the already-running image. This records a manifest whose compiler source
  paths use the stable repository workspace before measuring direct loads.
- The final structural baseline is `4b08e65`, application digest
  `sha256:3e0ca5b88f9d2d8c198e38028f0a76323ddb6eae24890da84283f9b59212a0b4`,
  and builder digest
  `sha256:04a44da1679c3d693143130c5da38dbc788ce3c1046f72f59161565f4303a628`.
  Its exact-SHA release gate passed all 13 stages and 2,043 tests. All three
  nodes reported boot convergence ready, complete cluster membership, and
  that exact structural image before the direct-load proof.
- Revision `b3ae6c6` then changed the status LiveView and reached all three
  nodes through the automated direct-load path. The deployment loaded two
  BEAM modules without an image roll and recorded `push_to_live_ms: 84299`.
  `/status` exposes that measured duration and the default fallback order as
  `direct,relup,rolling`.
- After the direct load, the operator restarted one production node. Boot
  convergence restored the two-module artifact from its local durable cache
  on the first attempt, held the node until it was ready, and rejoined both
  peers. This proves that a node restart does not discard the hot revision.
- Forge and GitHub exposed `b3ae6c6` as `main`, and the public status endpoint
  reported the mirror `current`. Every node also reported the same hot
  artifact digest and target SHA.
- Forge classified the activation change as `needs_rolling_replace`, and the
  operator settled it as `live` only after every node reported revision
  `3479f12`, complete cluster membership, and local health. Later compatible
  changes use that manifest for direct classification.
- Restarting a node reported boot convergence `ready: true`, reason
  `image_matches_live`, and the exact baseline SHA before admission.
- `/api/status` reported the Forge lane as `active`. A push sent only to Forge
  reached GitHub through the configured mirror, and `MirrorWatch` reported
  `current` immediately after each restarted node joined the fleet.
- Production's small boot partitions required removing obsolete build
  containers before pruning immutable images. The startup metadata and the
  repository-owned fleet template now remove those retired containers and
  replace the disposable builder sidecar before pulling a new builder image.

The activation did not change the application version from `0.2.0`. Keep that
version for direct loads. For full compatible packages, increment only the
patch component. Change the minor component only for a planned compatibility
boundary, and never increment a release version merely to record a source
commit.

After a rollout or storage repair, force convergence before validating the
mirror:

```elixir
storage_key = OpenAgents.Forge.Pushes.mirror_storage_key("openagents.com")
:ok = OpenAgents.Forge.Sync.ensure_cluster_fresh(storage_key)
:ok = OpenAgents.Forge.Pushes.mirror_now("openagents.com")
```

Compare complete, sorted `git ls-remote` output from Forge and GitHub. Do not
accept a matching `main` branch as proof if another branch or tag differs.

## References

- [Hot deploy gap audit](../2026-08-21-hot-deploy-gap-audit.md)
- [Forge build lane](forge-build-lane.md)
- [Transactional deployment](forge-transactional-deployment.md)
- [Release deployment fallbacks](release-deployment-fallbacks.md)
