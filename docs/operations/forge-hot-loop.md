# Forge hot loop runbook

Date: 2026-08-21

Status: Relup and mirroring are active in production. The automated direct-load
loop still requires fleet enablement.

This is the operator procedure for the fast deployment lane: push to the owned
forge, promote, and watch a code-only change go live across the fleet in
seconds without an image build. It also describes the production relup path,
the independent GitHub mirror repair worker, and the remaining direct-load
enablement work.

## Verified state of the lanes

| Path | State | Evidence |
| --- | --- | --- |
| Direct BEAM transaction on production | Works | `fa4b792` loaded across three nodes via the transaction protocol; `live` target and deployment receipt recorded; uptimes unbroken |
| Automated push → promote → build → hot-load loop | Not yet operating | No receipted automated deploy exists, so `/api/status` reports `loop.last_ms: null` and `push_to_live_ms: null` |
| General relup lane | Active in production | `RelupPackage` binds source and target revisions, release versions, state schemas, target system, and artifact digests before `RelupDeployment` upgrades one node at a time. Production upgraded `0.2.0@81e4c25` to `0.2.1@9763bf7` in 48.838 seconds without restarting the BEAM. |
| Forge-to-GitHub mirror | Active in production | The production mirror uses a write-enabled deploy key. `MirrorWatch` runs independently of the deploy lane, repairs drift every five minutes, and reports freshness. Forge and GitHub exposed 10 identical refs after the production drill. |
| Rolling image replacement | Works, default for structural changes | Current release tooling path |

Two consequences worth stating plainly:

- Code-only changes do **not** require an image roll once the loop is enabled;
  the whole web layer is allowlisted.
- Changes to `config/config.exs` or `config/runtime.exs` remain structural.
  The classifier must refuse them for direct loading and route them to a full
  release path.

## Why the metrics read null

- `loop.last_ms` and the median come from deploy receipts whose result is
  `live` with an integer `push_to_live_ms`. The manual `fa4b792`
  application produced a receipt without timing, so the projection has no
  sample yet. The first automated loop deploy populates both.
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
   changed set, and writes the response plus a digest-addressed artifact.
4. **Verify**: `Builder` re-verifies digest and manifest, advances the target
   to `built` with module list and classification, then broadcasts
   `forge:builds`.
5. **Deploy**: `OpenAgents.Forge.HotLoader` verifies again, refuses anything
   that is not a `direct_candidate` or carries off-allowlist modules, and hands
   the artifact to `OpenAgents.Forge.Deployment` for the transactional
   prepare → canary → fleet apply → verify → commit sequence.
6. **Receipt**: a `live` deployment writes the deploy receipt including
   `push_to_live_ms`, measured from the push receipt.

## Enablement checklist

Work top to bottom; each step gates the next.

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
   `OpenAgents.Forge.Browse`, `OpenAgents.BuildInfo`, and the scratch prefix,
   with boot-time classification self-tests.
6. **Optional — turn the mirror on** by configuring a mirror URL for
   `openagents.com`. This only affects the public status projection and GitHub
   mirroring, never deploys.

## First automated drill

Run this once enablement completes; it is also the regression check after any
builder change.

1. Pick a commit that changes only allowlisted modules (a template or
   LiveView edit is ideal).
2. Push it to the forge remote:
   `git push openagents <sha>:main`. Confirm the push receipt on
   `/admin/forge`.
3. Promote the new SHA from `/admin/forge`.
4. Watch the target walk `promoted → building → built → deploying → live`.
5. Assert the deploy receipt shows `result: live`, a nonzero module count, and
   a populated `push_to_live_ms`. Then confirm `/api/status` now reports
   `forge.loop.last_ms`.
6. Restart one node and verify boot convergence restores the same revision
   before it serves.

Expect the first real build to take minutes: the loop's economics assume the
warm workspace that the first build creates. Subsequent web-layer diffs should
land in seconds. Receipts measure pipeline time from push ack to live, not
human reaction time.

## Failure modes

| Symptom | Meaning | Action |
| --- | --- | --- |
| Target stalls at `building`, fails `build_timeout` | No sidecar claimed the request | Check the builder container is running and the queue volume is shared |
| `needs_rolling_replace` with `structural_reasons` | Honest refusal: config, dependencies, assets, or release files changed | Ride the image-roll path; this is correct behavior |
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
`MirrorWatch` runs even when `OPENAGENTS_FEATURE_FORGE_DEPLOY=false`, compares
the canonical `main` ref every five minutes, retries a full mirror push on
drift, and publishes `current` or `lagging` status.

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
