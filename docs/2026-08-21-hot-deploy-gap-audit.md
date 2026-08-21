# Hot deploy gap audit

**Date:** 2026-08-21
**Commit measured:** `eda094c` (origin/main)
**Question:** Sarah shipped code-only changes to its three-node production fleet in 13–55 seconds. OpenAgents has the same machinery ported, yet today's deploys still take roughly 25 minutes. What is actually missing?
**Sources:** the `OpenAgentsInc/sarah` issue tracker (closed issues with comments, especially #121 and #157), the local `sarah` working copy (`ops/fleet/`, `rel/`, `docs/RELUPS.md`, `docs/DEPLOY.md`, `docs/FORGE-RUNBOOK.md`), codex session `01a01f1c` through 2026-08-21T19:49Z, and this repository's gates, runbooks, infra templates, and forge modules.

---

## 0. Verdict

The port is real. `OpenAgents.Forge.HotLoader`, the widened web-layer allowlist, the hardened builder lane, boot convergence, the transactional direct-load deployment, the relup lane, and the rolling fallback are all present in this repository, mostly in stronger form than Sarah's originals. Nothing needs re-implementing.

What is missing is **enablement**, and it is fenced deliberately:

1. The gate ladder stopped at Gate 11. Gate 12's isolated three-node staging fleet exists as Terraform but was never applied to the cloud; the recorded blocker is expired Google Cloud CLI credentials.
2. Every runbook forbids enabling the lanes until Gates 12–15 complete: `OPENAGENTS_FEATURE_FORGE`, `OPENAGENTS_FEATURE_FORGE_DEPLOY`, and `OPENAGENTS_FEATURE_BOOT_CONVERGENCE` are documented Off until then.
3. The builder sidecar image has publish tooling but is not pinned into fleet metadata — `openagents-builder-image` defaults to an empty string, so no running node has a build executor.
4. Today's staging is a pair of services, not the three-node VM fleet the transactional lane requires (exact expected membership is a hard precondition), so the fast lane physically cannot engage there.

Meanwhile every production deploy rides the structural class: one immutable image built locally under amd64 emulation (~9 minutes for commit `eda094c`), pushed to Artifact Registry, qualified on staging, then rolled one node at a time (~7 minutes). Push-to-live measured about 23 minutes on 2026-08-21 for a release whose changes were mostly hot-loadable LiveView and template work — the exact class Sarah moved in seconds.

Closing the gap is operator work, not engineering work: apply the staging Terraform, run Gates 12–15 against the real builder image, pin the builder digest into fleet metadata, flip the feature flags, then extend the runbooks with the consolidated decision table and drill lessons listed in section 5.

### Addendum: post-measurement production events (2026-08-21, later)

After this audit was measured, two claims moved:

1. **The direct-load transaction now works on production.** Commit `fa4b792`
   (a code-only router fix) was loaded across all three nodes through the real
   transaction protocol — `live` Forge target and deployment receipt recorded,
   boot convergence satisfied, process uptimes unbroken. The operator assembled
   and applied the artifact manually; no receipted automated deploy exists yet.
2. **"Nothing needs re-implementing" holds for the hot-load loop only.** The
   general relup path remains unconnected: `BuildArtifact` classifies only
   `direct_candidate` and `needs_rolling_replace` and can never emit a relup
   class, and `RelupDeployment` accepts only the fixed `0.1.0 → 0.2.0`
   proof transition while production runs `0.2.0`. Closing that lane is
   recorded as future work in
   [`docs/operations/forge-hot-loop.md`](operations/forge-hot-loop.md), which
   is also the enablement runbook for the automated loop.

---

## 1. What Sarah proved

Sarah's production fleet reached a receipted push-to-live loop measured in seconds, with three escalation classes that compose.

### 1.1 Timeline

| Date (2026) | Stage | Measured |
|---|---|---|
| before 08-18 | Cloud Run staging deploys | ~5 min each |
| 08-18 → 08-19 | Rolling image replacement across three nodes | ~15–25 min per roll (Cloud Build ~8–10 min plus rolling replace) |
| 08-19 ~02:48Z | In-place relup proven live on a fleet node (`unpack` → `install` → `commit`, downgrade, re-upgrade) | sub-second swap, BEAM never restarted |
| 08-19 06:04Z | Forge hot-load "Loop v0" closed on production: push → promote → incremental build → canary → fleet load | **13.242 s receipted** (`push_to_live_ms`) |
| 08-19 later | Real promote observed from public `/api/status`, all three nodes flipped revision | 25.6 s pipeline; 55.4 s including the human Promote click |
| 08-19 19:41Z | Issue #157 drill: allowlist widened to the whole web layer, router hot-swap verified in production | router-only change live in **18.6 s**; same-sha promote after manifest convergence landed in **10 s** |

### 1.2 The 13-second anatomy

Issue #121, closing comment by AtlantisPleb, 2026-08-19T06:05:14Z:

> **What the 13.2 seconds is** — anatomy of `push_to_live_ms: 13242`, measured on the production 3-node fleet (2026-08-19, commit `d6539cf`):
>
> The clock starts at the **push receipt** (the moment the forge acked `git push` — i.e., after the packfile + WAL index were durably persisted to GCS) and stops when the hot-load completed fleet-wide and the deploy receipt was written. In between:
>
> 1. **Promote** (~4 s of it, operator action): `Targets.promote/3` validated the SHA against the WAL-backed repo and broadcast on `forge:target`. In this run promotion was issued by automation right after the push; a human clicking Promote in `/admin/forge` would add whatever time the human takes — the receipt measures the pipeline, push-ack → live.
> 2. **Build** (the bulk): the winning node's sidecar fetched the new commit into its warm workspace, ran an **incremental** `mix compile` (only `Sarah.BuildInfo` recompiled), hashed all 325 beams with unstable chunks stripped, diffed against the manifest → exactly 1 changed module, tarred it.
> 3. **Hot-load** (sub-second): allowlist check, canary `:code.load_binary` on the build node, then `:erpc.multicall` to the other 2 nodes, target advanced to `live`, receipt written.
>
> Why it's fast: no Docker bake, no image push, no VM replace, no rolling restart — the release keeps running and only the changed beams move. The same change through the full bake-and-roll path takes ~15–25 **minutes** … That's roughly a **70–100× loop-time reduction** for hot-loadable changes.

The speed comes from four properties, none exotic: a warm persistent checkout with incremental compilation, per-module changed-set diffing with stable beam hashing, moving only changed BEAMs over existing cluster distribution, and receipts at each step.

### 1.3 The #157 verdicts worth keeping

- **The Phoenix router hot-swaps.** Drilled in production on all three nodes: a new route answered 200 everywhere within the promote, every pre-existing route kept answering, and a deliberately broken module still reverted at the canary. "`SarahWeb.` goes on the list whole, `SarahWeb.Router` included."
- **Allowlist-as-config survives reboot.** The drill first set the allowlist live over rpc to answer the question in minutes, then baked it into config so it outlives restarts. This repository already ships it baked (`config/config.exs:231`).
- **Per-node build manifests diverge and cause honest refusals.** With only the transition-winning node building, three nodes held manifests at three different commits; stale winners produced 35-module changed sets carrying off-allowlist modules and refused with `needs_rolling_replace`. After converging the manifests, the same-shape promote landed `live` in 10 s. Quote: "**The seconds-scale loop is only reliable while the manifests agree.**"
- **Revert restores baked code, not the last good hot-load.** Sarah's revert read object code from the release on disk, so after a failed drill the canary rolled back to image code while peers carried the hot-load — a divergent fleet until the next deploy reconverged it. Rule adopted there: treat any `reverted` as fleet-divergent and re-promote or roll. Note this repository's transactional design already fixes the root cause: participants capture exact prior object code per node and restore it on rollback (`docs/operations/forge-transactional-deployment.md`, phase protocol).
- **Cold builds destroy the economics.** The seconds-scale loop assumes a warm workspace; cold compiles take minutes. Warm `_build` on durable state disks is a prerequisite, not an optimization.

---

## 2. How openagents.com deploys today

From codex session `01a01f1c`, the 2026-08-21 release of commit `eda094c` (LiveView subscription fix, cold-cache warming, sidebar layout move, CSP fix):

| Time (UTC) | Step | Duration |
|---|---|---|
| 19:25 – 19:29 | Full precommit locally (1,687 tests plus JS, docs, dependency checks) | ~4 min |
| 19:30 – 19:39 | Build one immutable `linux/amd64` image locally under BuildKit emulation; push to Artifact Registry | ~9 min (CPU-bound emulated dependency compile) |
| 19:39 – 19:41 | Deploy same digest to both isolated staging services; verify health and revision identity | ~2 min |
| 19:41 – 19:49 | Roll production three nodes one at a time via instance replacement; verify each node's health, LB health, revision | ~7 min |
| total | push-to-live | **~24 min** |

The changes in this release were almost entirely `OpenAgentsWeb.` modules and templates — the class Sarah's #157 drill proved ships in 10–20 seconds. The session also records the recurring cost pattern: earlier the same day, commit `46e86d5` rode the identical bake-and-roll path, and the agent explicitly kept a "single-artifact constraint" rather than parallelizing because the immutable-image discipline is the only approved production path.

---

## 3. What is already here (the port is real)

Verified in this repository at `eda094c`:

| Capability | Location | Status versus Sarah |
|---|---|---|
| Hot loader: allowlist check, canary load, fleet multicall, revert, receipts | `lib/openagents/forge/hot_loader.ex` | Ported; adds double allowlist verification and bounded error codes |
| Web-layer allowlist, baked config with classification self-test | `config/config.exs:231`, `lib/openagents/runtime_config.ex:150` | Ported from #157; includes prefix/exact semantics and example-classification validation at boot |
| Build lane producing normalized-BEAM changed-set artifacts | `lib/openagents/forge/build_worker.ex`, `build_artifact.ex` | Hardened rewrite: JSON queue contract, digest-addressed artifacts, `:beam_lib.strip/1` stable hashing (the fix for Sarah's hash-instability defect), structural-reason classifier for mix.lock/config/assets/NIF paths |
| Isolated builder container, credential-free queue | `docs/operations/forge-build-lane.md`, `Dockerfile` forge-builder target, `ops/forge/build-worker.exs` | Stronger than Sarah's root sidecar: no compiler in the serving image, askpass-based credentials, mode-separated queue files |
| Transactional fleet deployment with rollback | `lib/openagents/forge/deployment.ex` and siblings; runbook `docs/operations/forge-transactional-deployment.md` | Stronger than Sarah's Loop v0: prepare/apply/verify/commit with expiring tokens, exact prior-object capture per node (fixes Sarah's revert-divergence flaw), membership rechecks between phases |
| Relup lane with appup + proof harness | `mix.exs` appup wiring, `rel/openagents.appup.exs`, `ops/relup-proof/`, runbook `docs/operations/release-deployment-fallbacks.md` | Proof harness only: the classifier never emits a relup class and `RelupDeployment` admits only the fixed `0.1.0 → 0.2.0` proof transition, so the general lane is ported but not connected |
| Boot convergence | `lib/openagents/forge/boot_converge.ex`; flag `OPENAGENTS_FEATURE_BOOT_CONVERGENCE` | Ported; readiness-gated so divergent nodes do not serve |
| Three-node fleet infrastructure with state disks and builder wiring | `infra/staging/main.tf`, `infra/staging/templates/fleet-startup.sh.tftpl` | Terraform-complete, safety-tested; cloud apply never ran |
| Promotion targets, receipts, WAL-backed git service | `lib/openagents/forge/targets.ex`, `pushes.ex`, `git_http.ex` | Ported and partially live: GitHub imports and the public clone URL already run in production |

Gates 0–11 are complete with evidence under `docs/evidence/`, including the direct transaction (Gate 10), fallback lanes, and packaged-release startup (Gate 11).

## 4. Why it still takes 25 minutes

Ranked by causal order:

1. **Gate 12 cloud apply never happened.** The isolated staging environment (private VPC, three fleet nodes with durable state disks, private deployer, Artifact Registry) is defined and safety-tested but unapplied. The implementation status records the blocker verbatim: "cloud work is blocked until the operator refreshes the expired Google Cloud CLI and Application Default Credentials." Everything downstream waits on this.
2. **The feature flags are Off by design.** `docs/runtime-configuration.md` documents `OPENAGENTS_FEATURE_FORGE` Off until gate 12, and `FORGE_DEPLOY` plus `BOOT_CONVERGENCE` Off until gate 13. The runbooks repeat the fence: "keep staging deployment disabled until the Gate 12 distributed staging lane exists… before anyone enables a deployment worker."
3. **No builder sidecar runs anywhere.** `infra/staging/main.tf:627` defaults `openagents-builder-image = ""`; the startup template validates and launches the builder only when that metadata is set. The publisher supports the builder image (`ops/staging/publish-candidate.sh` handles `openagents-builder` tags), so publishing and pinning it is mechanical once a registry exists.
4. **Staging topology mismatch.** Current staging is two services receiving image digests. The transactional lane requires exact expected fleet membership (`OPENAGENTS_FORGE_EXPECTED_FLEET_SIZE`), persistent forge/workspace volumes, and inter-node distribution — properties only the Gate 12 VM fleet provides.
5. **Runbooks stop short of operations.** The lane documents exist but none gives the operator the Sarah-style daily loop: classify the change, push to the owned forge, click Promote, watch the receipt land in seconds, escalate to relup/rolling only when the classifier refuses. Section 5 details the missing pieces.

## 5. Runbook gaps to close

These are documentation deliverables; write them while Gate 12 executes.

1. **A consolidated deployment-classes decision table**, equivalent to Sarah's `docs/DEPLOY.md`: for each change type (web module, template, router, schema, migration, dependency, config, ERTS/NIF), name the class (direct load / relup / rolling replacement), the artifact, and the expected wall-clock. Today the knowledge is spread across three runbooks plus the classifier source.
2. **A push-to-live operator procedure** for the direct lane: where to push, how to promote, which receipt surfaces show `modules`, result, and `push_to_live_ms`, what `needs_rolling_replace` means when it appears honestly, and the rule that a `reverted` outcome still warrants checking fleet convergence even though this design captures prior object code per node.
3. **The drill lessons as operational notes**: warm-workspace economics (cold builds take minutes and void the loop), manifest agreement across nodes, empty-manifest failure mode (an artifact with zero changed modules must never advance a target), break-glass expectations, and the timing caveat that receipts measure pipeline time, not human Promote latency.
4. **A staging qualification matrix entry for deploy-speed regression**: assert push-to-live stays under a stated bound for a representative web-layer change, so the fast lane cannot silently rot back into minutes.
5. **An update path for `production-cutover.md`**, whose status text ("the Sarah release as the serving application") predates the completed cutover; record that production now serves OpenAgents via rolling replacement and that the observation window condition for enabling faster classes has begun.

## 6. Recommended sequence to the first 15-second deploy

1. Refresh Google Cloud CLI credentials; run the staging Terraform apply and isolation validator (Gate 12 exit).
2. Publish candidate artifacts including the builder image; pin its digest into fleet metadata (Gate 13 exit).
3. Run the Gate 14 regression matrix and Gate 15 failure injection against the real fleet, including one representative `OpenAgentsWeb.`-only change promoted end to end.
4. Flip `OPENAGENTS_FEATURE_FORGE`, then `FORGE_DEPLOY` and `BOOT_CONVERGENCE`, in staging only; verify a push→promote→live round trip with receipts and confirm restart persistence via boot convergence.
5. Write the section 5 runbook additions from the drill results, then repeat the promotion in production behind the operator allowlist.

Steps 1–3 are the recorded gate plan; nothing in them requires new application code. The realistic payoff repeats Sarah's measurement: the 2026-08-21 release class drops from ~24 minutes to tens of seconds, with the bake-and-roll path retained for structural changes exactly as designed.
