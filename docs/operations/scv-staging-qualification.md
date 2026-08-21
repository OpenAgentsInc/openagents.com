# Qualify an SCV in staging

Date: 2026-08-20

Status: OpenCode read-only proof passed; Codex individual-operator proof pending

Use this procedure to prove the first complete SCV image in staging. This lane
qualifies one OpenCode-driven SCV run. It does not admit repository writes,
candidate pushes, Forge promotion, autonomous deployment, or production use.

## Safety boundary

The current `staging.openagents.com` service and production resources share the
`openagentsgemini` Google Cloud project. This does not satisfy the isolated
staging topology required for SCV autonomy. Until an isolated project exists,
run this qualification as a separate Cloud Run job with all of these controls:

- Use a dedicated service account with no project-level roles.
- Grant the service account access to only the staging OpenAI secret.
- Do not attach a database, VPC connector, GitHub credential, Forge credential,
  release cookie, deployment credential, or cloud API credential.
- Deploy an immutable image digest from a dedicated immutable staging
  repository.
- Set `OPENAGENTS_RUNTIME_ROLE=scv`, `OPENAGENTS_ENVIRONMENT=staging`, and
  `SCV_PERMISSION_PROFILE=read_only`.
- Run one task with no retries and a bounded timeout.

The image starts only the SCV worker supervision tree. The worker admits the
`opencode` driver and `opencode-core` environment, streams versioned JSON events
to Cloud Logging, writes one terminal result, and exits.

## Build and deploy

1. Commit and push the candidate. Record the exact Git SHA.
2. Run `ops/scv/images/build-opencode-core-cloud.sh` against the clean commit.
   The script builds `ops/scv/images/opencode-core/Dockerfile` on native
   `linux/amd64` infrastructure with the SHA as
   `OPENAGENTS_BUILD_REVISION`.
3. Push the image to the dedicated immutable Artifact Registry repository and
   resolve its manifest digest.
4. Deploy or update the dedicated Cloud Run job by digest. Configure these
   nonsecret values:

   - `SCV_OBJECTIVE` with a bounded read-only inspection request.
   - `SCV_MODEL` with the admitted model identifier.
   - `SCV_REASONING_EFFORT=low` for the production-code-capable SCV baseline.
   - `SCV_REPOSITORY_REVISION` with the exact committed Git SHA.
   - `SCV_TIMEOUT_MS` and `SCV_HEARTBEAT_INTERVAL_MS` with bounded values.
   - `SCV_DIAGNOSTIC_LOGS=false`.

5. Map `OPENAI_API_KEY` from a specific enabled numeric version of the staging
   secret at runtime. Do not use `latest`, print the value, or persist it.
6. Execute one job task and wait for its terminal state.

## Verify the execution

The Cloud Logging stream must contain these records for one run ID:

- `run_preparing`;
- `process_started`;
- at least one `heartbeat` during a long-enough run;
- normalized `opencode_event` records;
- `process_finished`;
- `run_finished`;
- one `openagents.scv.worker.result.v1` terminal result.

Verify that the result reports the `opencode` driver, `opencode-core`
environment, `openai/gpt-5.6-luna` model, `low` reasoning effort, `read_only`
permission profile, exact source SHA, successful exit status, bounded duration,
resource measurements, event counts, token totals, and no output truncation.
Verify the deployed job uses the dedicated service account and contains no
prohibited environment or secret references.

Treat a successful execution as an environment qualification receipt only. Do
not call it an isolated-staging pass or enable writes. Before an SCV can write,
add the durable coordinator and worker protocol, process-tree or cgroup
enforcement, run-scoped inference grants, persistent per-effect barriers,
artifact storage, cancellation, and the isolated Forge staging lane.

## Qualify the individual-operator Codex driver

Run this procedure only after an administrator connects an individual Codex
account at `/admin/scv/accounts` and the account shows **Ready**. Do not add a
service account until this path passes.

1. Deploy the exact candidate SHA and immutable image digest to every staging
   fleet node.
2. Confirm that the connected account advertises `gpt-5.6-luna` and at least
   one of the admitted reasoning efforts, `low` or `none`.
