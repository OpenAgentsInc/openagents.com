# Production deploy runbook

This is the single end-to-end procedure for deploying `openagents.com` to the
production fleet. Follow it top to bottom. Every other operations document is
reference material; this one is the checklist.

The pipeline is:

```
push candidate to forge main
  → release gate (exact SHA)
  → immutable image build and publish
  → promote on /admin/forge
  → migration job
  → rolling replacement (structural) or direct deploy (BEAM-only)
  → settle the target
  → verify production
```

Two invariants govern everything:

- **One exact Git SHA.** The gate receipt, the image, the promotion, and the
  rolling replacement all name the same full commit SHA. If `main` advances,
  you have a new candidate and you start over at the gate.
- **One immutable image digest.** Deployment identity is a `sha256:` digest,
  never a mutable tag.

## 0. One-time workstation prerequisites

The gate fails fast when any of these is missing. Set them up once per
machine:

1. Tools on `PATH`: `jq`, `mix`, `npm`, `docker`, `git` version 2.38 or
   later (the stack merge and git-plane tests run
   `git merge-tree --write-tree`, which older git does not support), and
   `terraform` satisfying `>= 1.11, < 2.0` (the staging infrastructure gate
   checks `ops/staging/infra/versions.tf`).
2. JavaScript dependencies: run `npm ci --prefix assets`. The relup stage runs
   `mix assets.deploy`, which needs `assets/node_modules` (for example
   `posthog-js`). A missing install fails the relup stage, not the javascript
   stage.
3. A local PostgreSQL server with the `vector` extension available, plus a
   disposable database the gate may trash:

   ```sh
   createdb openagents_release_smoke
   psql -d openagents_release_smoke -c 'CREATE EXTENSION IF NOT EXISTS vector;'
   ```

   The `OPENAGENTS_RELEASE_SMOKE_DISPOSABLE=1` flag asserts the database is
   disposable; it does not create it. The version-chain and release-smoke
   stages boot real releases against this database and fail during startup if
   it does not exist.
4. Operator gcloud auth with compute and Secret Manager access in
   `openagentsgemini`, and Docker configured for Artifact Registry:

   ```sh
   gcloud auth login <operator>@openagents.com --no-browser
   gcloud auth configure-docker us-central1-docker.pkg.dev
   ```

## 1. Pick the candidate

1. Work from a clean worktree: `git status --porcelain` prints nothing.
2. The candidate is the exact SHA of forge `main`. Fetch and confirm
   `git rev-parse HEAD` equals `git rev-parse origin/main`.
3. If you have local commits, push them first: `git push openagents HEAD:main`
   (never GitHub; the push guard refuses non-forge pushes).
4. Record the full SHA. It appears in every later step.

## 2. Run the release gate

```sh
OPENAGENTS_RELEASE_SMOKE_DISPOSABLE=1 \
OPENAGENTS_RELEASE_SMOKE_DATABASE_URL='ecto://USER:PASSWORD@127.0.0.1/openagents_release_smoke' \
ops/ci/gate.sh
```

The gate runs, in order: `compile`, `production_compile`, `precommit`,
`cluster`, `javascript`, `direct_transaction`, `relup`, `version_chain`,
`interrupted_install`, `rolling_replacement`, `contracts`, `staging_infra`,
and `release_smoke`. It writes a receipt keyed to the exact SHA under
`.git/openagents/`. A receipt from a different SHA — even a docs-only parent —
is invalid.

Budget 30 to 60 minutes. If a stage fails, fix the cause, push the fix to
forge `main`, and rerun the whole gate against the new SHA. Do not deploy a
commit whose gate did not complete.

## 3. Build and publish the immutable image

```sh
ops/deploy/build-image.sh openagents:<full-sha>
```

The script verifies the gate receipt (`ops/ci/gate.sh --verify`), builds the
`final` Docker target for `linux/amd64`, boots the packaged release to check
that the embedded `OpenAgents.BuildInfo.revision()` equals the SHA, and writes
a receipt to `.git/openagents/images/<sha>.json`.

Publish to Artifact Registry and capture the **registry** digest — the digest
printed by `docker push` is the deployment identity, not the local image ID:

```sh
docker tag <local-digest> us-central1-docker.pkg.dev/openagents-staging-20260820/openagents-staging/openagents:<full-sha>
docker push us-central1-docker.pkg.dev/openagents-staging-20260820/openagents-staging/openagents:<full-sha>
```

Record the pushed `sha256:` digest.

## 4. Confirm runtime secrets and environment

The fleet startup script (instance metadata key `startup-script` on
`sarah-fleet-1/2/3`) resolves secrets from Secret Manager at boot and passes
them to the app container through the `ENV_NAMES` array. A new runtime
environment variable needs three things:

