# Qualify an SCV in staging

Date: 2026-08-20

Status: Read-only qualification procedure

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
2. Build `ops/scv/images/opencode-core/Dockerfile` for `linux/amd64` with that
   SHA as `SCV_SOURCE_REVISION`.
3. Push the image to the dedicated immutable Artifact Registry repository and
   resolve its manifest digest.
4. Deploy or update the dedicated Cloud Run job by digest. Configure these
   nonsecret values:

   - `SCV_OBJECTIVE` with a bounded read-only inspection request.
   - `SCV_MODEL` with the admitted model identifier.
   - `SCV_REPOSITORY_REVISION` with the exact committed Git SHA.
   - `SCV_TIMEOUT_MS` and `SCV_HEARTBEAT_INTERVAL_MS` with bounded values.
   - `SCV_DIAGNOSTIC_LOGS=false`.

5. Map `OPENAI_API_KEY` from the staging secret at runtime. Do not print or
   persist its value.
6. Execute one job task and wait for its terminal state.

## Verify the execution

The Cloud Logging stream must contain these records for one run ID:

- `run_preparing`;
- `process_started`;
- at least one `resource_heartbeat` during a long-enough run;
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