3. Resolve the public repository, its node-local Forge storage key, and the
   exact candidate SHA. Do not use a mutable branch name for the run.
4. Call `OpenAgents.SCV.CodexRuns.start/5` on one fleet node with the account
   ID, repository record, exact SHA, bounded read-only objective, and optional
   issue ID.
5. Observe `/status` while the SCV runs. The stream must advance through the
   Codex runtime, session, turn, tool or report, and terminal persistence
   phases without showing the objective, repository path, command, output,
   account identity, or credential data.
6. Call `OpenAgents.SCV.CodexRuns.await/2` with a bounded timeout. Require a
   terminal `succeeded` row, a nonempty `openagents.scv.report.v1` report, its
   SHA-256 digest, exact repository SHA, Codex thread and turn IDs, event count,
   usage, and resources.
7. Query `scv_run_events` for that run. Require `driver_started`,
   `driver_session_started`, `turn_started`, at least one activity or message
   event, `turn_finished`, and `run_finished`.
8. Confirm that no disposable workspace or temporary `CODEX_HOME` remains and
   that the connected account remains **Ready**.
9. Scan the bounded event payloads, application logs, and public status
   response for credential patterns and raw protocol content. Any match fails
   qualification.

This procedure qualifies only read-only investigation and report persistence.
It does not grant write, push, issue-transition, Forge promotion, deployment,
or production authority.

## First qualification receipt

The first shared-project qualification passed on 2026-08-20:

| Field | Value |
| --- | --- |
| Source revision | `09a775b83fa05b6a92854b0ad1f7b5c23b3aee88` |
| Build | `9721075d-ed17-491c-af9a-85be8f46bf52` |
| Image digest | `sha256:ee2a74660faa6137e4021a2870380f5977796d33ca9dcaabcb0b958f35e0e36b` |
| Job execution | `openagents-scv-staging-wrppq` |
| SCV run | `db8a6849-1e59-41fb-ba7d-461c9a4fa4a3` |
| Result | `succeeded` in 11,008 milliseconds with two completed read calls and no output truncation |

Cloud Logging received lifecycle events, five two-second heartbeats, eight
normalized OpenCode events, resource measurements, and the terminal worker
result before the container exited with status `0`. This receipt proves the
read-only image and event path. The safety limitation above remains in force.

After the job pinned the provider secret to its numeric version, generation 2
passed as execution `openagents-scv-staging-9gdhz`. SCV run
`cc749000-8961-44a5-8d98-6569f6b1b925` completed in 11,207 milliseconds with
two read calls, eight normalized events, 754,118,656 bytes of peak RSS, 45
resource samples, no sampling errors, and no output truncation. This second
receipt proves the currently deployed job configuration.

## GPT-5.6 Luna staging receipt

Cloud Build `655a2fe6-8173-4686-9533-f3a1733942b0` built source revision
`c7175ed8a8781ea1aab7d204623a28ac45a70bc1`. Artifact Registry resolved the
worker image to
`sha256:156ff9f51e955d03b4795af8e2bb190a6c4f9962cc7942a6dcc0586e9b48b0a9`.
The control-plane, parity, production-readiness, and staging SCV jobs all use
that digest with `SCV_MODEL=openai/gpt-5.6-luna` and
`SCV_REASONING_EFFORT=low`.

Parity execution `openagents-scv-parity-audit-p5mkz` completed successfully as
SCV run `0f13d278-02aa-47cd-bc07-3bdcd2fd6135`. The OpenCode process ran for
58,553 milliseconds and emitted 62 normalized events. It completed 9 `glob`,
9 `grep`, and 22 `read` calls, recorded 688,361,472 bytes of peak RSS, and
reported no sampling or output truncation.

Cloud Logging stored the terminal result as
`openagents.scv.worker.result.v1` and the 8,645-byte report as three ordered
`openagents.scv.report.chunk.v1` JSON records. Both the initial
`run_preparing` event and terminal result recorded the exact model and reasoning
effort. This receipt qualifies the Luna model-selection, live event, bounded
report, and terminal-result paths in the shared staging project. It does not
admit repository writes or count the report findings as claimed or completed
issues.
