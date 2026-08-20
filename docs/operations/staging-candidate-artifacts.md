# Publish an immutable staging candidate

Publish one exact, gated Git commit as two immutable images and one retained
artifact set before you migrate or deploy staging. The application image serves
traffic. The separate builder image contains the pinned compiler toolchain and
the exact release archive.

The staging Artifact Registry enables [immutable image tags](https://docs.cloud.google.com/artifact-registry/docs/docker/names).
Terraform also prevents deletion of the repository. The publication command
uses the full Git SHA as each tag, reads the registry manifest descriptor after
the push, and deploys by digest rather than by tag.

## Build inputs

The container build pins these external inputs:

- Elixir and Debian base images by OCI manifest digest.
- Debian and Debian Security packages to the dated 2026-08-03 snapshot.
- Hex by exact version.
- Rebar3 by exact release URL and SHA-512 checksum.
- Tailwind and esbuild by exact version and executable SHA-256 checksum.
- Application dependencies by `mix.lock` and Hex package checksums.
- Build timestamps with the commit timestamp through `SOURCE_DATE_EPOCH`.
- The deployment platform as `linux/amd64`, matching the staging fleet.

The packaged release contains a fixed non-distributed cookie placeholder. A
fleet node refuses to start distribution unless the staging runtime provides a
separate `RELEASE_COOKIE` with at least 32 bytes. Never put the staging cookie
in an image or artifact manifest.

Update base, snapshot, Hex, or Rebar3 pins in a dedicated dependency change.
Run the complete exact-SHA release gate and inspect the resulting SBOM before
you publish a candidate with new pins.

## Check publication prerequisites

Use a clean `main` worktree whose `HEAD` equals the locally fetched
`origin/main`. The exact commit must already have a complete local release-gate
receipt. Export only staging and comparison project identifiers:

```sh
export OPENAGENTS_STAGING_PROJECT_ID='openagents-staging-UNIQUE'
export OPENAGENTS_PRODUCTION_PROJECT_ID='PRODUCTION_PROJECT_ID'
export OPENAGENTS_STAGING_REGION='us-central1'

ops/staging/publish-candidate.sh check
```

The check is read-only. It verifies the project fence, active Google Cloud
authentication, exact local gate receipt, staging Artifact Registry format,
and immutable-tag setting. It does not build or push an image.

Do not continue if the check reports an expired login. Refresh both the Cloud
CLI and Application Default Credentials before the broader staging workflow:

```sh
gcloud auth login
gcloud auth application-default login
```

## Publish the candidate

Publish only after the isolated Gate 12 project and registry exist:

```sh
ops/staging/publish-candidate.sh --publish
```

The command performs these operations:

1. Repeats every preflight check and configures Docker authentication only for
   the staging registry host.
2. Builds the application and isolated forge-builder targets with the exact Git
   SHA, commit timestamp, and `linux/amd64` deployment platform.
3. Pushes only full-SHA tags into the immutable staging repository. If an
   earlier attempt already pushed a tag, it resolves and verifies that existing
   immutable image instead of moving the tag.
4. Reads and validates the registry-reported application and builder OCI
   manifest digests.
5. Pulls both digest references and verifies their OCI revision labels and
   packaged `OpenAgents.BuildInfo` revisions.
6. Extracts the exact release tar from the builder image.
7. Generates a CycloneDX SBOM from the digest-addressed application image by
   using the digest-pinned Syft image.
8. Writes and hashes one candidate manifest that binds the Git SHA, registry
   manifests, local image configurations, release archive, SBOM, release-gate
   receipt, Dockerfile, lockfile, migration-lineage map, application spec, and
   compiler toolchain.

The command never creates `latest`, environment, or branch tags. A failed
second image push can be resumed because the first full-SHA tag cannot move.
An unexpected existing local evidence directory fails closed unless it already
contains a valid manifest for the exact SHA.

## Review the retained artifact set

The command writes mode-`0600` evidence under:

```text
.git/openagents/staging-candidates/<full-sha>/
  candidate-manifest.json
  candidate-manifest.sha256
  openagents-<release-version>.tar.gz
  sbom.cdx.json
  sbom.cdx.json.receipt
```

The `.git` location prevents accidental commits. Copy the complete directory
to the staging-only versioned evidence bucket after Gate 12, and verify
`candidate-manifest.sha256` after upload. Do not upload Docker credentials,
Cloud CLI state, environment files, database URLs, or secret values.

Use only the `images.application.reference` and `images.builder.reference`
digest values from `candidate-manifest.json` in deployment configuration. A
tag is a review label, not deployment authority. Require every web revision,
fleet node, `/status` response, and deployment receipt to report the same Git
SHA and application manifest digest.

## Refuse or recover a candidate

Refuse publication if any of these conditions occurs:

- `HEAD` differs from `origin/main` or lacks an exact gate receipt.
- The target project is unmarked, equals production, or lacks immutable tags.
- A registry label or packaged build revision differs from the Git SHA.
- A registry manifest, release, SBOM, or input digest has an invalid shape.
- The generated manifest does not validate before its atomic move.

If publication fails after an immutable tag exists, preserve the local logs and
rerun the same exact commit. Do not delete or move the tag. If the existing
image fails identity verification, stop and investigate the registry as a
security incident. Never recover by publishing a different commit under the
same SHA tag.
