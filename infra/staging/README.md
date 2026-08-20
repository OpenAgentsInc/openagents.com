# Isolated staging infrastructure

This Terraform root creates the infrastructure boundary required by Gate 12.
It targets a dedicated Google Cloud project and refuses a project ID that
matches production. It does not create, read, or modify production resources.

## Topology

The configuration creates these staging-only resources:

- A custom VPC, private subnet, private DNS zone, Cloud NAT, and logged firewall
  rules.
- One private-IP Cloud SQL for PostgreSQL instance with its own connection
  budget, backups, and deletion protection.
- Three stable Compute Engine instances without public IP addresses. Each node
  has a fixed private address and a separate durable state disk for Ra, forge,
  build-queue, artifact-cache, and job data.
- Separate web, fleet, and deployer service accounts. A dedicated private
  deployer VM runs a minimal BEAM node and receives only the permissions to
  read, reset, and update metadata on staging instances. It does not start the
  application, join Ra, open HTTP, or connect to PostgreSQL, and it has no
  production project authority.
- Separate non-secret configuration placeholders for the web, fleet, and
  builder lanes, plus one Secret Manager resource per credential in the
  staging secret inventory. The deployer can read only the release cookie.
  Terraform never creates a secret version or stores a credential in state.
- Separate database URL secrets for the Cloud Run web lane and private Compute
  Engine fleet. The web URL selects the managed Cloud SQL Unix socket. The
  fleet URL selects a loopback TCP listener provided by a digest-pinned Cloud
  SQL Auth Proxy, which uses private IP and encrypted PostgreSQL transport.
- Separate buckets for forge artifacts, forge WAL, recordings, and evidence.
- One Artifact Registry repository for digest-addressed application and builder
  images. Full-SHA tags are immutable, and Terraform cannot delete the
  repository.

The instances start fenced. They do not run an application until an operator
assigns exact application and builder image digests and creates the required
staging-only secret versions during Gate 13.

After this boundary exists, use the
[immutable candidate runbook](../../docs/operations/staging-candidate-artifacts.md)
to publish the exact application image, builder image, release archive, SBOM,
and candidate manifest for Gate 13. Use the
[staging regression runbook](../../docs/operations/staging-regression.md) only
after the candidate and selected migration path are proven on this isolated
target. The later
[controlled-failure and soak runbook](../../docs/operations/staging-resilience.md)
must use the same boundary and must not begin before the regression passes.

## Prerequisites

You need these local tools:

- Google Cloud CLI with an active operator login and Application Default
  Credentials.
- Terraform 1.11 or later.
- `jq`.

Select a globally unique staging project ID that contains `stag`. Export the
production project ID only as a comparison value. The scripts never select it
as an action target.

```sh
export OPENAGENTS_STAGING_PROJECT_ID='openagents-staging-UNIQUE'
export OPENAGENTS_PRODUCTION_PROJECT_ID='PRODUCTION_PROJECT_ID'
export OPENAGENTS_STAGING_BILLING_ACCOUNT='000000-000000-000000'
export OPENAGENTS_STAGING_TF_STATE_BUCKET="$OPENAGENTS_STAGING_PROJECT_ID-openagents-tfstate"
read -r -s TF_VAR_database_password
export TF_VAR_database_password
printf '\n'
```

The database password is a Terraform ephemeral, write-only input and is not
stored in the plan or state. Generate it with an approved password manager,
keep it out of shell history, and use the same value when Gate 13 creates the
staging runtime secret. Never reuse a production credential.

Authenticate the Cloud CLI. Application Default Credentials are preferred for
Terraform because they can refresh during a long operation:

```sh
gcloud auth login
gcloud auth application-default login
```

If Application Default Credentials have expired, the wrapper uses a fresh,
process-only Cloud CLI access token. Terraform cannot renew that token, so each
`plan`, `apply`, or `output` command must complete within one hour. The wrapper
never writes the token to a plan, Terraform state, or command output.

## Provision the boundary

1. Review the project bootstrap targets without changing cloud state:

   ```sh
   ops/staging/bootstrap-project.sh check
   ```

2. Create the staging project, attach billing, and create the protected state
   bucket:

   ```sh
   ops/staging/bootstrap-project.sh --apply
   ```

3. Validate the Terraform configuration:

   ```sh
   ops/staging/terraform.sh validate
   ```

4. Commit the exact candidate and create a plan tied to that clean Git SHA:

   ```sh
   ops/staging/terraform.sh plan
   ```

5. Review the saved plan. Apply that exact plan only when every target belongs
   to the staging project:

   ```sh
   ops/staging/terraform.sh apply --apply
   ```

6. Validate the resulting boundary against both project identities:

   ```sh
   ops/staging/validate-isolation.sh
   ```

The validator verifies the separate `openagents_staging` database role and
writes a content-free receipt under
`.git/openagents/staging-isolation/<full-sha>.json`. Do not commit Terraform
plans, state, credentials, project inventory, IP addresses, or secret values.

## Clean up a disposable test run

Give each staging test run a unique lowercase identifier with 8 through 64
letters, numbers, and hyphens. Before the test harness uses a disposable
resource, register its database ID under that run:

```elixir
OpenAgents.StagingCleanup.register(run_id, :account, user.id)
OpenAgents.StagingCleanup.register(run_id, :repository, repository.id)
OpenAgents.StagingCleanup.register(run_id, :recording, recording.id)
OpenAgents.StagingCleanup.register(run_id, :machine, machine.id)
```

Set `OPENAGENTS_STAGING_CLEANUP_ENABLED=true` only for the staging release at
Gate 12 or later. The registration manifest is immutable. A resource can
belong to only one run, and the cleanup command does not infer targets from
names, timestamps, owners, or labels.

Preview content-free counts before deletion:

```sh
ops/staging/cleanup-run.sh gate14-20260820-0001 check
```

Apply the same bounded manifest once you confirm the counts:

```sh
ops/staging/cleanup-run.sh gate14-20260820-0001 --apply
```

The command targets a fixed staging fleet node through Identity-Aware Proxy.
It refuses the canonical repository, administrator accounts, online machines,
machines with queued or running work, active text turns or voice sessions, and
accounts that own an unregistered project, machine, or recording. It performs
all database deletions in one transaction and removes the manifest only after
the transaction succeeds. An interrupted or refused cleanup remains safe to
preview and retry.

The `repository` and `machine` kinds refer to product database records. This
command never deletes Compute Engine fleet instances, Cloud SQL, Artifact
Registry images, Terraform resources, or production data. Quiesce the test
harness before you apply cleanup so it cannot create new run data concurrently.

## Complete Gate 12

Gate 12 remains incomplete until the cloud apply, isolation validator, and a
live execution of the manifest-scoped disposable-run cleanup command are
proven. Do not populate
secrets, push an image, change DNS for `staging.openagents.com`, or deploy a
candidate as part of the infrastructure apply. Gate 13 performs those steps on
one exact, locally gated SHA after a separate review.

Do not run `terraform destroy`. Cloud SQL and the fleet instances have deletion
protection. Use a separate, reviewed decommission plan after staging evidence
is no longer required.
