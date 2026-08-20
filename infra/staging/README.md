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
- Separate buckets for forge artifacts, forge WAL, recordings, and evidence.
- One Artifact Registry repository for digest-addressed application and builder
  images.

The instances start fenced. They do not run an application until an operator
assigns exact application and builder image digests and creates the required
staging-only secret versions during Gate 13.

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

Authenticate both the Cloud CLI and Terraform provider:

```sh
gcloud auth login
gcloud auth application-default login
```

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

## Complete Gate 12

Gate 12 remains incomplete until the cloud apply, isolation validator, and
manifest-scoped disposable-run cleanup command are proven. Do not populate
secrets, push an image, change DNS for `stage.openagents.com`, or deploy a
candidate as part of the infrastructure apply. Gate 13 performs those steps on
one exact, locally gated SHA after a separate review.

Do not run `terraform destroy`. Cloud SQL and the fleet instances have deletion
protection. Use a separate, reviewed decommission plan after staging evidence
is no longer required.
