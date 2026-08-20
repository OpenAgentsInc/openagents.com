# Forge build lane

Date: 2026-08-20

Status: Implemented locally; the transactional deployment lane now consumes its verified artifacts

## Purpose

The forge build lane turns one operator-promoted, fully qualified Git commit
into a reproducible BEAM artifact with fixed tar ownership and time metadata.
Compilation runs in an isolated builder container. The public release receives
no compiler, Docker socket, Git
credential, or ability to execute queue contents.

This lane only produces and verifies artifacts. The
[transactional deployment runbook](forge-transactional-deployment.md) owns
fleet application. Do not enable direct staging loads merely because a build
completes; the isolated distributed staging lane and fallback deployment
classes remain required.

## Runtime roles

Use separate runtime identities and mounts:

| Role | Access |
| --- | --- |
| Web release | Write requests, read responses and immutable artifacts, write the node-local artifact cache, and write the configured durable WAL store |
| Builder | Read and claim requests, write responses and immutable artifacts, write operator-only output, create disposable workspaces, and read only the forge credential through its own identity |
| Operator | Read retained full output for an incident or failed-build review |

The builder gets Git credentials from a mounted executable or workload
identity. Set `OPENAGENTS_FORGE_GIT_ASKPASS` to the absolute path of that
helper. The value is a path, not a token. The worker sets
`GIT_TERMINAL_PROMPT=0`, never places a credential in the repository URL, and
invokes Git without a shell.

## Build and start the isolated worker

Build the dedicated Docker target from the same pushed revision as the web
image:

```sh
docker build --target forge-builder --tag openagents-forge-builder:<git-sha> .
```

The image starts this command:

```sh
mix run --no-compile --no-start ops/forge/build-worker.exs
```

Provide these absolute paths to the worker:

```text
OPENAGENTS_FORGE_BUILD_QUEUE_DIR
OPENAGENTS_FORGE_ARTIFACT_DIR
OPENAGENTS_FORGE_BUILD_DIR
```

Mount the queue and artifact roots into both roles. Mount the build root only
into the builder. Do not mount a Docker socket. Arrange the shared group so the
web release and builder can exchange mode `0640` queue files. Artifacts are
published mode `0444`; retained output is mode `0600` and belongs to the
builder/operator identity.

## Queue contract

The versioned contract is canonical JSON. Unknown fields, oversized bodies,
invalid repositories, abbreviated SHAs, credential-bearing URLs, and malformed
UUIDs fail before compilation.

```text
<queue>/requests/<build-id>.json
<queue>/running/<build-id>.json
<queue>/responses/<build-id>.json
```

The web release writes a same-directory temporary file and publishes it under
an exclusive lock. The worker claims a request by atomic rename into
`running/`. It publishes the response through the same temporary-file
protocol. A request contains:

- schema version;
- unique build ID and target ID;
- repository and exact 40-character source SHA;
- credential-free internal repository URL;
- the current live target's immutable manifest, or `null` for the first build;
- an absolute expiry time.

Every retry gets a new build ID. On restart, the coordinator expires a stale
`running` receipt before making a new attempt. The new attempt reads only its
own response filename, so a late response cannot satisfy the retry. The worker
also expires abandoned claimed files after their request deadline.

## Exact build procedure

The worker performs these steps in order:

1. Create `<build-root>/jobs/<build-id>` and initialize an empty Git checkout.
2. Add the validated credential-free internal remote.
3. Fetch the exact source SHA and the baseline SHA, when present.
4. Check out the source SHA detached and require `git rev-parse HEAD` to equal
   it exactly.
5. Compare source paths against the immutable baseline and classify dependency,
   configuration, asset, migration, release, runtime-image, and native-code
   changes.
6. Run `MIX_ENV=prod mix deps.get --only prod --check-locked`.
7. Run `MIX_ENV=prod mix compile --warnings-as-errors` in the pinned image
   toolchain.
8. Read the complete application BEAM set, normalize each BEAM, and compare it
   with the baseline manifest.
9. Remove the disposable workspace whether the build succeeds or fails.

The manifest records the source and baseline identities, build ID, Elixir,
OTP, ERTS, application version, application-spec digest, `mix.lock` digest,
all candidate module digests, and the added, changed, and deleted sets.

## Artifact format and verification

The deterministic tar contains:

```text
manifest.json
beams/Elixir.OpenAgents.<Module>.beam
```

Only added and changed BEAMs are included. The manifest describes the complete
candidate module set so deletions cannot disappear from the comparison. The
artifact is stored as `artifacts/<sha256>.tar` in the builder output and WAL
store, then cached as `beams/<sha256>.tar` on the builder node.

Before creating any module atom, the shared verifier requires all of the
following:

- a matching full artifact SHA-256;
- a tar no larger than 32 MiB;
- one canonical manifest no larger than 1 MiB;
- no more than 512 modules and no BEAM larger than 4 MiB;
- unique, traversal-free entry names in the declared namespace;
- exact repository, source SHA, and build ID;
- exact declared module sizes and SHA-256 digests;
- a BEAM-internal module name that matches the entry and manifest;
- an artifact entry set equal to the manifest's added and changed sets;
- a classification consistent with its structural reasons.

The BEAM identity parser reads `Atom` or OTP 28 `AtU8` chunks as UTF-8 bytes.
It does not call `binary_to_atom/2`. Module atoms are created only after the
entire artifact passes verification and direct-load policy.

Module deletion, a missing baseline, NIF/native changes, dependency or
application-spec changes, assets, configuration, migrations, releases,
runtime-image changes, and Elixir/OTP/ERTS toolchain drift produce
`needs_rolling_replace`. Gate 10 may add more conservative classifications; it
must not weaken this list.

## Receipts, durability, and output

`forge_builds.id` is the build ID. The coordinator inserts a `running` row
before queueing work. It does not mark the row `complete` or the target `built`
until it has independently verified the artifact, written the digest-addressed
local cache, and completed the durable WAL-store write.

The response carries at most 8 KiB of redacted compiler output. Receipts store
only that bounded excerpt plus the full-output digest and reference. The full
log remains under `output/<build-id>.log`, mode `0600`, and the worker deletes
completed logs after `OPENAGENTS_FORGE_BUILD_OUTPUT_RETENTION_MS` (seven days
in the admitted profile). Do not expose full output through a web route.

## Local verification

Run the focused lane and standard repository gates:

```sh
mix test test/openagents/forge/build_artifact_test.exs
mix test test/openagents/forge/build_worker_test.exs
mix test test/openagents/forge/builder_test.exs
mix test test/openagents/forge/hot_loader_test.exs
mix test test/openagents/forge/boot_converge_test.exs
mix precommit
```

The focused coverage proves deterministic artifacts, JSON field rejection,
atomic publication, exact build-ID fencing, abandoned-attempt recovery,
digest-addressed durable storage, log retention, tar and BEAM identity checks,
and malformed-artifact refusal before loading. Staging must additionally build
the exact pushed commit with the real sidecar image and retain the resulting
build receipt, artifact digest, image digest, and redacted operator log proof.
