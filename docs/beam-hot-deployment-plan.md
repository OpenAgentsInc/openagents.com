# BEAM hot deployment plan

Date: 2026-08-19

Status: Design and partial local implementation; staging proof incomplete;
production use prohibited

## Outcome

OpenAgents is designed to support three deployment classes:

1. Direct BEAM loading for allowlisted, code-only changes.
2. OTP release upgrades, or relups, for versioned code and state migrations.
3. Rolling image replacement for ERTS, OTP, native dependency, asset, configuration, migration, and other structural changes.

The deployment system will select the narrowest class that completely covers a change. It will never apply part of a candidate and call the candidate live. Every promotion, build, deployment, refusal, rollback, and boot-convergence attempt will produce an auditable receipt.

This document describes the target safety model and preserves the detailed
implementation sequence. It is not a readiness receipt. Persistence, build,
hot-load, relup, cluster, and proof-harness pieces exist locally, but the full
classifier, transactional fleet path, reverse upgrade, rolling replacement,
isolated staging matrix, failure injection, and soak have not passed on one
candidate. Phoenix development code reloading is unrelated to this plan.

The current authority is
[`docs/architecture.md`](architecture.md) together with Gates 9–16 of the
[integration hardening plan](2026-08-20-integration-hardening-and-staging-readiness-recommendations.md).
Nothing in this historical phase sequence authorizes production deployment.

## Target success criteria

The work is complete when the system meets all of these conditions:

- An operator can promote a pushed commit by repository and SHA.
- An allowlisted module-only change reaches every healthy BEAM node without restarting the application.
- A failed canary restores the exact code that ran immediately before the attempt.
- A partial fleet failure restores the exact prior code on every node that received the candidate.
- A stateful process can migrate through `code_change/3` during a relup without changing its PID or losing its state.
- A structural change is refused by the direct-load lane and proceeds through rolling replacement.
- A newly started node converges to the current live target before it becomes ready for traffic.
- Build and deployment receipts identify the source SHA, artifact digest, strategy, modules, nodes, result, and duration.
- The full local release gate passes without hosted CI.

The first performance target for a direct BEAM deployment is less than 60 seconds from promotion to a consistent three-node fleet. Correctness takes precedence over this latency target.

## Deployment classes

| Class | Use it for | Artifact | Rollback |
| --- | --- | --- | --- |
| Direct BEAM load | Allowlisted module additions and changes with no structural effects | Normalized changed-module manifest and BEAM tar | Restore the exact predeployment module binaries on every affected node |
| Relup | Versioned application code, compatible dependency changes, and explicit process-state migrations | `.appup`, `.relup`, `.rel`, and release tar | Install the reverse relup and restore the prior permanent release |
| Rolling replacement | ERTS or OTP changes, NIFs, dependency graph changes outside relup policy, module deletion, assets, runtime structure, and other unsupported changes | Immutable release image by digest | Roll forward or replace nodes with the last known-good image |

The classifier must fail closed. If it cannot prove that a change qualifies for a direct BEAM load or relup, it must return `needs_rolling_replace`.

## End-to-end flow

```text
pushed commit
    |
    v
operator promotion
    |
    v
target state machine
    |
    v
isolated release build --------> immutable artifact and build receipt
    |
    v
deployment classifier
    |
    +---- direct BEAM ----> canary ----> fleet transaction ----> live receipt
    |
    +---- relup ----------> staged release ----> node-by-node install ----> live receipt
    |
    `---- structural -----> rolling replacement ----> health gates ----> live receipt