1. A Secret Manager secret in `openagentsgemini`, with
   `roles/secretmanager.secretAccessor` granted to
   `oa-mvp-automation@openagentsgemini.iam.gserviceaccount.com`.
2. An `export NAME="$(secret <secret-name>)"` line in the startup script.
3. The name added to `ENV_NAMES`.

Edit one copy of the script, `diff` it against each instance's live metadata
(all three must be identical), then apply with:

```sh
gcloud compute instances add-metadata sarah-fleet-N --zone <zone> \
  --project openagentsgemini \
  --metadata-from-file startup-script=<file>
```

Metadata changes take effect at the next instance reset, which the rolling
replacement performs. Never print secret values.

## 5. Promote and classify

Promote the exact SHA through `/admin/forge`. The target moves
`promoted → building → built`, and the classifier decides the deployment
route:

- **Direct deploy**: the diff touches only allowlisted BEAM modules. The
  forge hot loop handles it; watch the target go `deploying → live`.
- **`needs_rolling_replace`**: anything structural — `config/*`, migrations,
  dependencies, assets, ERTS, or release-private files. Continue below.

Keep the classification receipt.

## 6. Migration job

Run exactly one migration job for the release; nodes must not race it.
`bin/migrate` takes the release advisory lock. Apply any reviewed migration
lineage bridge first, and require the lineage classification and integrity
checks to pass before touching the fleet.

## 7. Rolling replacement

`OpenAgents.Forge.RollingReplacement.run/2` replaces one node at a time. Its
request names the Forge target id, the exact current and previous SHAs, the
exact current and previous image digests, the expected node list, and the fleet
size.

Before it touches the fleet, the coordinator publishes the authorized rolling
identity onto that target. Boot convergence reads the published record, so a
node that boots into the authorized image is admitted on its first convergence
attempt and stays in the load balancer for the rest of the roll. Leave
`OPENAGENTS_FEATURE_BOOT_CONVERGENCE` on, and do not restart
`OpenAgents.Forge.BootConverge`.

For each node the coordinator removes readiness, drains to zero active work,
verifies remaining capacity and quorum, resets the instance with the target
digest (the GCP provider sets `openagents-image`, `openagents-image-digest`,
and `openagents-sha` metadata), then waits for membership, readiness, boot
convergence, database readiness, and the exact SHA and digest before moving on.
It records each node's observed SHA and image digest against the published
authority as that node rejoins.

Order: `sarah-fleet-1` (us-central1-a), `sarah-fleet-2` (us-central1-b),
`sarah-fleet-3` (us-central1-c). Two healthy nodes must exist before each
replacement. If a node fails to rejoin, the coordinator rolls back to the
previous digest; wait for full health and stop — do not continue the roll.

## 8. Settle the target

```elixir
OpenAgents.Forge.Targets.finish_rolling_replacement(target_id, rolling_result)
```

Settlement demands the newest target in `needs_rolling_replace`, a complete
verified build receipt, a rolling result whose SHA and image identities match
the published authority and its exact expected node set, and an exact-identity
observation from every one of those nodes. Success flips the target to `live`
and inserts the immutable deployment receipt.

`rolling_nodes_not_converged` means a node is not on the authorized SHA and
image digest. The target stays `needs_rolling_replace`, which is the
recoverable state: read `details.rolling_authority.observed` on the target row
to see exactly which node reported which identity, fix that node, and rerun
`run/2` with the same request. Republishing the same identity resumes the roll
and keeps every recorded observation.

## 9. Verify production

Do not report success without all of the following:

- `/status` and `/api/status` return the exact SHA and image digest.
- All three nodes report the same revision and digest; `beam=3`, `raft=3`,
  quorum holds.
- All three backends of `sarah-backend` are healthy.
- The migration appears in `schema_migrations`.
- Login, a typed chat turn, and a durable reload work.
- Issues, git clone/fetch, and a read-only computer job work.
- New configuration is live without exposing secret values.

## Load balancer health check

The global backend service `sarah-backend` decides which nodes receive
traffic. The health check it references determines whether a broken node
leaves rotation:

- A TCP check (`sarah-hc-tcp`) only verifies that port `8080` accepts
  connections. A node that answers every request with `500` still passes,
  so it keeps serving a third of traffic while broken. Issue #105 records
  an incident where this happened.
- The HTTP check `sarah-hc-healthz` probes `GET /healthz` on port `8080`
  and requires `200`. The application returns `503` from `/healthz` when
  the database is unreachable, boot has not converged, the deployment
  participant is not ready, admission is not ready, or the forge cache is
  not ready, so an unhealthy node drops out of rotation.

Requirements before pointing the backend at the HTTP check:

1. The running image must exclude `/health` and `/healthz` from
   `force_ssl` in `config/prod.exs`. GCP HTTP probes are plain HTTP;
   `Plug.SSL` answers them with a `301` redirect, which counts as a failed
   probe. If every node redirects, the backend loses all members at once
   and the site serves `502`. This happened on 2026-08-23.
