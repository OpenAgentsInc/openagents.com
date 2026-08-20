# Qualify an SCV in staging

Date: 2026-08-20

Status: Read-only qualification procedure; first shared-project proof passed

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
environment, `read_only` permission profile, exact source SHA, successful exit
status, bounded duration, resource measurements, event counts, token totals,
and no output truncation. Verify the deployed job uses the dedicated service
account and contains no prohibited environment or secret references.

Treat a successful execution as an environment qualification receipt only. Do
not call it an isolated-staging pass or enable writes. Before an SCV can write,
add the durable coordinator and worker protocol, process-tree or cgroup
enforcement, run-scoped inference grants, persistent per-effect barriers,
artifact storage, cancellation, and the isolated Forge staging lane.

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