new node boot ----> read live target ----> fetch artifact ----> converge ----> readiness
```

## Safety invariants

Implement these invariants before enabling the deployment lane:

- **A pushed commit is the artifact source.** Promotion accepts only a SHA that exists in the repository’s durable ref history.
- **Promotion is an operator action.** A push never promotes itself.
- **Targets are append-only.** Promoting a known-good SHA creates a new target instead of mutating history.
- **Artifacts are immutable.** Address each artifact by source SHA and SHA-256 digest. Verify the digest before loading or installing it.
- **The allowlist is operator-owned configuration.** Request data and repository content cannot expand it.
- **A deployment is atomic at fleet scope.** Mark a target `live` only after every expected healthy node reports the same revision and passes its smoke checks.
- **Rollback restores the immediate predecessor.** Do not assume that the image contains the last live module version because the fleet may have completed several direct loads since the image was built.
- **Every terminal outcome has a receipt.** Record `live`, `reverted`, `needs_relup`, `needs_rolling_replace`, and `failed` results.
- **Boot convergence does not hide failure.** A node may start on image code when convergence fails, but readiness remains false until the node matches the fleet target or an operator changes the target.
- **Structural changes never enter the direct-load lane.** Treat module deletion, ERTS changes, NIFs, migrations, dependency changes, assets, and release configuration as structural unless the relup policy explicitly supports them.
- **Secrets remain runtime-only.** Never store credentials in artifacts, receipts, logs, build output, or repository configuration.

## Target module layout

Keep each module in its own file and use the existing `OpenAgents.Repo`, `OpenAgents.PubSub`, and `OpenAgentsWeb.Endpoint` infrastructure.

```text
lib/openagents/build_info.ex
lib/openagents/cluster.ex
lib/openagents/release.ex
lib/openagents/forge/target.ex
lib/openagents/forge/build_receipt.ex
lib/openagents/forge/deploy_receipt.ex
lib/openagents/forge/targets.ex
lib/openagents/forge/builder.ex
lib/openagents/forge/build_executor.ex
lib/openagents/forge/build_executor/sidecar.ex
lib/openagents/forge/hot_loader.ex
lib/openagents/forge/boot_converge.ex
lib/openagents/forge/deploy_supervisor.ex
lib/openagents/forge/artifact_store.ex
lib/openagents/forge/artifact_store/local.ex
lib/openagents/forge/smoke_check.ex
lib/openagents/forge/relup_builder.ex
lib/openagents/forge/relup_deployer.ex
```

The forge repository, ref, and durable artifact services are prerequisites for promotion and boot convergence. Define narrow behaviours for these services when the implementation order requires temporary test adapters:

- A commit store verifies that `{repo, sha}` exists.
- An artifact store writes and fetches immutable content by repository, SHA, and digest.
- A push clock returns the matching push timestamp for push-to-live measurement.
- A fleet provider returns the expected nodes and their health state.

Use production forge implementations once those services are available. Keep fake implementations under `test/support`.

## Phase 1: Add the release and relup foundation

Build a hot-upgrade-capable OpenAgents release before adding automated deployment.

1. Add `castle` and its Forecastle release integration to `mix.exs`.
2. Add the `:appup` compiler before the existing Phoenix LiveView compiler.
3. Define an `openagents` release that includes ERTS, excludes source, and runs the Forecastle pre-assemble and post-assemble steps.
4. Add `rel/openagents.appup.exs`. Keep the initial appup empty unless the candidate names a real version transition.
5. Add `OpenAgents.Release` and run Ecto migrations from application startup under the database advisory lock. Do not rely on a preboot `eval` command that runs before Castle creates version-specific release configuration.
6. Add a multi-stage `Dockerfile` that builds assets and the release, copies only runtime requirements into the final image, and starts `/app/bin/openagents start` with `PHX_SERVER=true`.
7. Pin Elixir, OTP, and the operating-system base consistently between the runtime image and the build sidecar.
8. Add `OpenAgents.BuildInfo` with the image revision and hot-loaded timestamp fields used by status checks.

Add these proof harnesses under `ops/relup-proof/`:

- `run.sh` builds two minimal releases and proves a live `code_change/3` migration.
- `version-chain.sh` upgrades one live process through every supported release version.
- `kill-during-install.sh` kills the emulator during `install_release`, verifies that the old permanent release boots, restages the consumed artifact, and completes the retry.

Add a unit fixture with versioned GenServer state under `test/support`. Test state migration with `:sys.suspend/1`, `:sys.change_code/4`, and `:sys.resume/1`.

**Exit criteria:** `mix release` produces a Castle-managed tar, the three proof harnesses pass locally, and the application starts through the Castle launcher.

## Phase 2: Establish distributed runtime identity

Direct fleet loading requires stable Erlang distribution.

1. Add `OpenAgents.Cluster` as the bounded API for node membership, expected fleet size, and quorum state.
2. Configure `RELEASE_DISTRIBUTION`, `RELEASE_NODE`, `RELEASE_COOKIE`, and a fixed distribution port range at runtime.
3. Continue using `DNSCluster` for discovery, and verify that all expected nodes form one mesh.
4. Add a bounded `:erpc` health report that includes release version, build revision, boot-convergence state, and uptime.
5. Separate liveness from readiness. Liveness means that the VM and BEAM run; readiness means that the node matches the current target and can receive traffic.
6. Add local multi-node tests with `:peer`. Test join, loss, timeout, and a node that returns a different build revision.

Do not make the direct-load lane responsible for durable application-state handoff. A rolling replacement can ship only after the application’s own stateful workloads tolerate one node leaving at a time.

**Exit criteria:** three local nodes form a cluster, report a consistent revision, and detect a missing or divergent node without blocking the status surface.

## Phase 3: Add target and receipt persistence

Generate migrations with `mix ecto.gen.migration` for these append-only records:

- `forge_fleet_targets` stores `repo`, `sha`, `promoted_by`, selected strategy, status, bounded details, and timestamps.
- `forge_builds` stores the source SHA, target ID, toolchain identity, baseline SHA, module changes, artifact path and digest, bounded output, and duration.
- `forge_deploys` stores the source SHA, target ID, strategy, modules, expected nodes, per-node results, canary result, artifact digest, push-to-live duration, and terminal result.

Use this target state machine:

```text
promoted
  -> building
  -> built
  -> deploying
  -> live | reverted | needs_relup | needs_rolling_replace | failed
