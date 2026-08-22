# Forge hot loop runbook

Date: 2026-08-21

Status: Enablement runbook for the automated direct-load deploy loop

This is the operator procedure for the fast deployment lane: push to the owned
forge, promote, and watch a code-only change go live across the fleet in
seconds without an image build. It also records why the loop reads as
disconnected today (`forge.loop.last_ms: null`, mirror `off`) and exactly what
flips it on.

## Verified state of the lanes

| Path | State | Evidence |
| --- | --- | --- |
| Direct BEAM transaction on production | Works | `fa4b792` loaded across three nodes via the transaction protocol; `live` target and deployment receipt recorded; uptimes unbroken |
| Automated push → promote → build → hot-load loop | Not yet operating | No receipted automated deploy exists, so `/api/status` reports `loop.last_ms: null` and `push_to_live_ms: null` |
| General relup lane | Manual tools only | `RelupDeployment` admits any distinct `X.Y.Z` pair, but the classifier emits only `direct_candidate` or `needs_rolling_replace`, `RelupDeployment.run/2` has no caller outside tests, and the release gate runs neither packaging script. Relups are not production-approved (`release-deployment-fallbacks.md`) |
| Rolling image replacement | Works, default for structural changes | Current release tooling path |

Two consequences worth stating plainly:

- Code-only changes do **not** require an image roll once the loop is enabled;
  the whole web layer is allowlisted.
- The current `main` (PostHog analytics, `73ff250`) touches
  `config/config.exs` and `config/runtime.exs`, which the classifier must
  refuse as structural. That change rides rolling replacement correctly.

## Why the metrics read null

- `loop.last_ms` and the median come from deploy receipts whose result is
  `live` with an integer `push_to_live_ms`. The manual `fa4b792`
  application produced a receipt without timing, so the projection has no
  sample yet. The first automated loop deploy populates both.
- Mirror state `off` means no repository has a configured mirror URL
  (`OPENAGENTS_FORGE_MIRROR_URLS` defaults to empty). Mirroring feeds GitHub;
  it plays no part in the deploy loop.

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
   This starts `Builder`, `HotLoader`, `Janitor`, and `MirrorWatch` under
   `OpenAgents.Forge.Supervisor`. Boot convergence is already proven on this
   fleet.
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

## The relup lane generalized, but nothing drives it

As of 2026-08-21 (later), the mechanism handles arbitrary version pairs:

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
3. **Packaging and install proofs exist as tools.**
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

What is not true yet, and is engineering work rather than operator work:

- **No code calls the lane.** `RelupDeployment.run/2` has no caller outside
  tests. Nothing classifies a candidate as a relup, builds the request, or
  triggers a fleet relup; an operator drives the two scripts by hand.
- **The release gate does not run either script.** `ops/ci/gate.sh` runs
  `ops/relup-proof/run.sh`, `version-chain.sh`, and `kill-during-install.sh`,
  which exercise the pinned `0.1.0 → 0.2.0` pair only. Neither
  `package-relup.sh` nor `install-proof.sh` is a gate stage, so no receipt
  binds a general pair to a candidate SHA.
- **Nothing binds a package to its gate receipt.** `package.json` records the
  revisions it was built from, but `RelupDeployment` verifies the receipt for
  `request.sha` without checking that the artifact came from that revision.

Operator work still required before the lane carries production traffic:

- Production approval recorded against
  [`docs/operations/release-deployment-fallbacks.md`](release-deployment-fallbacks.md),
  which remains the authority that relups are not production-approved.
- A staging rehearsal of `package-relup.sh` followed by `install-proof.sh`
  against a disposable database, before any fleet use.

Note on scope: hot-load diffs and relups remain different artifact classes.
A BEAM-diff artifact cannot drive `release_handler`; only a full release
package can. That is why the build lane's classification stays two-class and
the relup lane consumes its own packages.

## References

- [Hot deploy gap audit](../2026-08-21-hot-deploy-gap-audit.md)
- [Forge build lane](forge-build-lane.md)
- [Transactional deployment](forge-transactional-deployment.md)
- [Release deployment fallbacks](release-deployment-fallbacks.md)
