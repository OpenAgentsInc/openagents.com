# Sarah persona source manifests

`sarah.v1.sources.json` is the immutable, status-labeled input ledger for the
first Sarah persona. It records where each historical source came from, the
exact repository revision and SHA-256 content digest reviewed, what the source
may inform, and what it may never authorize.

The manifest is not runtime authority. Current application safety, scope,
capability, and data contracts always win. Sarah does not fetch the OpenAgents
archive at runtime.

The manifest records that separation explicitly: `current_runtime_contracts`
are binding and resolve from the deployed Sarah release, while historical
sources are pinned evidence used only to author reviewed persona artifacts.

## Updating the canon

Never edit an admitted manifest in place while keeping its ID.

1. Resolve the upstream source to an immutable repository revision and verify
   the exact path and content digest.
2. Classify its status before extracting any identity, voice, product, role, or
   evaluation material.
3. Record explicit admitted uses and exclusions. Founder speech, drafts,
   retired product material, and special performances are not ordinary Sarah
   voice or current capability truth.
4. Create a new manifest and persona revision. Calculate the canonical manifest
   digest with `Sarah.Persona.SourceManifest.calculate_digest/1` and admit that
   digest in code during the same reviewed change.
5. Add or update validation and containment tests, the persona evaluation
   corpus, `INVARIANTS.md`, and release notes.
6. Run the provider-backed regression and verify its revision-bound report as
   described in `docs/PERSONA_REGRESSION_EVALS.md`. A candidate digest is not
   admitted without a passing report.
7. Keep the old manifest available for turns/releases that already cite it.

Episode numbers are navigation hints, not source identity. The current Episode
263 catalog entry conflicts with its file content, so that source remains
quarantined. The actual final Omega Alpha transcript is pinned explicitly at
`docs/transcripts/26X-omega-alpha.md` in the OpenAgents repository.

## Runtime artifact

`sarah.v1.md` is the first admitted runtime persona. One SHA-256 covers its
first-conversation greeting and protected identity/voice instructions. The
application validates and installs it at boot, then
`Sarah.Context.Composer` places it above host safety, surface truths, the
admitted `general_collaborator.v1` role, captured capabilities, and any bounded
untrusted recall. Provider adapters receive the result and contain no separate
Sarah prompt.