```

Implement `OpenAgents.Forge.Targets` with these rules:

- Verify the SHA before inserting a promotion.
- Use a cluster-wide transaction key or database lock so only one node advances each transition.
- Refuse invalid transitions and every transition out of a terminal state.
- Bound strings, lists, compiler output, and arbitrary detail maps before persistence.
- Broadcast promotions and status changes through `OpenAgents.PubSub`.
- Treat pinning back to an older SHA as a new promotion.

**Exit criteria:** tests prove valid promotion, unknown-SHA refusal, the complete lifecycle, bounded details, single-writer behavior, and pin-back.

## Phase 4: Build immutable BEAM artifacts

Run production builds outside the serving release. The web process must not receive a Docker socket or a compiler toolchain.

1. Define `OpenAgents.Forge.BuildExecutor` as a behaviour.
2. Add `OpenAgents.Forge.BuildExecutor.Sidecar` as the production adapter and a fake executor under `test/support`.
3. Communicate through a shared file queue. Write each request to a temporary file, rename it atomically, and return the result and output through the same atomic protocol.
4. Use a structured, non-executable request format such as JSON. Do not source queue files as shell programs.
5. Give each build a unique ID. Do not key queue responses only by SHA because retries and concurrent targets can reuse a commit.
6. Clone or fetch the canonical repository into an isolated workspace, check out the exact SHA in detached mode, and run the production compiler with warnings treated as errors.
7. Record the Elixir version, OTP release, application version, `mix.lock` digest, source SHA, and baseline SHA in the build manifest.
8. Normalize BEAM files before hashing. Remove compile-info, debug, documentation, and checker chunks that do not change executable behavior. Preserve line information.
9. Compare the candidate against the current live target’s immutable manifest, not the sidecar’s most recent local build. A node-local warm manifest is only a cache.
10. Detect additions, changes, and deletions. Send module deletions to relup or rolling replacement.
11. Write the changed BEAM files and their normalized manifest to a tar. Write a SHA-256 digest beside the artifact.
12. Store the artifact locally for the immediate deployment and in the durable artifact store for replacement-node convergence.
13. Insert the build receipt before broadcasting `{:forge_build_ready, build}`.

The build coordinator processes one target at a time. Every node may hear the promotion, but only the node that wins the `promoted -> building` transition performs the build. A warm workspace may improve scheduling, but it cannot determine correctness.

**Exit criteria:** tests cover successful builds, empty diffs, additions, deletions, compiler failure, bounded output, stale and cold manifests, artifact digest verification, worker recovery, and duplicate delivery.

## Phase 5: Add direct BEAM classification and local canary loading

Implement `OpenAgents.Forge.HotLoader` behind a disabled-by-default runtime flag.

1. Read an operator-owned allowlist from runtime configuration. Support exact module names and namespace prefixes that end in `.`.
2. Classify the complete candidate before loading any module.
3. Refuse the complete artifact when one declared or extracted module is not allowlisted.
4. Verify the artifact digest and derive module identity from each BEAM entry. Confirm that the declared manifest and extracted modules match exactly.
5. Bound the number of modules and artifact bytes before creating module atoms or loading binaries.
6. Capture the currently loaded object code for every candidate module.
7. Load the candidate through `:code.load_binary/3` on the canary.
8. Run `OpenAgents.Forge.SmokeCheck`. The default check verifies that every module loaded, `OpenAgents.BuildInfo.revision/0` returns a binary when present, the router resolves known routes, and the local readiness probe passes.
9. If loading or smoke checks fail, restore every captured module. Purge a module only when it did not exist before the attempt.
10. Record and broadcast `reverted`, `needs_relup`, `needs_rolling_replace`, and `failed` outcomes as first-class results.

Do not mark a canary success as a fleet success. Phase 6 adds the fleet transaction.

**Exit criteria:** tests prove successful local loading, allowlist refusal without partial loading, corrupt-artifact rollback, exact rollback after multiple prior hot loads, manifest mismatch refusal, and a smoke-check failure.

## Phase 6: Make fleet loading transactional

Replace a one-way `:erpc.multicall` with an explicit prepare, apply, verify, and commit protocol.

1. Snapshot the expected healthy node set at the start of deployment.
2. Send the artifact digest and module manifest to every node during prepare.
3. Make every node verify the artifact, capture its exact prior object code, and return a deployment token without loading the candidate.
4. Apply and verify the candidate on one canary node.
5. Apply the candidate on the remaining prepared nodes.
6. Run smoke checks and revision checks on every expected node.
7. Commit the deployment tokens and advance the target to `live` only when every node succeeds.
8. If any node fails or times out, use the tokens to restore the captured binaries on every node that applied the candidate.
9. Verify the restored revision across the fleet before recording `reverted`.
10. If rollback cannot restore fleet consistency, mark the target `failed`, remove divergent nodes from readiness, and require boot convergence or rolling replacement.

Store deployment tokens in bounded node-local state with expiration. A token must identify the target ID, source SHA, artifact digest, and prior revision so another deployment cannot reuse it.

**Exit criteria:** multi-node tests prove all-node success, remote timeout, remote load failure, exact fleet rollback, duplicate event handling, node membership changes during deployment, and refusal to mark a divergent fleet live.

## Phase 7: Converge replacement and restarted nodes

Add `OpenAgents.Forge.BootConverge` as a synchronous boot step after `OpenAgents.Repo` starts and before `DNSCluster`, `OpenAgents.PubSub`, and `OpenAgentsWeb.Endpoint` start.

1. Read the newest live target for the configured repository.
2. If the target has a direct BEAM artifact, load it from the local cache or fetch it from the durable artifact store.
3. Verify the digest, allowlist, and module manifest before loading.
4. Record the outcome in `:persistent_term` for health and status reports.
5. Treat a live target with an empty artifact as converged.
6. Start on image code if the target or artifact cannot load, but keep readiness false while the node differs from the live target.
7. Retry convergence with bounded backoff so an artifact-store interruption does not require another restart.
8. Prune old local artifacts while retaining the current target and immediate rollback artifacts. Never prune the durable copy or receipts.

**Exit criteria:** tests cover local convergence, durable fetch, no target, non-live target, empty artifact, missing artifact, off-allowlist content, corrupt digest, and readiness behavior.

## Phase 8: Add the production relup lane

Use relups for changes that need OTP-coordinated module updates or `code_change/3` state migration but do not cross a structural boundary.

1. Require every long-lived GenServer with state that must survive an upgrade to use a versioned state struct.
2. Require a tested `code_change/3` for every state-shape transition.
3. Keep `rel/openagents.appup.exs` explicit. Use `{:load_module, Module}` for a pure swap and `{:update, Module, {:advanced, extra}}` for state migration.
4. Build the prior and candidate releases with explicit versions.
5. Generate both forward and reverse relups from the two `.rel` files.
6. Package and checksum the candidate release tar, `.appup`, and `.relup`.
7. Add `OpenAgents.Forge.RelupBuilder` to produce and receipt this artifact when classification returns `needs_relup`.
8. Add `OpenAgents.Forge.RelupDeployer` to stage, check, unpack, and install the candidate on one node at a time.
9. Run readiness and application health checks after each install before making the release permanent or proceeding to the next node.
10. Install the reverse relup when a health check fails. Stop the sequence if downgrade cannot restore the node.
11. Restage the release tar after a crash during install because `unpack_release` consumes it.
12. Advance the fleet target to `live` only after every node reports the same permanent release.

Use additive-first database migrations before a relup and contract in a later release. Do not combine an irreversible schema contraction with a reversible code upgrade.

**Exit criteria:** a staged cluster completes upgrade, downgrade, and re-upgrade while a stateful process keeps its PID and state. The kill-during-install drill proves restart on the prior permanent release followed by a successful retry.

## Phase 9: Add rolling replacement as the universal fallback

Implement rolling replacement before enabling broad direct-load prefixes.

1. Build an immutable release image and identify it by digest.
2. Require a full local gate receipt for the exact commit before rollout.
3. Remove one node from readiness and stop new work from entering it.
4. Confirm that the remaining nodes retain required capacity and quorum.
5. Replace the node with the target image.
6. Wait for BEAM membership, boot convergence, database access, and readiness before proceeding.
7. Repeat one node at a time.
8. Abort the rollout when a node does not rejoin. Do not continue reducing fleet capacity.

Keep provider-specific fleet inventory, image names, and secret identifiers in runtime configuration or operator-owned deployment configuration. Do not commit credentials or private infrastructure addresses.

Add a loopback-only break-glass Git transport that does not depend on the running Phoenix endpoint. Document that break-glass pushes bypass normal receipts and must be replayed through the standard path after recovery.

**Exit criteria:** a no-op image rollout replaces every node one at a time without dropping readiness below the configured threshold, and a failed replacement stops before the next node.

## Phase 10: Add controls, status, and receipts

Add an operator-only promotion surface and a bounded public deployment projection.

The operator surface shows:

- The repository and full SHA.
- The operator identity.
- The target state and selected strategy.
- The changed modules and structural reasons.
- Bounded compiler and smoke-check output.
- Per-node prepare, apply, verify, rollback, and readiness results.
- The artifact digest and build toolchain.
- A **Promote** action and a pin-back action.

The public status projection shows only bounded operational data:

- Short SHA and target status.
- Strategy and changed-module count.
- Release and revision consistency by anonymous node label.
- Boot-convergence state.
- Last and median push-to-live duration.
- Recent terminal deployment results.

Never publish module names, infrastructure addresses, secrets, build URLs, full operator identifiers, or free-form compiler output on the public status surface.

Subscribe both surfaces to target, build, deploy, and cluster-status PubSub topics so updates appear without a page reload.

**Exit criteria:** LiveView tests use stable DOM IDs to prove promotion, refusal, live progress, rollback, pin-back, and public redaction.

## Phase 11: Add the local release gate

Create `ops/ci/gate.sh` and run it locally, from the pre-push hook, and from release commands. Do not add hosted CI configuration.

The full gate runs these stages in order:

1. Fetch dependencies.
2. Compile with warnings as errors.
3. Run `mix precommit`.
4. Run distributed-node tests.
5. Run the direct-load transaction suite.
6. Run the relup proof.
7. Run the version-chain proof.
8. Run the kill-during-install proof.
9. Write a local receipt containing the exact Git SHA and completion time.

Release commands refuse a stale or missing receipt. Keep an explicit, logged emergency override for recovery.

**Exit criteria:** changing the checked-out commit invalidates the gate receipt, and both relup and rolling commands refuse to run until the current commit passes.

## Phase 12: Stage and enable the lane

Keep the new processes disabled by default until the preceding phases pass.

1. Enable target persistence and receipt reads with the workers disabled.
2. Enable builds with a fake executor in tests and the sidecar on one staging node.
3. Enable local canary loading for `OpenAgents.BuildInfo` only.
4. Run a good direct-load drill and a deliberately broken BEAM drill.
5. Enable the fleet transaction on three staging nodes.
6. Drill a remote timeout and prove exact rollback on every prepared node.
7. Replace one node and prove boot convergence from durable storage.
8. Run a router and LiveView change after adding `OpenAgentsWeb.` to the allowlist.
9. Run a stateful relup, reverse relup, and kill-during-install recovery.
10. Run a structural change and prove that the direct lane refuses it before rolling replacement succeeds.
11. After every preceding staging proof passes, prepare an explicitly approved
    candidate for a later production-readiness decision; retain an immediate
    runtime kill switch. This plan does not authorize enabling production
    workers.

Do not broaden the allowlist based only on module naming. Add each namespace after its state, side effects, on-load behavior, and smoke checks have a completed drill.

## Commit sequence

Keep every commit independently buildable and run `mix precommit` before each handoff.

| Order | Commit | Required verification |
| --- | --- | --- |
| 1 | Add the release and relup foundation | Release builds and all relup proof scripts pass |
| 2 | Add distributed runtime health | Local multi-node membership and divergence tests pass |
| 3 | Add deployment targets and receipts | Migration, transition, and pin-back tests pass |
| 4 | Add isolated BEAM artifact builds | Sidecar protocol, manifest, digest, and build recovery tests pass |
| 5 | Add local canary hot loading | Allowlist, corruption, smoke, and exact rollback tests pass |
| 6 | Make BEAM deployment transactional across the fleet | Multi-node success, timeout, and fleet rollback tests pass |
| 7 | Converge booted nodes to the live target | Local cache, durable fetch, and readiness tests pass |
| 8 | Add production relup deployment | Upgrade, downgrade, version-chain, and crash recovery pass |
| 9 | Add rolling replacement fallback | One-node-at-a-time rollout and abort tests pass |
| 10 | Add deployment controls and status | Operator LiveView and public-redaction tests pass |
| 11 | Gate local releases with receipts | Stale-receipt refusal and the complete local gate pass |
| 12 | Enable receipted BEAM deployments | Staging drill matrix and production smoke checks pass |

## Test inventory

Add small test files by responsibility:

```text
test/openagents/forge/targets_test.exs
test/openagents/forge/build_executor_test.exs
test/openagents/forge/builder_test.exs
test/openagents/forge/hot_loader_test.exs
test/openagents/forge/fleet_hot_loader_test.exs
test/openagents/forge/boot_converge_test.exs
test/openagents/forge/relup_builder_test.exs
test/openagents/forge/relup_deployer_test.exs
test/openagents/forge/deploy_loop_test.exs
test/openagents/cluster/code_change_test.exs
test/openagents/cluster/membership_test.exs
test/openagents_web/live/admin_deploy_live_test.exs
test/openagents_web/live/status_live_test.exs
```

Use `start_supervised!/1` for processes. Use process monitors, `:sys.get_state/1`, PubSub messages, and bounded readiness polling instead of fixed sleeps in ExUnit tests.

The end-to-end deployment test must exercise this complete path with a real local Git push and a fake compiler adapter:

```text
push -> receipt -> promote -> build -> classify -> canary -> fleet -> live
```

Assert the loaded module behavior, final target state, artifact digest, per-node result, and push-to-live duration. Add a paired test where one off-allowlist module causes complete refusal and no module loads.

## Configuration inventory

Use runtime configuration for policy and deployment environment values. Use safe defaults that keep deployment disabled.

| Setting | Purpose | Default posture |
| --- | --- | --- |
| `forge_deploy_lane_enabled` | Starts build and deploy workers | `false` until staged |
| `forge_boot_converge_enabled` | Replays the live target during boot | `false` until durable artifacts work |
| `forge_hot_load_allowlist` | Exact modules and namespace prefixes | `[]` |
| `forge_build_executor` | Selects the sidecar or test adapter | Sidecar in production only |
| `forge_build_queue_dir` | Shared request and response queue | Deployment-specific data path |
| `forge_build_dir` | Sidecar checkout and build cache | Deployment-specific data path |
| `forge_artifact_dir` | Node-local BEAM and relup cache | Deployment-specific data path |
| `forge_build_timeout_ms` | Bounds compilation | Five minutes |
| `forge_fleet_rpc_timeout_ms` | Bounds each fleet operation | Fifteen seconds |
| `forge_target_repo` | Selects the deployed repository | Explicit production value |
| `forge_internal_git_url` | Gives the sidecar a canonical clone URL | Loopback or private network |
| `forge_operator_token` | Authenticates promotion and local clone | Required at runtime, never logged |
| `forge_expected_fleet_size` | Defines revision consistency and readiness | Explicit production value |
| `forge_artifact_store` | Selects durable artifact storage | Local adapter in development |

Validate production-required settings during boot. Redact credentials when rendering configuration errors.

## Known hazards to close before production

- **Stale build baselines:** A sidecar-local manifest can describe an unrelated commit and report most of the application as changed. Always diff against the current live target’s immutable manifest.
- **Rollback to image code:** `:code.get_object_code/1` can return the image’s module after prior direct loads. Capture the exact current binary on every node as part of the deployment transaction.
- **Partial remote success:** A raw `:erpc.multicall` can load some nodes and time out on others. Require prepare tokens, all-node verification, and fleet-wide rollback.
- **Module deletion:** A changed-BEAM tar cannot express safe code removal by itself. Route deletions to relup or rolling replacement.
- **Artifact disagreement:** Never trust a declared module list without checking the tar entries and digest.
- **Atom growth:** Bound artifact entries and validate BEAM module identity before loading.
- **Queue injection:** Use structured queue files and fixed command arguments. Never evaluate repository-controlled queue content as shell code.
- **Anonymous build amplification:** Promotion and build operations remain authenticated and rate-limited even when repository reads are public.
- **Boot inconsistency:** A node that starts on fallback image code must not enter readiness while the fleet target names newer code.
- **Irreversible schema changes:** Use expand-and-contract migrations across releases so rollback remains possible.

## Final acceptance drill

Run the final drill on a three-node staging fleet:

1. Promote an allowlisted `OpenAgents.BuildInfo` change and verify one consistent revision on all nodes.
2. Promote a Phoenix LiveView and router change and verify existing and new routes without a restart.
3. Promote an artifact containing one corrupt BEAM and verify exact fleet rollback.
4. Promote an off-allowlist module and verify `needs_rolling_replace` with no partial load.
5. Stop one node, replace its local cache, restart it, and verify convergence from the durable artifact.
6. Upgrade a stateful GenServer through a relup, verify the same PID and migrated state, downgrade it, and upgrade it again.
7. Kill a node during relup installation, verify boot on the prior permanent release, restage the artifact, and complete the upgrade.
8. Ship a structural change through rolling replacement and verify that only one node leaves readiness at a time.
9. Confirm that every attempt has a complete receipt and that the public status surface contains no sensitive details.
10. Run `mix precommit` and `ops/ci/gate.sh` at the final SHA.

After this drill, the evidence can be reviewed as a production-readiness
candidate. Direct BEAM loading, relup, and rolling replacement remain disabled
until a separate operator decision approves a specific configuration and
candidate.
