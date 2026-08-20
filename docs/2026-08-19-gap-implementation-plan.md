# Gap implementation plan: full port of Sarah into openagents.com

**Date:** 2026-08-19  
**Source:** `~/work/sarah/docs/audits/2026-08-19-openagents-com-full-port-gap-analysis.md`  
**Status:** in progress — this document is updated as work lands.

## Verdict

The code is across. What remains is commissioning: the test signal, runtime
configuration, clustering, routing and LiveViews, schema completeness, CI, and
the production cutover. The first job is to make `mix test` honest again.

## Phases

### Phase A — Restore the test signal (serial, blocks all else)

1. Fix the partial `visitors` unique index so `Conversations.ensure_visitor/1`
   can use `[:browser_key_hash]` as an `ON CONFLICT` arbiter.
2. Re-run the full test suite, triage the survivors, and delete the
   `exclude: [:skip]` plus `@moduletag :skip` scaffolding as tests pass.

### Phase B — Commission the runtime (parallel lanes)

3. Port the missing `config/` keys: the tool catalog, inference `provider`,
   `openai_model`, shadow programs, semantic index, recall backends, voice
   providers, experience/graph memory, GitHub API, and forge flags. Replace the
   soft `Application.get_env(:openagents, :tools, [])` default with
   `fetch_env!`.
4. Restore `OpenAgents.Application` startup: `Release.migrate/0`,
   `Persona.SourceManifest.load!/install!`, `ProgramArtifacts.install!/0`,
   `Voice.Config.validate_boot!/0`, `Tools.Embeddings.warm/0`,
   `Changelog.Backfill.boot/0`, and real Horde/Ra children. Replace the
   `cluster/registry.ex` and `cluster/dynamic_supervisor.ex` shims with real
   `Horde.Registry` and `Horde.DynamicSupervisor`.
5. Close the schema gaps: add `voice_tool_steps` and `voice_response_contexts`
   tables; fix `forge_pushes` / `forge_push_receipts`; add `forge_deploys.nodes`;
   verify the six `allow_*_privacy_deletion` migrations are present.
6. Port `INVARIANTS.md` from Sarah, rewrite `RELEASE-004` to dogfood the forge,
   rewrite `UI-003` to record the basecoat transitional exception, add the
   layering boundary from transcript 270, disambiguate the duplicate
   `DEGRADE-001`, and revert the `forge/targets.ex` `commit_store` test-only
   relaxation.

### Phase C — Surfaces (depends on B)

7. Port the 12 missing LiveViews verbatim, carrying `assets/vendor/basecoat/`
   across with the narrow import discipline. Reconcile `ui_gallery_live` with the
   existing `/components` gallery.
8. Mount `ControllerSocket` in `endpoint.ex`; route the 7 orphaned controllers.
9. Route `forward "/git", OpenAgents.Forge.GitHTTP`; the literal-owner code
   views; `/changelog`, `/status`, `/leaderboard`, `/admin/*`, data-rights
   exports; and `/api/inference/proxy`.

### Phase D — Dogfood the forge as CI

10. Port `ops/ci/gate.sh` and `.githooks/pre-push`. Move openagents.com to
    forge-canonical; demote GitHub to a MirrorWatch mirror. Run the gate on the
    forge's build lane.

### Phase E — Cutover

11. Data migration rehearsal against a restored Sarah snapshot; keep
    `changelog_entries` and `forge_*` receipt identifiers intact.
12. Fleet cutover, WAL continuity, DNS/MirrorWatch repoint, and Sarah
    deprecation.

## Current cycle

Phase A is active. The first commit is the one-line `visitors` index fix; the
first validation is `mix test` with all 893 previously skipped Sarah tests
un-excluded.