2. Verify the exact probe shape on every node first. `curl
   http://localhost:8080/healthz` is not sufficient because `Plug.SSL`
   excludes the `localhost` host. Use a non-localhost host header:

   ```sh
   curl -s -o /dev/null -w '%{http_code}' \
     -H 'Host: <node-external-ip>' http://localhost:8080/healthz
   ```

   Require `200` on all three nodes before swapping.
3. Swap, then watch `gcloud compute backend-services get-health
   sarah-backend --global`. If any node goes `UNHEALTHY` unexpectedly,
   revert immediately:

   ```sh
   gcloud compute backend-services update sarah-backend --global \
     --health-checks sarah-hc-tcp --global-health-checks
   ```

With the HTTP check active, a structural rolling replacement depends on boot
convergence admitting a node that runs the authorized rolling image. Because
`run/2` publishes that identity before the first replacement, nodes replaced
before settlement report `image_matches_rolling_target` and stay in rotation;
settlement through `finish_rolling_replacement/2` flips the target live and the
worker's own next convergence attempt reports `image_matches_live`. No flag
change and no restart of `OpenAgents.Forge.BootConverge` is part of this path.

Admission is bound to the published identity, not to the SHA alone: a node
whose image digest is not the authorized one, or a `needs_rolling_replace`
target with no published authority, admits nothing and the node correctly
returns `503`. If every node returns `503` at the start of a roll, check that
`run/2` actually published the authority — read `details.rolling_authority` on
the target row — rather than disabling boot convergence.

Images older than commit `a79bfce` degrade with `artifact_not_direct` instead
and return `503` for the whole roll, which would empty the backend. The
2026-08-22 rollout of `45f6fff3222c432f248ca831a6fbc882c0fc6206` ran on such an
image and needed a temporary boot-convergence disable plus a manual restart of
`OpenAgents.Forge.BootConverge`. That workaround is retired: do not use it.

## Known failure modes

| Symptom | Cause | Fix |
| --- | --- | --- |
| `cluster` stage: `report["consistent"] == true` fails | A `local_report` dependency crashes on peers where the app is loaded but not started | Health-report callees must fail closed (catch `:exit`), never raise |
| `relup` stage: esbuild cannot resolve a package | `assets/node_modules` missing | `npm ci --prefix assets` |
| `version_chain` / `release_smoke`: `invalid_catalog_name` | Disposable database does not exist | `createdb` + `CREATE EXTENSION vector` |
| `staging_infra`: terraform missing or version unsupported | No terraform, or version outside `>= 1.11, < 2.0` | Install a supported terraform |
| Push rejected (non-fast-forward) | Forge `main` advanced | Fetch, rebase your commit, push, restart the gate on the new SHA |
| `gate.sh --verify` fails in `build-image.sh` | Receipt is for a different SHA | Rerun the gate on the exact candidate |
| App boots without a new variable | Name missing from `ENV_NAMES` in the startup script | Add the export and the `ENV_NAMES` entry, re-apply metadata |
| Target build fails with `invalid_module_name` | A compiled module falls outside the artifact allowlist in `OpenAgents.Forge.BuildArtifact` (`OpenAgents.*`, `OpenAgentsWeb.*`, allowlisted protocol implementations, `Mix.Tasks.Openagents.*`) | Rename the module into an allowlisted namespace, or extend the pattern for a new generated-implementation family. `test/openagents/forge/build_artifact_namespace_test.exs` catches this in precommit |
| Target build fails with `invalid_module_name` even though every source module is allowlisted | The build cache at `$OPENAGENTS_FORGE_BUILD_DIR/cache/_build/prod` persists across builds, and a stale BEAM for a renamed or deleted module is still in `lib/openagents/ebin` | Since the application-resource packaging fix, `BuildWorker.read_candidate_beams/1` packages only modules listed in the generated `openagents.app`, so stale BEAMs are ignored. On an older build, delete the stale `.beam` from the cache `ebin` on the node that ran the build and re-promote |
| Intermittent git-over-HTTP `500` on push and fetch | One fleet node has a structurally invalid bare-repository cache (for example `HEAD` present but `refs/` missing), and `Repos.ensure_repo_at!` crashed on it. The load balancer alternates between healthy nodes and the broken one | Since the quarantine fix in `OpenAgents.Forge.Repos`, the node moves the invalid cache to `<repo>.git.corrupt-<n>` and re-materializes from the WAL on the next read. On an older build, find the node whose log shows `fatal: not a git repository` with a `MatchError` from `Repos.set_default_branch!/2`, move the cache directory aside inside the container, and let WAL replay rebuild it (`docs/operations/forge-cache-recovery.md`) |
