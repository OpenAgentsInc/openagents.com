# Integration hardening and staging readiness recommendations

Date: 2026-08-20

Status: In progress; Gates 0–11 complete locally, Gate 12 cloud and live cleanup proof pending

## Outcome

Make `openagents.com` one coherent public AGPL application, deploy it safely to
staging, and prove its behavior there before any production work begins.

The complete Sarah product is intentionally part of this repository. The
remaining work is not to restore a private-service split. The work is to make
the merged application internally consistent, secure its authority and data
boundaries, finish the deployment system, remove obsolete source-project
assumptions, and establish reproducible staging evidence.

Production is out of scope. Do not deploy production traffic, mount production
credentials, repoint production DNS, or promote a production fleet target as
part of this plan.

## Executive recommendations

Complete the work in this order:

1. Establish one accurate architecture and terminology baseline.
2. Repair documentation, invariants, configuration, and generic runtime names.
3. Harden authentication, repository scoping, data ownership, and administrative
   authority.
4. Consolidate the UI, icon, Markdown, and dependency stacks.
5. Harden the forge build and deployment lanes before enabling hot loading.
6. Create an isolated staging environment that represents the intended runtime.
7. Run the complete staging regression and failure-injection matrix.
8. Hold the staging release through a soak period and close every unexplained
   error before discussing production.

Treat each numbered gate in this document as blocking. A later gate cannot make
an earlier failure acceptable.

## Ground rules

- Keep Sarah-specific identity, persona, voice, and evaluation material public
  under the AGPL license.
- Use `OpenAgents` for application infrastructure and Sarah only for the agent,
  persona, or behavior that is specifically Sarah's.
- Keep direct provider credentials on the server. The browser must never receive
  an OpenAI key, forge operator token, machine token, or recording key.
- Keep hosted CI disabled. Run checks on owned machines, local hooks, and owned
  deployment infrastructure.
- Keep all new deployment capabilities disabled by default. Enable them in
  staging only after their preceding gates pass.
- Treat PostgreSQL rows and immutable receipts as authority. Treat LiveView,
  PubSub, caches, and status pages as projections.
- Preserve historical migrations. Correct live schema problems with new
  migrations instead of rewriting migrations that may already have run.
- Use the completed Issues and Projects coverage work as an input to this plan.
  Do not duplicate that work or weaken its assertions to make a gate pass.
- Record every staging result against an exact Git SHA, image digest, artifact
  digest, migration version, and staging revision.

## Gate 0: Freeze and measure the baseline

Create a reliable starting point before changing architecture or infrastructure.

1. Record the current Git SHA and confirm the worktree is clean.
2. Run `mix precommit` on an owned test machine.
3. Run `mix test --only cluster` as a separate stage.
4. Port or recreate the missing Node tests for voice state, recording, and
   browser hooks, and add an explicit package test command.
5. Run those JavaScript tests as a required stage.
6. Run `mix test --cover` and merge its result with the separate cluster stage.
7. Record compile warnings, test exclusions, flaky tests, and test duration.
8. Build a release and run its startup path against a disposable database.
9. Save the result as a local, content-free gate receipt tied to the SHA.

The baseline at `d5679e8` recorded 1,218 default tests passing with 9 cluster
tests excluded, all 9 cluster tests passing separately, no compile warnings, no
hidden skips, and 83.14% line coverage before merging cluster coverage. Keep
that result as historical evidence, but rerun the complete gate for each
candidate. The implementation status below supersedes the historical blockers.

### Gate 0 implementation status

Completed on 2026-08-20:

- Added Node suites for the voice admission state, media-resource cleanup,
  recording admission, upload ordering, finalization, failure containment, and
  generation fencing.
- Added `npm test` in `assets/package.json` and the `mix assets.test` alias.
- Added `mix assets.test` to `mix precommit`, so the standard repository gate
  fails when browser-side voice behavior regresses.
- Removed the remaining test-compilation warnings and made
  `mix test --warnings-as-errors` part of `mix precommit`.
- Replaced Ra's captured session-query functions with stable
  module-function-argument descriptors. The cluster suite now runs under
  coverage without a peer crashing on an instrumented function identity.
- Merged the default and cluster coverage exports locally. The completed
  baseline result is 83.59% from 1,222 default tests and all 9 cluster tests.
- Added `ops/ci/coverage.sh` to discard stale exports, run both suites with
  warnings as errors, collect execution from distributed peers, merge both
  exports, and enforce an initial 83% floor. Raise the floor as direct recovery
  and release-path tests land. Do not lower it to admit a candidate.
- Added coverage-aware peer shutdown so peer execution flushes back to the main
  coverage node before a test stops the peer.
- Added direct `RaBootstrap` decision tests for healthy, phantom, join, form,
  and wait outcomes instead of treating cluster execution as indirect proof.
- Added `ops/ci/release-smoke.sh`. It requires an explicitly acknowledged
  disposable PostgreSQL URL, generates throwaway runtime secrets, builds the
  production assets and release, starts the real release, waits for the bounded
  `/healthz` response, and terminates the release cleanly.
- Fixed `mix assets.deploy` to compile Phoenix's colocated assets before
  Tailwind resolves them. The release smoke exposed this production-only build
  failure and now passes against a fresh PostgreSQL 18 container.
- Added `ops/ci/baseline.sh` to require a clean worktree, run precommit, merged
  coverage, and the production release smoke without retries, recheck Git
  identity and cleanliness, and atomically write a content-free receipt under
  `.git/openagents/gate-receipts/`.
- Ran the complete baseline on clean commit
  `d9ffc65f5cdd961cf228146a95e9d651e14692d2`. It passed without automatic
  retries in 76 seconds: 15 JavaScript tests, 1,222 default Elixir tests, all 9
  separately executed cluster tests, 83.59% merged coverage, and the packaged
  production release smoke against a disposable PostgreSQL 18 database.
- Inspected the resulting mode-`0600`, content-free local receipt at
  `.git/openagents/gate-receipts/d9ffc65f5cdd961cf228146a95e9d651e14692d2.json`.
  The receipt identifies the exact commit, stage results and durations, bounded
  test counts, coverage, and zero automatic retries; it contains no logs,
  database URLs, hostnames, credentials, or product content.

Gate 0 is complete. Run `ops/ci/baseline.sh` again on every subsequent release
candidate; a receipt for one SHA is never evidence for another.

Do not use the current green suite as evidence for untested code. The updated
coverage audit records strong Issues and Projects coverage and the defects it
found. Recovery workers and release-only entry points still need direct
evidence.

**Exit criteria:** The team has one reproducible baseline with no hidden test
filters and a named owner for every known failure or exclusion.

## Gate 1: Define the integrated architecture

Write one architecture document that describes the application that now exists.
It should replace the conflicting public-shell, private-service, mock-chat, and
partial-port narratives.

The architecture document should state these decisions:

- `openagents.com` owns the browser UI, Sarah persona, conversation and turn
  lifecycle, provider orchestration, tools, memory, delegated work, voice,
  machines, issues, projects, forge, and administrative surfaces.
- Provider adapters are replaceable server-side boundaries. Direct OpenAI use
  is an adapter choice, not an application-wide dependency.
- PostgreSQL is the durable product authority.
- The forge's Git and deployment planes are separate concerns inside one
  application namespace.
- Public, authenticated, operator, machine, and internal-service routes have
  distinct authorization rules.
- Direct BEAM load, relup, and rolling replacement are different deployment
  strategies with different safety requirements.

Add focused architecture decision records for:

- The full public AGPL integration.
- Sarah as a persona within the `OpenAgents` application.
- Direct provider integration and credential boundaries.
- GitHub identity and access-token retention.
- Basecoat and the application UI component system.
- The staging and eventual production fleet topology.
- Forge-canonical source control and GitHub mirroring, if that remains the
  intended cutover.

### Gate 1 implementation status

Completed on 2026-08-20:

- Added `docs/architecture.md` as the source of truth for product ownership,
  durable authority, provider and trust boundaries, forge planes, deployment
  strategies, staging topology, and the source-control transition.
- Classified public, authenticated, operator, machine, internal-service, and
  Git principals. The architecture names Gate 6's exhaustive route ledger as
  the enforcement proof instead of claiming that route placement is enough.
- Added seven focused decision records for the complete public integration,
  Sarah's persona boundary, provider credentials, encrypted GitHub token
  retention, the Basecoat component system, isolated staging topology, and the
  proof-gated forge-canonical cutover.
- Recorded GitHub as the accurate temporary canonical remote during hardening.
  The forge cutover cannot occur until its Git, mirror, artifact, rollback, and
  recovery gates pass together with updated contributor automation.

**Exit criteria:** A contributor can explain the application and its trust
boundaries without reading a superseded plan or another repository.

## Gate 2: Remove stale names and references

Apply a semantic naming rule instead of a blind search-and-replace.

### Keep Sarah references where they are accurate

Keep Sarah in names that identify Sarah-specific behavior or data, such as:

- Persona artifact IDs and source manifests.
- Persona evaluation corpora.
- User-visible Sarah identity and voice copy.
- Sarah-specific role or behavior revisions when the identity is part of the
  artifact contract.

### Rename generic application infrastructure

Rename generic infrastructure that still carries a source-project name. Review
at least these areas:

- `OpenAgents.Sarah.Supervisor`.
- `sarah_live_view`, `sarah_html`, and `sarah_html_helpers`.
- `assets/css/sarah.css` and comments that call the whole application Sarah.
- Generic test cases and helpers named `SarahConnCase`, `SarahDataCase`, or
  `SarahChannelCase`.
- `sarah_source_dir` and other generic application configuration keys.
- `/tmp/sarah_*` and `/var/lib/sarah/*` runtime paths.
- Forge defaults that name the `sarah` repository instead of
  `OpenAgentsInc/openagents.com`.
- Builder sidecar names, queue paths, WAL paths, and artifact paths.
- Generic user-agent strings and internal service labels.

Prefer names such as `OpenAgents.RuntimeSupervisor`, `openagents_live_view`,
`openagents.css`, `source_repo_dir`, and `/var/lib/openagents`. Do not rename a
Sarah persona artifact to OpenAgents if that would erase its actual identity.

### Establish an allowed-reference check

Add a repository check that searches source, tests, configuration, and docs for
`Sarah`, `sarah`, old filesystem roots, old application atoms, and retired
service domains. Maintain a small allowlist of intentional Sarah-specific
locations. Fail the check on every unclassified match.

### Gate 2 implementation status

Completed on 2026-08-20:

- Renamed the generic runtime supervisor to `OpenAgents.RuntimeSupervisor` and
  the generic web macros to `openagents_live_view`, `openagents_html`, and
  `openagents_html_helpers`.
- Renamed the product component module to `OpenAgentsWeb.UI` and the style pack
  to `assets/css/openagents.css`. Updated the catalog, component tests, Basecoat
  notes, and contributor instructions with the new names.
- Consolidated lifted connection and data tests onto `OpenAgentsWeb.ConnCase`
  and `OpenAgents.DataCase`, renamed the shared channel case, removed unused
  lifted factory and fixture stubs, and removed duplicate lifted error tests.
- Replaced inherited runtime, Ra, forge, WAL, build-sidecar, test-peer, and
  coding-workspace names with OpenAgents names. The default forge repository is
  now the public `OpenAgentsInc/openagents.com` repository, represented as
  `openagents.com` in repository-scoped records and URLs.
- Extended repository validation to admit bounded domain-style names without
  admitting consecutive dots, trailing dots, path separators, uppercase
  names, or unconfigured repositories.
- Changed generic GitHub user agents, machine wire schemas, network and
  changelog schemas, observability schemas, and Git authentication labels to
  OpenAgents names.
- Versioned machine-token and voice-recording authenticated encryption. New
  ciphertext uses OpenAgents AAD and version 2; reads retain explicit support
  for legacy version-1 Sarah ciphertext so the rename does not strand existing
  encrypted staging data.
- Added `ops/ci/reference-check.sh` and a documented allowlist. `mix precommit`
  now rejects unclassified Sarah names, retired service domains, inherited
  filesystem roots, source-project symbols, builder labels, and repository
  names. The allowlist preserves persona language, stable behavior and data
  contracts, persona artifacts, historical migrations, and named historical
  documents.
- Verified the change with 15 browser tests, 1,222 default Elixir tests, and all
  9 isolated cluster tests, with zero failures.

**Exit criteria:** Every remaining Sarah reference is intentional, documented,
and specific to Sarah rather than inherited infrastructure.

## Gate 3: Reconcile all documentation and invariants

Documentation currently describes several incompatible generations of the
application. Make documentation a release gate rather than a historical
accident.

### Repair the top-level narrative

- Rewrite `README.md` to describe the integrated application accurately.
- Remove the clean-room statement because the repository intentionally contains
  the integrated product implementation.
- Replace DaisyUI references with the current Basecoat and OpenAgents style
  system.
- Separate working features, staging-only features, disabled features, and
  planned features. Do not describe a disabled or incomplete deploy lane as
  production-ready.
- State the AGPL licensing decision and identify vendored third-party licenses.

### Retire or rewrite obsolete plans

- Mark `docs/chat-inference-plan.md` as superseded or remove it after preserving
  any still-valid provider-boundary requirements.
- Convert `docs/sarah-integration-plan.md` into a historical migration record or
  replace its stale status and skipped-test counts.
- Close or archive `docs/2026-08-19-gap-implementation-plan.md` after moving each
  unresolved item into the current hardening plan.
- Update `docs/component-library.md` and
  `docs/issues-projects-ui-roadmap.md` for Basecoat, `OpenAgentsWeb.UI`, and the
  actual component catalog.
- Update `docs/github-auth-plan.md` after deciding whether GitHub access tokens
  remain stored.
- Keep the test coverage audit as a dated measurement. Add a later audit instead
  of rewriting the original numbers.

### Repair the invariant ledger

Review every invariant in `INVARIANTS.md` against code, schema, configuration,
tests, and documentation.

- Give every invariant a unique ID. Resolve the duplicate `DEGRADE-001` entries.
- Correct inherited or nonexistent paths such as `priv/openagents` and
  `style-openagents.css`; use the generic `OpenAgentsWeb.UI` module established
  by Gate 2.
- Resolve the contradiction between discarding GitHub tokens and the current
  encrypted-token storage path.
- Distinguish implemented invariants from proposed invariants. A proposed
  contract cannot claim current evidence.
- Port, recreate, or remove references to missing evidence documents.
- Ensure each current invariant names at least one executable test or a concrete
  manual release proof.
- Remove references to modules, controllers, routes, and admin recording
  behavior that no longer exist.

### Add documentation validation

Add an owned local check that:

- Verifies relative Markdown links and referenced local files.
- Detects duplicate invariant IDs.
- Detects banned obsolete terms such as DaisyUI and retired service domains.
- Detects absolute developer-specific paths such as `~/work` and
  `/Users/<name>`.
- Confirms that every evidence file named by `INVARIANTS.md` exists.

**Exit criteria:** Every current document agrees on product ownership,
components, authentication, deployment maturity, and staging status, and all
local references resolve.

**Gate 3 status (2026-08-20): complete.**

- Rewrote `README.md` around the integrated AGPL application and separated
  locally implemented, disabled/staging-only, planned, and production-prohibited
  capabilities. It now names the Basecoat/OpenAgents component system and
  vendored license locations.
- Converted the chat service split, source integration, and original gap plan
  into closed historical records. Updated the component inventory, issue/project
  UI roadmap, API assessment, API work record, GitHub token contract, and BEAM
  deployment maturity narrative without rewriting the dated coverage audit.
- Reconciled `INVARIANTS.md`: all 72 IDs are unique, every entry is explicitly
  current or proposed, all 70 current entries map to executable repository-owned
  proofs, artifact/style paths match the tree, retained encrypted GitHub tokens
  are documented consistently, and missing admin recording routes are no longer
  claimed.
- Removed the dead operator recording playback affordance whose URL had no
  controller or route; the current operator surface exposes bounded recording
  metadata only. Added `.dockerignore` because RELEASE-002 named a build-context
  safeguard that was absent.
- Added `ops/ci/docs-check.exs` to `mix precommit`. It verifies relative Markdown
  links, current-document terminology, developer-local paths, invariant IDs and
  statuses, proof-index coverage, evidence paths, and referenced modules.
- Verified 21 Markdown files with the documentation gate, 14 focused operator
  LiveView tests, 15 browser tests, and 1,222 default Elixir tests with zero
  failures. The nine distributed tests remain isolated for the owned baseline
  gate and were unchanged by this documentation gate.

## Gate 4: Harden dependencies, assets, and the component system

### Complete the Markdown parser migration

At the initial audit, the integration plan said MDEx replaced Earmark while the
application still depended on and called the retired parser. Gate 4 replaces
that implementation with MDEx and verifies sanitization, maintained status,
and output compatibility.

Whichever parser remains must pass tests for:

- Raw HTML refusal.
- Script and event-handler removal.
- Unsafe URL scheme rejection.
- Bounded nesting, input size, and output size.
- Code blocks, lists, links, tables, and malformed Markdown.
- Stable rendering for streamed and persisted assistant text.

Remove the unused parser and update every related document in the same commit.

### Complete UI consolidation

- Choose the final generic module name: preferably `OpenAgentsWeb.UI` once the
  source-project migration is complete.
- Move all product surfaces onto that component system.
- Remove the generated compatibility component module after migrating every
  caller. Do not recreate a parallel component surface.
- Remove DaisyUI aliases and compatibility tokens after every surface has
  migrated.
- Use one documented icon policy: Apps SDK icons are preferred, and Heroicons
  remains the deliberate fallback when the preferred set has no suitable
  glyph. Do not add a third source. Inventory fallback uses so they stay
  exceptional rather than becoming the default.
- Keep Basecoat imports per component and do not load Basecoat JavaScript.
- Reject any component library that emits generic component selectors into the
  Tailwind utilities layer or otherwise outranks the application component
  layer. Verify cascade behavior, not only dependency names.
- Keep the product deliberately dark-only for staging. Hide or remove the theme
  toggle while it has no visual effect; treat a light palette as a separate,
  owner-approved design project.
- Treat any style-pack rename as a controlled palette migration. Preserve the
  primitive token contract, run visual regression checks, and do not mistake a
  load-bearing palette file for a cosmetic filename.
- Make the component catalog the executable inventory of supported primitives.

### Audit dependencies and licenses

- Remove unused dependencies and stale lock entries.
- Run Hex retirement and vulnerability checks on owned infrastructure.
- Generate a dependency and license inventory for the release artifact.
- Verify the Basecoat, icon, font, and brand-mark attribution files.
- Pin every Git dependency to an immutable tag or revision.
- Build an SBOM for the staging image and retain it with the staging evidence.

**Exit criteria:** The application has one Markdown parser, one component
system, one documented two-tier icon policy, no nonfunctional theme control, no
unexplained dependency, and complete license records.

**Gate 4 status (2026-08-20): complete.**

- Replaced the retired parser with MDEx and removed its stale lock entry.
  `OpenAgents.Markdown` disables dangerous rendering, applies an exact Ammonia
  allowlist, normalizes links, and independently bounds input, syntax-tree
  nesting, output, and escaped fallback size. The focused suite covers raw
  HTML, scripts and handlers, unsafe schemes, supported structures, malformed
  input, streaming stability, and every limit.
- Consolidated all web imports and product surfaces on `OpenAgentsWeb.UI`.
  Added form-aware input, heading, table, and list primitives; removed the
  generated compatibility module; and made `/components` an executable
  inventory of every public component.
- Removed the browser theme script, theme control, theme selectors, and retired
  palette aliases. The palette remains deliberately dark-only. The Node suite
  now compiles Tailwind and proves that Basecoat geometry precedes the
  OpenAgents style pack and that all eight governed button variants survive the
  cascade.
- Migrated current glyph uses to the preferred vendored Apps SDK set. Retained
  Heroicons only as the owner-approved second tier, pinned it to immutable
  revision `0435d4ca364a608cc75e2f8683d374e55abbae26`, and recorded an empty
  fallback-use inventory in `docs/ICONS.md`.
- Added a direct-dependency purpose and license ledger, release notices for
  Basecoat, icons, fonts, and the brand mark, and digest-pinned Syft SBOM
  tooling. `mix precommit` now runs Hex retirement, MixAudit vulnerability, and
  unused-lock checks. All three checks pass locally.
- Built and scanned the exact committed staging candidate
  `eeacfd196ea7cd1c0b4f2f923b7366ff63130124`. Its OCI revision label matches
  that SHA and its loopback-registry digest is
  `sha256:5bf9d09a6ac43affaba4ac5bc71f225f047be642d5a8e209825c6c06a338b3fd`.
  The retained [CycloneDX 1.7 SBOM](evidence/gate-4/eeacfd196ea7cd1c0b4f2f923b7366ff63130124/sbom.cdx.json)
  contains 63 OTP applications and 116 Debian packages; its
  [receipt](evidence/gate-4/eeacfd196ea7cd1c0b4f2f923b7366ff63130124/sbom.cdx.json.receipt)
  binds the source SHA, image digest, image revision, digest-pinned Syft image,
  generation time, and SBOM checksum. This is release-inventory evidence, not a
  deployment claim; the same image must still pass Gates 13 through 15 before
  staging is considered ready.

## Gate 5: Make runtime configuration explicit and fail closed

Create one typed runtime configuration boundary. Do not scatter environment
parsing across feature modules.

Validate these groups at boot:

- Endpoint host, allowed origins, HTTPS aliases, and secure cookie settings.
- Database connection and migration behavior.
- GitHub OAuth client, callback, scope, and token-encryption keys.
- OpenAI text, voice, embedding, and shadow-program provider settings.
- Voice admission, recording, retention, and encryption settings.
- Work, machine, recovery, memory, and graph feature dependencies.
- Forge repository, owner, Git URL, WAL, artifact store, build sidecar, operator
  token, allowlist, and fleet size.
- Horde, Ra, DNS discovery, node naming, and distribution settings.

Apply these rules:

- Prefer `Application.fetch_env!/2` for required settings whose absence changes
  behavior. Permit a default only for a documented, sanctioned degraded mode.
- Validate value kinds and domains, not only presence. Repository paths are not
  module names, and a structurally valid allowlist can still be unusable.
- Use explicit staging values instead of relying on development defaults.
- Refuse invalid or incomplete feature combinations. For example, refuse an
  enabled recording feature without a recording key.
- Redact values from errors and logs. Name the missing setting, not its value.
- Give every feature a documented default and staging override.
- Disable voice, work, semantic memory, forge deployment, and boot convergence
  until their specific staging gates begin.
- Do not enable Ra by default on a topology that cannot form the expected
  cluster.
- Put Ra data, forge artifacts, WAL caches, and build queues on intentional
  durable or disposable volumes. Do not use inherited `/tmp/sarah_*` defaults.
- Make the target repository `OpenAgentsInc/openagents.com` explicit.

Add a command that prints a content-free configuration readiness report. It
should show enabled features and validation status without printing secrets,
URLs with credentials, internal node names, or tokens.

Add startup self-tests for behavior-changing registries and policies. At a
minimum, prove the tool catalog is nonempty when tools are enabled and prove
that configured hot-load examples classify as intended. A node that silently
boots without its tools or rejects every direct load is not ready.

**Exit criteria:** A staging release either starts with a valid, reviewed
configuration or exits before serving traffic with a redacted diagnostic.

**Gate 5 status (2026-08-20): complete.**

- Added `OpenAgents.RuntimeConfig` as the typed boundary for endpoint,
  database, GitHub, provider, feature, forge, storage, Horde, Ra, discovery,
  node, and distribution settings. It validates before migrations, supervised
  workers, or the endpoint and names only the invalid setting in failures.
- Replaced provider-side process-environment reads with the boundary's
  centralized OpenAI secret accessor. GitHub OAuth scopes are now configured
  once and validated against the implemented retained-token tool model.
- Added an explicit Gate 5 staging profile with every feature boolean set.
  Staging-gate fences refuse advanced product features before Gate 14, forge
  deployment and boot convergence before Gate 13, and Ra before Gate 12.
  Production remains separately locked.
- Removed inherited temporary-directory fallbacks for Ra, forge data, forge
  WAL, build queues, artifacts, and coding jobs. Enabled staging features must
  use explicit absolute storage paths outside `/tmp`.
- Added content-free Mix and release readiness commands plus startup behavior
  checks for the executable tool catalog and hot-load examples. The release
  wrapper now generates Castle runtime configuration before either readiness
  or migrations, fixing a fresh-release preboot ordering defect.
- Exact committed SHA `5351e62b3b1ab1734c810779860344d611ebd0bd`
  passed 1,237 default Elixir tests, all 9 distributed tests, 17 browser tests,
  the documentation and dependency gates, the redacted release readiness
  check, migrations, and startup against a disposable PostgreSQL database.
  The retained [readiness report](evidence/gate-5/5351e62b3b1ab1734c810779860344d611ebd0bd/runtime-readiness.json)
  and [receipt](evidence/gate-5/5351e62b3b1ab1734c810779860344d611ebd0bd/runtime-readiness.receipt)
  contain no credentials, URLs, hosts, paths, node names, or tokens. No staging
  deployment or production action occurred.

## Gate 6: Harden identity, authorization, and secrets

### Decide GitHub token retention deliberately

The current OAuth path stores an encrypted GitHub token even though some
invariants say the token is discarded after identity projection.

Choose one model:

- **Identity-only:** request the minimum identity scope, discard the access
  token, and remove repository tools that depend on it.
- **Identity and GitHub tools:** store the token because the user explicitly
  enabled GitHub-backed tools, request the minimum required scopes, disclose the
  retention, encrypt it at rest, support key rotation, revoke it on disconnect,
  and include its metadata in data-rights behavior without exporting the token.

Do not describe the first model while implementing the second.

### Separate route authority classes

Classify every route as public read, authenticated browser, authenticated API,
operator, machine, internal service, or Git transport. Add an automated route
inventory test.

- Keep public health, status, leaderboard, changelog, and configured source
  projections content-free or bounded by their publication contract.
- Require authentication and authorization for every product mutation.
- Keep browser mutations CSRF-protected.
- Give CLI-compatible API clients a deliberate bearer-token or personal-access-
  token flow rather than relying on browser cookies.
- Require operator identity for promotion and other operator writes.
- Require scoped, expiring, replay-resistant credentials for machines and
  inference grants.
- Return indistinguishable responses for hidden operator and private repository
  surfaces where the invariant requires it.

### Protect secrets and logs

- Inventory every secret and assign a staging-only secret name and runtime
  identity.
- Remove secrets from build arguments, images, repository URLs, receipts, and
  exception text.
- Do not embed the forge operator token in a URL that can reach process lists or
  logs.
- Redact OAuth callback query parameters at the platform logging boundary.
- Scan application logs for message, prompt, transcript, memory, tool argument,
  SDP, credential, and machine-token leakage.
- Rotate any credential that may have appeared in prior staging logs.

**Exit criteria:** Every mutation has an explicit principal and scope, GitHub
token behavior matches its documentation, and staging logs contain no secret or
private-content fields.

### Gate 6 implementation status

Application controls were completed and locally verified on 2026-08-20:

- Chose the identity-and-GitHub-tools model. The consent UI now says that the
  retained, encrypted `repo` grant carries GitHub-side read/write authority
  even though OpenAgents exposes it only to bounded repository-read tools.
  Public profile identity needs no scope, so the redundant `read:user` request
  was removed. Missing, reduced, or broadened granted scopes fail closed.
- Added a versioned AES-256-GCM envelope with an environment-specific active
  key ID, a bounded same-environment prior-key map, transactional rewrap, and
  an executable release rotation command. Explicit disconnect revokes the
  GitHub grant before a compare-and-clear operation, so provider failure or a
  concurrent reconnection cannot silently discard the wrong grant.
- Added non-secret GitHub connection and first-party API credential metadata to
  account export. Product-data deletion and the UI now state that credentials
  remain until their independent disconnect or revoke action.
- Added an executable inventory for every HTTP route and endpoint socket across
  public-read, authenticated-browser, authenticated-API, operator, machine,
  internal-service, and Git-transport authority classes. New or misclassified
  mutations fail the test gate.
- Split public `/api/v3` reads from writes. Writes now require an expiring,
  revocable, digest-only `oa_pat_` bearer with exact `forge:write` scope;
  missing, malformed, unknown, expired, revoked, and wrong-scope credentials
  receive the same refusal. Browser token management remains session-bound and
  CSRF-protected.
- Made machine credentials expire, disconnect active channels at expiry, and
  moved pairing claim to a row-locked one-time transition with a concurrent
  winner test. Existing inference grants remain scoped, expiring, budgeted,
  revocable, and generation-fenced.
- Added a staging secret and runtime-identity inventory, environment-fenced
  vault keys, credential-free builder and mirror URLs, bounded operational
  error codes, global sensitive-parameter filtering, OAuth callback log
  suppression, build-output redaction, and a log scanner that reports finding
  classes and line numbers without echoing private values.
- Rehearsed all three Gate 6 migrations down and back up on disposable
  PostgreSQL. Exact implementation commit
  `04b2faf47080aa7b5bce43b4319fa0276eb3da05` then passed the owned baseline in
  80 seconds with 1,267 default Elixir tests, all 9 distributed tests, 17
  browser tests, 83.29% merged coverage, the packaged production release
  startup, and zero automatic retries. See the
  [Gate 6 local evidence](evidence/gate-6/04b2faf47080aa7b5bce43b4319fa0276eb3da05/README.md).

Gate 6 is not operationally closed. No staging deployment occurred. Before
Gate 15 admission, rotate every pre-gate staging credential, revoke and
reauthorize any legacy `read:user,repo` grant, configure the load balancer to
omit OAuth callback query strings, export logs from every named source for the
complete test window, and pass the private-log scanner plus manual plaintext
review. That exact-SHA staging record is the remaining Gate 6 exit criterion.

## Gate 7: Add real repository and tenant scoping

The Issues and Projects routes carry `owner` and `repo`, but several contexts
currently read and mutate global tables. Fix the domain model before treating
the tracker as a multi-repository forge.

1. Add a canonical repository entity with owner, name, visibility, default
   branch, and stable ID.
2. Add `repository_id` foreign keys to issues, labels, milestones, comments,
   assignee relationships, and repository projects where appropriate.
3. Make issue and milestone numbers unique per repository, not globally.
4. Scope every lookup by repository and resource identifier in one query.
5. Scope labels and assignable users to repository authorization rules.
6. Scope project ownership and project-item issue references.
7. Reject cross-repository issue, label, milestone, and project identifiers.
8. Add database constraints that enforce the same relationships as the
   application.
9. Backfill current rows into an explicit initial repository with a reversible,
   rehearsed migration.
10. Make public reads and authenticated writes explicit rather than leaving all
    `/api/v3` routes on the same unauthenticated pipeline.

Build on the completed controller, LiveView, and domain coverage. Add
multi-repository isolation cases without duplicating the existing mount,
interaction, and JSON-contract cases.

Treat these measured behaviors as known blockers, not hypothetical risks:

- `OpenAgentsWeb.ProjectController` ignores the requested username in five
  project actions, allowing a project to be read or changed through another
  user's path.
- `AssigneeController` reports no assignable users while issue mutations accept
  an arbitrary login.

Replace both behaviors with explicit repository and user authorization rules,
then update the tests that currently pin them as existing behavior.

**Exit criteria:** An owner or repository path can never read or mutate a row
owned by another repository, and PostgreSQL enforces the boundary.

### Gate 7 implementation status

Completed on 2026-08-20:

- Added a canonical repository entity with stable UUID, normalized owner/name,
  visibility, default branch, and active role-bearing memberships. Public
  lookup now excludes private repositories, and writes require owner,
  maintainer, or contributor membership.
- Added repository foreign keys throughout issues, labels, milestones,
  comments, projects, project items, issue-label relationships, and
  issue-assignee relationships. Issue and milestone numbers are unique within
  a repository rather than across the application.
- Scoped route-facing controller and LiveView queries by repository in the same
  database lookup. Cross-repository identifiers now fail closed, and composite
  database constraints enforce the same issue-label, issue-assignee,
  issue-comment, issue-milestone, project-owner, and project-item boundaries.
- Replaced the empty assignee endpoint and arbitrary-login mutation with the
  active repository membership set. Fixed every project action that previously
  ignored the username segment, including create ownership.
- Added a reversible migration that backfills the existing rows into the
  explicit `OpenAgentsInc/openagents.com` repository and preserves legacy
  label, assignee, milestone, comment-author, project-owner, and project-item
  relationships. Rehearsed the migration down/up against a populated
  disposable test database, validated each relationship, then repeated the
  down/up cycle and reset the test database.
- Added multi-repository isolation, private-read, membership, controller,
  project-path, and composite-constraint tests while retaining the established
  Issues and Projects behavior coverage.
- Exact implementation commit
  `8db39fe3fe3ce9a338117c0e96521a00c09b146a` passed the owned baseline without
  retries in 81 seconds: 1,283 default Elixir tests, all 9 distributed tests,
  17 browser tests, 83.44% merged coverage, and the packaged production release
  startup against a disposable PostgreSQL database. See the
  [Gate 7 evidence](evidence/gate-7/8db39fe3fe3ce9a338117c0e96521a00c09b146a/README.md).

Gate 7 is complete. No staging or production environment was changed.

## Gate 8: Harden chat, memory, work, machines, and voice

### Chat and provider lifecycle

- Keep LiveView free of direct HTTP, credential, retry, and provider event code.
- Bound every message, stream frame, tool call, continuation, and rendered
  projection.
- Require durable turn, message, provider-step, and tool-step state before
  broadcasting completion.
- Verify cancellation, reconnect, duplicate event, timeout, malformed provider
  data, and process-restart paths.
- Make retry behavior operation-specific. Do not retry a mutation unless its
  idempotency contract makes repetition safe.
- Confirm that every provider failure produces a bounded, provider-neutral
  result.

### Memory and data rights

- Test account isolation at the query and database levels for every memory
  plane.
- Confirm that recall snapshots exclude later writes and foreign accounts.
- Confirm that reset, export, delete, correction, forget, retention, and purge
  paths include all newly integrated tables.
- Verify that derived semantic and graph data can be rebuilt from durable
  authority and disappears when its authoritative source is deleted.
- Keep every export bounded and require a disposable staging account for
  destructive export and deletion tests.

### Recovery workers

Write a behavior specification from the durable-state and recovery invariants
before writing tests. There is no inherited recovery-worker suite to translate,
so this work must resolve intended behavior rather than guess from the current
implementation.

Add direct tests for:

- `OpenAgents.TurnRecovery` after a turn process dies mid-stream.
- `OpenAgents.VoiceRecovery` after a voice runtime disappears.
- `OpenAgents.WorkRecovery` after a delegated worker dies at each durable
  checkpoint.
- `OpenAgents.Memory.SemanticWorker` after provider, database, and process
  failures.

Use process monitors, supervised processes, and durable state assertions. Do not
use fixed sleeps as the correctness mechanism.

### Voice and recording

- Fix the recording start race so the admitted server generation exists before
  the browser processes the remote track event.
- Verify that recording failure never fails the call.
- Keep typed chat available during every voice failure.
- Verify barge-in, interruption, session end, tab destruction, and track cleanup.
- Verify typed input during a live voice call without ending that call or
  starting a competing typed assistant response.
- Verify disclosure before microphone access and a visible indicator only while
  recording runs.
- Verify chunk sequencing, size limits, truncation, late-chunk grace, encryption,
  retention, operator playback, export metadata, and deletion.

### Machines and delegated work

- Keep pairing and claim secrets out of logs, screenshots, and test output.
- Require one-time claim, owner approval, token replay refusal, and revocation.
- Bind every job to an owner, conversation, machine, authority set, and budget.
- Verify cancellation, worker restart, duplicate delivery, and terminal report
  persistence.
- Run only harmless staging jobs against disposable repositories and machines.

**Exit criteria:** Every asynchronous subsystem has tested interruption,
recovery, idempotency, ownership, and bounded-failure behavior.

### Gate 8 implementation status

Completed on 2026-08-20:

- Added the asynchronous recovery contract before the new recovery tests. The
  contract defines durable authority, generation fencing, permitted resume
  behavior, honest terminal failure, idempotency, and resource bounds for text,
  voice, work, and semantic derivatives.
- Added direct supervised-process tests for `TurnRecovery`, `VoiceRecovery`,
  `WorkRecovery`, and `SemanticWorker`. The tests cover a killed streaming turn,
  an admitted voice generation, live and orphaned work singletons, provider and
  drain failure, worker death, expired-lease reclamation, and stale-result
  fencing without fixed sleeps as the correctness mechanism.
- Made provider mutation retries operation-specific. OpenAI response creation
  and Realtime call creation now send one `POST` attempt, with direct adapter
  tests that fail if the request repeats.
- Added an accumulated assistant-message limit and a database hard ceiling for
  every message. Recovery now records the bounded `runtime_restarted` error
  code across the complete text-turn evidence chain.
- Added bounded semantic-provider execution, reclaimable leases, attempt
  fencing, and worker-level exception containment. Added composite database
  constraints that prevent semantic jobs or embeddings from crossing their
  source conversation.
- Bound every machine delegation to its account-owned machine, immutable
  admission-time authority, immutable execution request, and bounded budget.
  Only the generation-fenced ACP session checkpoint may change after
  admission. The worker reads machine, agent, working directory, and wall-clock
  authority from those fields.
- Rehearsed the Gate 8 migration forward, backward, and forward again on a
  populated disposable database. The rehearsal preserved the legacy job,
  rebuilt its machine, authority, and budget binding, admitted the session
  checkpoint, and refused an execution-identity rewrite.
- Exact implementation commit
  `6a812a22e9942f88b2593dc0d7b18fba13cabc53` passed the owned baseline without
  retries in 80 seconds: 1,295 default Elixir tests, all 9 distributed tests, 17
  browser tests, 83.59% merged coverage, and the packaged production release
  startup against a disposable PostgreSQL database. See the
  [Gate 8 evidence](evidence/gate-8/6a812a22e9942f88b2593dc0d7b18fba13cabc53/README.md).

Gate 8 is complete. Run only harmless delegated jobs against disposable
repositories and machines when Gates 14 and 15 execute this coverage in
staging. No staging or production environment was changed.

## Gate 9: Harden the forge build lane

Do not enable staging hot loading while the current v0 build and load protocol
can accept partial fleet success.

### Replace the sidecar queue protocol

- Give every build a unique build ID. Do not key work only by SHA.
- Use JSON or another non-executable structured format.
- Write requests and responses through atomic temporary-file renames.
- Validate repository, SHA, request version, size, and allowed fields.
- Pass credentials through a protected file descriptor, mounted secret, or
  workload identity. Do not place credentials in repository URLs.
- Bound compiler output and preserve the full output only in an operator-owned
  artifact with defined retention.
- Recover or expire abandoned jobs without confusing their responses with a
  retry.

### Make artifacts immutable and verifiable

- Build the exact pushed commit in an isolated production toolchain.
- Record Elixir, OTP, application, dependency-lock, source, and baseline
  identities.
- Compare against the current live target's immutable manifest, not a sidecar's
  last warm build.
- Detect module additions, changes, and deletions.
- Normalize BEAM files before hashing and record an artifact SHA-256 digest.
- Store the artifact by digest in durable staging storage.
- Verify the digest, tar bounds, module count, entry names, BEAM module identity,
  and declared manifest before creating module atoms or loading code.
- Route deletions, NIF changes, application changes, dependencies, assets,
  configuration, ERTS, and OTP changes away from direct loading.

**Exit criteria:** A build can be reproduced and independently verified from
its pushed commit and immutable receipt, and malformed artifacts fail before
loading any module.

### Gate 9 implementation status

Completed locally on 2026-08-20:

- Replaced SHA-keyed, line-oriented queue files with strict canonical JSON
  requests and responses keyed by a unique UUID build attempt. Unknown fields,
  abbreviated SHAs, oversized bodies, malformed identities, and URLs containing
  credentials fail before the compiler boundary.
- Added atomic temporary-file publication, claim-by-rename, request expiry, and
  durable `running`, `complete`, `failed`, and `expired` attempt receipts. A
  recovered attempt always gets a new build ID, and a database constraint
  permits only one running attempt per target.
- Added the isolated `forge-builder` Docker target and
  `OpenAgents.Forge.BuildWorker`. It fetches and checks out the exact pushed SHA
  detached, uses fixed Git and Mix arguments without a shell, requires the
  production dependency lock, compiles with warnings as errors, and removes
  its disposable workspace.
- Kept builder credentials out of the queue, repository URL, and serving
  release. The worker accepts only an absolute mounted askpass-helper path and
  disables terminal prompting.
- Added deterministic BEAM normalization and canonical artifact manifests with
  source, baseline, Elixir, OTP, ERTS, application version/spec, and dependency
  lock identities plus complete added, changed, and deleted module sets. Fixed
  tar ownership and time metadata so identical inputs remain byte-for-byte
  reproducible across wall-clock boundaries.
- Addressed artifacts by the full tar SHA-256 in both the local cache and
  durable WAL store. A target cannot become `built` until independent
  verification, local publication, durable storage, and receipt completion all
  succeed.
- Added one shared atom-free verifier for the builder, hot loader, and boot
  convergence. It bounds tar, manifest, module count, BEAM size, paths, and
  names; checks every declared size and digest; parses `Atom` and OTP 28 `AtU8`
  module identity as bytes; and validates the exact change set before any
  module atom can be created.
- Routed missing baselines, deletions, NIF/native changes, dependency and
  application changes, assets, configuration, migrations, releases, runtime
  images, and toolchain drift to rolling replacement rather than direct load.
- Bounded the redacted compiler excerpt at 8 KiB. Full output remains a mode
  `0600` builder/operator artifact with a digest, reference, and seven-day
  default retention; the serving release does not read the full file.
- Added focused protocol, artifact, worker, coordinator recovery, WAL, hot-load,
  and boot-convergence coverage. The forge suite passes 93 tests, and the full
  precommit gate passes 1,302 default Elixir tests and 17 browser tests with no
  failures.
- Built the dedicated `forge-builder` Docker target with the pinned Elixir
  1.20.3 and OTP 29.0.5 production toolchain. The image build completed without
  application warnings; it also exposed and closed bitstring-size warnings that
  were invisible under the local Elixir 1.19 toolchain.
- Documented the deployment contract, permissions, exact build order,
  classification, verification, recovery, retention, and staging proof in the
  [forge build lane runbook](operations/forge-build-lane.md).

Gate 9 is complete, and Gate 10 now provides transactional fleet application.
Keep the staging deploy lane disabled until Gate 11 adds the fallback lanes and
Gate 12 creates the isolated distributed staging environment. Gates 12–15 must
exercise the real builder image against the exact staging SHA and retain the
image, build, artifact, and output-proof identities; local success is not
staging admission.

## Gate 10: Make fleet deployment transactional

Replace one-way remote loading with prepare, apply, verify, commit, and rollback.

1. Snapshot the expected healthy node set.
2. Verify the artifact and capture exact prior object code on every node.
3. Return an expiring deployment token from every prepared node.
4. Apply and smoke-test one canary.
5. Apply to the remaining prepared nodes.
6. Verify module identities, application revision, readiness, and expected node
   membership everywhere.
7. Commit only when every expected node reports success.
8. Restore every node that applied the candidate if any node fails or times
   out.
9. Verify the restored revision before recording `reverted`.
10. Remove a divergent node from readiness if rollback cannot restore it.

Never advance a target to `live` merely because the local canary passed. A
remote `error`, timeout, missing node, unexpected node, or failed verification
must block `live`.

Make boot convergence part of readiness:

- Fetch the current live artifact from durable storage on an empty node.
- Verify the same digest and manifest used during promotion.
- Keep readiness false when image code differs from the live target.
- Retry with bounded backoff.
- Retain the current and immediate rollback artifacts locally.
- Report a content-free convergence state on `/status`.

**Exit criteria:** Three-node tests prove consistent success, exact rollback,
timeout behavior, node replacement, cold-cache convergence, and refusal to
serve divergent code.

### Gate 10 implementation status

Completed locally on 2026-08-20:

- Replaced the one-way remote load with an explicit fleet transaction that
  snapshots the exact healthy member set, requires the configured fleet size,
  selects one canary, and rechecks membership between every mutating phase.
- Added a supervised participant on every node. It independently verifies the
  artifact, canonical manifest, source, build, runtime toolchain,
  classification, and allowlist before creating module atoms. It caches the
  digest-addressed bytes and captures exact prior object code before returning
  a random 256-bit token.
- Bound each token to one deployment, target, build, source SHA, artifact,
  manifest, candidate, prior object set, and expected fleet. Tokens expire and
  admit at most four prepared transactions per node. Expired uncommitted tokens
  restore immediately. Expired committed tokens finalize only when the durable
  target and artifact identities match, defer while the database commit remains
  in progress, and restore after a durable refusal.
- Persisted the bounded participant fence across supervised process restarts.
  A participant restart therefore recovers the token, exact prior object code,
  candidate identity, and readiness fence instead of exposing partially
  applied code.
- Kept every participant out of external readiness from prepare through fleet
  commit. Candidate verification checks loaded BEAM MD5 identities,
  application version, candidate revision, and node-level deployment
  readiness before commit.
- Made all errors and timeouts trigger rollback on every prepared node. A node
  reloads or removes every affected module and verifies the exact restored
  BEAM identity. Only a fully verified fleet restoration records `reverted`;
  an unreachable or divergent node records `failed` and remains out of
  readiness.
- Made pre-token and partial-prepare failures rollback only participants that
  actually issued tokens. These failures now return bounded outcomes instead
  of raising on a missing token, and failed fleet snapshots retain their
  per-node health diagnostics.
- Added a database transaction that advances the target to `live` only in the
  same commit that inserts its terminal deployment receipt. The receipt binds
  deployment, artifact, manifest, expected membership, bounded per-node
  outcomes, rollback verification, and timing. PostgreSQL rejects receipt
  updates and deletes.
- Rehearsed the receipt migration forward, backward, and forward again on a
  disposable populated database. The migration backfilled legacy rows,
  preserved them across rollback, and recreated the hardened schema without
  data loss.
- Fenced deployment ownership to the newest promotion, so a late build for a
  superseded target cannot change fleet code.
- Moved the deployment participant and synchronous boot convergence after
  PostgreSQL but before cluster discovery, PubSub, runtime workers, and the
  endpoint. A cold node verifies its local artifact or fetches the identical
  durable blob, retains the current and immediate rollback artifacts, prunes
  older digest-addressed cache entries, and retries failures with capped
  exponential backoff.
- Added durable live-target checks to readiness and the periodic convergence
  cycle. A late-joining or replaced node leaves readiness while a target is
  deploying or as soon as a newer live target exists, then converges before it
  serves that revision.
- Made `/healthz` return `503` while boot code or a deployment participant is
  divergent. Added a bounded, content-free boot and deployment projection to
  `/status`, and made its quorum calculation honor the configured forge fleet
  size even when Ra is disabled.
- Added direct participant tests for token fencing, exact rollback, expiry,
  commit authority, and supervised restart recovery; database tests for
  duplicate delivery, superseded targets, atomic live completion, and receipt
  immutability; boot tests for cold-cache fetch, cache retention, stale-target
  refusal, and degraded retry; and real three-node tests for success, remote
  failure with exact rollback, rollback refusal, timeout, and membership loss.
- Passed the exact-SHA baseline with 17 browser tests, 1,339 default Elixir
  tests, 14 distributed tests, 83.15% merged coverage, and packaged release
  startup against a disposable PostgreSQL database. The distributed lane
  includes five real three-node deployment scenarios. See the
  [Gate 10 evidence](evidence/gate-10/6999983b4487c0fe0acdb73c10b34327cdb0de5a/README.md).
- Built the pinned Elixir 1.20.3 and OTP 29.0.5 `forge-builder` production
  release without application warnings.
- Documented the operator contract in the
  [transactional deployment runbook](operations/forge-transactional-deployment.md).

Gate 10 is complete locally with exact-commit evidence. Keep the deploy and
boot-convergence features disabled until Gate 11 supplies relup and
rolling-replacement fallbacks and Gate 12 provides an isolated distributed
staging lane. No staging or production environment was changed.

## Gate 11: Complete relup and rolling replacement

Direct loading is only one deployment class. Implement and test the two required
fallbacks before broadening the direct-load allowlist.

### Relup lane

- Use versioned state structs for long-lived processes that must survive an
  upgrade.
- Add tested `code_change/3` callbacks for every supported state transition.
- Build forward and reverse relups from explicit release versions.
- Stage, check, unpack, install, verify, and make permanent one node at a time.
- Reverse the relup when a health check fails.
- Re-stage consumed release artifacts after an interrupted install.
- Prove that a stateful process keeps its PID and data through upgrade,
  downgrade, and re-upgrade.

Before broadening the direct-load allowlist, prove one complete
push-to-build-to-canary-to-fleet-to-live path with an allowlisted module. A
configuration review alone cannot detect an allowlist whose values are the
wrong kind.

### Rolling replacement lane

- Build an immutable image identified by digest.
- Require a complete local gate receipt for the exact SHA.
- Drain one node, verify remaining capacity and quorum, replace it, and wait for
  membership and readiness before continuing.
- Abort before replacing another node when one node fails to rejoin.
- Keep database migrations additive while old and new revisions overlap.
- Contract schemas only in a later release after rollback is no longer needed.

### Owned release gate

Add `ops/ci/gate.sh` and `.githooks/pre-push` on owned infrastructure. The gate
should run:

1. Compile with warnings as errors.
2. `mix precommit`.
3. The separate cluster suite.
4. JavaScript tests.
5. Direct-load transaction tests.
6. Relup, reverse-relup, version-chain, and kill-during-install proofs.
7. Rolling drain and replacement proofs.
8. Documentation, invariant, secret, CSS, and icon contract checks.
9. A release build and startup smoke test.
10. A content-free gate receipt bound to the exact SHA.

**Exit criteria:** Every supported change has a safe deployment class, a tested
rollback or recovery path, and an exact-SHA gate receipt.

### Gate 11 implementation status

Implemented locally on 2026-08-20:

- Replaced the relup placeholders with explicit `0.1.0` and `0.2.0` release
  builds, a generated forward and reverse `relup`, and a packaged candidate
  that carries the generated release instructions.
- Added `OpenAgents.ReleaseState` and its versioned state struct. Focused and
  packaged-node proofs preserve the process PID and observations through
  upgrade, downgrade, and re-upgrade.
- Added a deterministic install barrier and a live recovery proof that kills
  the emulator after the point of no return, verifies that the prior permanent
  release boots, re-stages the consumed immutable tar, and completes the retry.
- Added `OpenAgents.Forge.RelupNode` and
  `OpenAgents.Forge.RelupDeployment` for digest verification, immutable cache
  retention, stage restoration, preflight, one-node-at-a-time installation,
  health and state checks, permanence, reverse relup, and fleet-wide reversal
  of already-upgraded nodes after a later failure.
- Added `OpenAgents.Forge.RollingReplacement` and the staging-provider
  behavior. The coordinator removes one node from readiness, waits for drain,
  checks remaining capacity and quorum, replaces by image digest, and requires
  membership, boot, database, SHA, digest, and readiness convergence before it
  continues. Unsafe pre-replacement capacity restores readiness; failed rejoin
  restores the last-known-good image and stops the rollout.
- Added an exact-SHA receipt verifier, the owned `ops/ci/gate.sh`, a pre-push
  hook, and a receipt-gated immutable local image builder. The release gate
  composes warning-free compilation, precommit, distributed, browser, direct,
  relup, interruption, rolling, contract, and packaged startup checks.
- Documented operation and additive migration constraints in the
  [release deployment fallback runbook](operations/release-deployment-fallbacks.md).
- Retained the direct lane's existing end-to-end push, build, canary, fleet,
  and live proof with the exact `OpenAgents.BuildInfo` allowlist entry. The
  broader allowlist remains unchanged and disabled outside tests.

Gate 11 is complete locally on exact implementation commit
`2e1c9240d0b172501a93bef7b02e934a63b447ae`. The exact-SHA release gate passed
test and production compilation, precommit, 14 distributed tests, 17 browser
tests, 42 focused direct-transaction tests, live upgrade/downgrade/re-upgrade,
interrupted-install recovery, four rolling-replacement tests, 68 contract
tests, and packaged startup with zero automatic retries. The immutable local
image is `sha256:56e472ce2ac3a967e21f6906c08f87933228d74e6f26d3c041661f180872d472`.
See the [Gate 11 evidence](evidence/gate-11/2e1c9240d0b172501a93bef7b02e934a63b447ae/README.md).

Keep every deploy lane disabled until Gate 12 provides an isolated distributed
staging fleet and an infrastructure-specific rolling provider. No image was
pushed, and no staging or production environment changed during this gate.

## Gate 12: Build an isolated staging environment

The existing Cloud Run staging service can validate the web application, OAuth,
LiveView, chat, memory, provider, and voice behavior. It cannot by itself prove
three-node BEAM hot loading, stable node identity, relup installation, or
node-by-node rolling replacement.

The current staging service and three-node fleet share the production Cloud SQL
instance. Provision a staging-only database instance before claiming this gate
or running load, restart, connection-exhaustion, destructive, or soak tests.
A separate database on the same instance is not an isolation boundary.

Use two staging lanes until the intended fleet replaces the web-only lane:

### Web acceptance lane

Use an isolated staging hostname such as `stage.openagents.com` for browser and
API acceptance. It needs:

- A staging-only GitHub OAuth application and callback.
- A staging-only database and database role.
- Staging-only OpenAI, encryption, forge, machine, and recording credentials.
- Secure cookies, HTTPS, WebSocket origin validation, CSP, and microphone policy.
- A reset feature enabled only for staging test accounts.
- Revision labels and log access that identify the exact deployment under test.

If Cloud Run remains temporarily, hard-reload every browser tab after a deploy.
An open LiveView socket can remain pinned to a draining old revision and produce
false regression results.

### Distributed deployment lane

Create a separate three-node staging fleet using stable instances or stateful
pods that support:

- Stable BEAM node names and private distribution.
- Private service discovery and expected membership.
- PostgreSQL connectivity and migration locks.
- Durable artifact and WAL storage.
- Node-local artifact caches.
- Build sidecar queues isolated from serving containers.
- Readiness removal and node drain.
- One-node-at-a-time replacement.
- Intentional Ra data storage and quorum behavior.

Match the eventual production topology closely enough that a staging relup or
rolling drill proves the same mechanism. Do not claim Cloud Run revision rollout
as evidence for an OTP relup.

### Staging isolation requirements

- Use a separate Google Cloud project or a strictly isolated staging boundary.
- Use staging-specific service accounts with minimum permissions.
- Use a separate database instance and role, Secret Manager secrets, buckets,
  DNS records, OAuth client, and machine tokens.
- Deny access to production secrets and production databases.
- Mark every staging banner, status response, log entry, and receipt as staging.
- Take a database snapshot before migration and destructive data-rights drills.
- Define one command that removes disposable machines, repositories, recordings,
  and test accounts after the run.

**Exit criteria:** Staging can test both the user-facing product and the complete
distributed deployment mechanism without touching production state or sharing
production's database capacity and failure domain.

### Gate 12 implementation status

Implemented locally on 2026-08-20:

- Added a Terraform root for a dedicated staging project. It defines a private
  VPC and DNS zone, a separate private-IP Cloud SQL instance, three stable fleet
  nodes without public IP addresses, durable node-local state disks, a private
  deployer controller, Cloud NAT, staging-only buckets, Secret Manager
  placeholders, Artifact Registry, and split workload identities.
- Added Terraform safety tests that require a project marked as staging, refuse
  the production project, preserve Cloud SQL deletion protection, and prove
  that the fleet and deployer have no public access configuration.
- Added Terraform formatting, initialization, validation, and safety tests as a
  required stage of every exact-SHA release gate receipt.
- Added exact-SHA plan and apply wrappers. The wrappers require a clean
  worktree, a protected remote state bucket, distinct staging and production
  project IDs, valid Application Default Credentials, and an explicit apply
  confirmation.
- Added a content-free isolation validator. It compares project numbers,
  verifies the private database, its separate application role, and the fleet,
  checks staging-only storage, secrets, identities, DNS, and networking, and
  rejects production service accounts in staging IAM. The database password is
  accepted only as a Terraform ephemeral write-only value and never enters the
  plan or state.
- Added exact packaged source and image identity, node-local admission fencing,
  a bounded rolling node probe, and a Google Cloud rolling provider. The
  provider uses private Erlang distribution for drain and health checks. A
  minimal private deployer BEAM node performs exact instance metadata updates
  and resets under the only identity that holds those permissions; it does not
  start the application, join Ra, open HTTP, or connect to PostgreSQL.
- Added an immutable, manifest-scoped staging cleanup registry and one operator
  command. The harness must register each disposable account, repository,
  recording, and product machine before use. Cleanup refuses canonical or
  administrator resources, online machines, active work or conversations, and
  account-owned resources outside the manifest. It deletes one run in a
  transaction and reports only bounded counts.

The local infrastructure definition and mocked safety tests pass. The cloud
apply, isolation receipt, and live disposable-run cleanup proof remain open;
cloud work is blocked until the operator refreshes the expired Google Cloud CLI
and Application Default Credentials. No staging or production cloud resource
changed during this implementation step. See the [isolated staging
infrastructure](../infra/staging/README.md) for the exact bootstrap, plan,
apply, validation, and cleanup procedures.

## Gate 13: Deploy to staging reproducibly

Use this sequence for every staging candidate:

1. Select an exact clean Git SHA.
2. Require its local gate receipt.
3. Build and retain the image, release, SBOM, build manifest, and artifact
   digests.
4. Classify the target as an empty current-lineage database or an existing
   database created by the prior migration lineage.
5. For an empty current-lineage database, run every current migration. For an
   existing prior-lineage database, first produce a schema diff and a written
   baseline map that identifies already-satisfied versions, required
   `schema_migrations` entries, and genuinely new changes. Never replay the
   consolidated create migrations onto existing tables.
6. Rehearse the selected migration path on a disposable copy and run startup,
   rollback-compatible schema, and data-integrity checks.
7. Snapshot the actual staging database.
8. Deploy the candidate to the web acceptance lane with high-risk features
   disabled.
9. Confirm migration completion, `/healthz`, `/status`, database connectivity,
   LiveView connection, and revision identity.
10. Hard-reload persistent browser sessions so they connect to the new revision.
11. Enable one gated subsystem at a time and run its regression group.
12. Deploy the same candidate to the distributed lane.
13. Run direct-load, rollback, boot-convergence, relup, and rolling-replacement
   drills.
14. Collect sanitized logs, database truth checks, receipts, screenshots, and
   timing evidence.
15. Roll back staging if any blocking check fails.

Do not combine an application change, schema contraction, infrastructure
change, and first-time feature enablement in one staging candidate.

**Exit criteria:** Another operator can repeat the deploy from the recorded SHA
and obtain the same revision, schema, configuration posture, and checks.

## Gate 14: Run the staging regression matrix

Record every case as passed, failed, blocked, or not applicable. A retry does not
erase the first failure; record both attempts and explain the result.

### Public and browser surfaces

- `/healthz`, `/status`, `/api/status`, and `/favicon.ico` return their bounded
  expected responses.
- `/`, `/leaderboard`, `/changelog`, `/docs`, `/components`, and configured
  public forge pages render without an authenticated session where intended.
- Hidden, private, operator, and unconfigured forge surfaces do not disclose
  their existence.
- LiveView reconnects after a transient network interruption.
- CSP, cookie, origin, image, and microphone policies match the architecture.
- Phone, tablet, desktop, keyboard-only, reduced-motion, and screen-reader
  checks pass for critical flows.

### Authentication and account state

- GitHub OAuth state, PKCE, attempt expiry, replay refusal, callback errors, and
  banned-user behavior work.
- The persistent staging browser session remains logged in. Do not log it out
  when a user-controlled GitHub login would be required to restore it.
- Session renewal, logout, and concurrent-browser account continuity work.
- GitHub token storage or disposal matches the chosen contract.
- Account export, reset, and deletion operate only on the authenticated owner.

### Typed chat and Markdown

- A first conversation creates one greeting and one canonical conversation.
- Typed messages stream, persist, reload, paginate, cancel, fail, and recover
  correctly.
- A reset through `#reset-conversation-form` removes messages and memory for the
  staging account and returns to one greeting.
- Markdown renders supported structures and refuses raw HTML, unsafe URLs,
  script content, oversized input, and malformed nesting.
- Tool activity uses bounded persisted projections and never displays provider
  IDs or secrets.
- Rate, size, continuation, and tool budgets fail honestly.

### Memory and data rights

- Remember, list, search, correct, forget, export, reset, and delete flows pass.
- Activity chips and memory panels reflect PostgreSQL state after reload.
- Cross-account and cross-conversation reads fail.
- Snapshot fences exclude writes made after capture.
- Semantic failure returns the documented lexical fallback.
- A direct staging database query confirms the durable result when UI and cache
  behavior are ambiguous.

### Voice and recording

- `#voice-start`, `#voice-status`, and `#voice-end` drive a clean call lifecycle.
- The fake-media harness observes listening, Sarah speaking, barge-in,
  interruption, and clean end.
- `POST /voice/calls` returns `201` and the final delete returns `204` on a good
  run.
- Typed input during an active voice call persists without ending voice or
  starting a competing typed assistant response.
- The next spoken response can use the injected typed content.
- Voice tool calls complete within their budgets.
- Reloaded chat shows durable voice transcript items and interruption markers.
- Recording disclosure appears before microphone access.
- Recording chunks and completion reach the server with the correct generation.
- The operator can play the assembled recording, and unauthorized users cannot.
- Channel layout, encryption, truncation, retention, export metadata, and delete
  behavior match the invariant.
- A failed or unsupported recorder leaves the live call and typed chat usable.

### Leaderboard and administrative surfaces

- Anonymous leaderboard rows expose only the published entry fields.
- Typed and voice usage invalidates and refreshes the board without a database
  query per viewer.
- Operator allowlisting uses immutable GitHub IDs.
- Unauthorized `/admin` and `/admin/forge` access is indistinguishable from the
  documented unauthenticated path.
- Promotion accepts only a pushed commit and writes an immutable operator
  receipt.
- Administrative pages expose no transcript, prompt, credential, or private
  memory content beyond their explicit contract.

### Issues and Projects

- Public reads and authenticated writes follow the chosen route policy.
- Issue, comment, label, milestone, assignee, project, field, and item endpoints
  return the documented statuses and shapes.
- Browser LiveViews mount, show empty and populated states, validate forms, and
  perform one meaningful interaction each.
- Repository A cannot read, update, label, assign, or add an issue from
  Repository B.
- Issue and milestone numbers can repeat safely in different repositories.
- Pagination, filters, malformed IDs, missing rows, oversized input, and rate
  limits behave consistently.

### Machines and delegated work

- Public pairing creation, one-time claim, owner approval, inventory, offline
  and online state, and revoke work.
- Token replay fails after claim and after revoke.
- A harmless real staging coding-agent job appears live, reaches a terminal
  state, and writes its report into the conversation.
- Cancellation and worker restart preserve committed evidence and never execute
  a step twice.
- Cleanup removes the ephemeral controller home and disposable project.

### Forge and deployment

- Clone, fetch, and push work against the staging forge.
- WAL and mirror receipts match the pushed refs.
- A valid allowlisted change passes build, canary, fleet transaction, and live
  receipt.
- An off-allowlist module refuses the complete direct-load candidate.
- Corrupt digest, manifest mismatch, module deletion, oversized tar, and invalid
  module identity fail before loading.
- Remote timeout and remote load failure restore every affected node.
- A cold replacement node fetches the durable artifact and becomes ready only
  after convergence.
- A stateful relup preserves PID and state through upgrade, downgrade, and
  re-upgrade.
- Killing a node during relup installation returns it on the prior permanent
  release and permits a clean retry.
- A structural change uses rolling replacement and removes only one node from
  readiness at a time.
- Failed replacement stops the sequence before another node drains.

### Logs and operational truth

- Query logs against the exact new revision and the exact test window.
- Inspect severity-based errors and application `[error]` text entries.
- Separate deploy-overlap database connection noise from candidate regressions.
- Correlate failures with request IDs and receipt IDs without logging content.
- Use direct database queries to distinguish projection failure from persistence
  failure.
- Confirm that logs contain no OAuth codes, tokens, prompts, messages,
  transcripts, memory claims, tool payloads, SDP, audio, or credentials.

**Exit criteria:** Every applicable case passes on the same candidate SHA, and
every failed first attempt has a documented cause and successful corrective
verification.

## Gate 15: Run failure injection and soak staging

After functional regression passes, test the system under controlled failure.
Do not begin this gate while staging shares a database instance, connection
budget, or failure domain with production.

Inject these failures one at a time:

- Provider timeout, malformed event, and stream closure without completion.
- PostgreSQL restart and temporary connection exhaustion.
- PubSub interruption and LiveView reconnect.
- Turn, voice, work, semantic worker, builder, and deployer process termination.
- Machine disconnect during a job.
- Artifact-store unavailability and corrupt cache.
- One unreachable fleet node.
- Node membership change during a deployment.
- Build sidecar crash and stale response.
- Browser navigation and tab destruction during microphone use.
- Recording upload failure and late final chunk.

After failure injection, run a staging soak:

- Keep the web and distributed staging lanes active for at least 48 hours.
- Exercise scheduled typed, memory, voice, tracker, Git, and status canaries.
- Watch database connections, queue depth, mailbox growth, process count,
  memory, CPU, restart count, artifact cache, Ra state, and node convergence.
- Investigate every crash, unexplained retry, stale active row, divergent node,
  leaked process, and content-bearing log entry.
- Repeat the full smoke group after the soak without redeploying.

**Exit criteria:** Staging survives controlled failures and the soak without
data loss, authority expansion, fleet divergence, secret leakage, or unexplained
error accumulation.

## Required staging evidence

Store one staging report per candidate. Include:

- Git SHA, branch, image digest, release version, artifact digests, and SBOM.
- Database migration versions and rehearsal result.
- Redacted configuration readiness report.
- Default and cluster test counts, coverage summary, and JavaScript results.
- Staging service revision and distributed node release identities.
- A pass, fail, blocked, or not-applicable result for every regression group.
- Sanitized screenshots or recordings for critical UI and voice flows.
- Sanitized log queries and direct database truth checks.
- Forge build, deployment, rollback, relup, and rolling receipts.
- Failure-injection and soak timelines.
- Every known issue, its owner, severity, and disposition.

Never store session cookies, OAuth codes, access tokens, database passwords,
machine tokens, provider keys, raw prompts, transcripts, memory values, or audio
in the report.

## Production hold conditions

Production remains blocked while any of these conditions is true:

- Documentation and `INVARIANTS.md` disagree with the implementation.
- A current invariant points to missing evidence.
- Any test is silently skipped or a cluster test is not run.
- The browser-side voice, recording, and hook suite does not exist or is not
  part of the owned release gate.
- A critical route lacks an explicit authority class.
- Repository data is not scoped and constrained by repository ID.
- GitHub token retention is undocumented or cannot be rotated and revoked.
- A recovery worker lacks direct tests.
- The forge can mark a partial fleet deployment live.
- Artifact identity, digest, rollback, boot convergence, relup, or rolling
  replacement lacks staging proof.
- Staging depends on production credentials, data, database capacity, or a
  shared database failure domain.
- The migration lineage for any existing database has not been mapped and
  rehearsed on a disposable copy.
- A staging regression, failure-injection case, or soak issue remains
  unexplained.
- Logs contain secrets or private product content.
- The candidate did not complete the full staging matrix on one exact SHA.

Passing staging does not automatically authorize production. It only creates a
reviewable production-readiness candidate for a later plan and explicit owner
decision.

## Suggested commit sequence

Keep commits independently reviewable and run the relevant local gates before
each handoff.

| Order | Commit | Required evidence |
| --- | --- | --- |
| 1 | Add integrated architecture decisions and repair the README | Documentation checks pass |
| 2 | Reconcile plans, component docs, and invariant evidence | No broken evidence links or duplicate invariant IDs |
| 3 | Rename generic Sarah infrastructure and configure `openagents.com` targets | Allowed-reference check passes |
| 4 | Centralize and validate runtime configuration | Invalid staging configurations fail before traffic |
| 5 | Resolve Markdown, UI, icon-policy, palette, dependency, and license consolidation | Parser security, cascade, theme, and component contract tests pass |
| 6 | Resolve GitHub token policy and classify route authority | Auth, CSRF, replay, and secret-redaction tests pass |
| 7 | Add repository entities and tenant-scoped tracker data | Cross-repository isolation tests pass |
| 8 | Close chat, recovery, memory, voice, work, and machine hardening gaps | Async failure and recovery tests pass |
| 9 | Replace the forge build queue and add immutable artifact manifests | Build reproducibility and corruption tests pass |
| 10 | Add transactional fleet deployment and readiness-bound boot convergence | Three-node rollback and cold-boot tests pass |
| 11 | Complete relup, reverse-relup, and rolling replacement | Upgrade and replacement drills pass |
| 12 | Add missing JavaScript coverage, the owned release gate, and content-free receipts | Exact-SHA refusal and full local gate pass |
| 13 | Provision isolated web and distributed staging lanes, including a separate database instance | Isolation and configuration review pass |
| 14 | Add staging harnesses and the evidence report template | Regression harness dry run passes |
| 15 | Deploy one staging candidate and complete the full matrix | Staging report is complete |
| 16 | Complete failure injection and the 48-hour soak | No unexplained blocking issues remain |

## Final staging readiness checklist

- [x] The repository has one accurate architecture narrative.
- [x] Every remaining Sarah reference is intentional and specific.
- [x] All documentation links and invariant evidence resolve.
- [x] The application has one Markdown parser, component system, and documented
      two-tier icon policy.
- [x] The dark-only palette has no nonfunctional theme control.
- [x] Runtime configuration is typed, redacted, and staging-specific.
- [x] Every route has an explicit authority class.
- [x] GitHub token behavior matches code, UI disclosure, and data rights.
- [ ] Gate 6 staging credentials are rotated and the complete staging log
      window passes automated and manual private-content review.
- [x] Issues and Projects are scoped by repository in code and PostgreSQL.
- [x] Every asynchronous recovery path has direct tests.
- [x] Browser-side voice, recording, and hook tests run in the owned gate.
- [x] Voice recording starts only after generation admission.
- [x] Build requests are structured, unique, bounded, and non-executable.
- [x] Artifacts are immutable, digested, manifest-checked, and durably stored.
- [x] Fleet deployment is transactional and rolls back every affected node.
- [x] Boot convergence controls readiness.
- [ ] Relup and rolling replacement pass their staging drills.
- [x] Owned local gates produce exact-SHA receipts.
- [ ] Web and distributed staging are isolated from production.
- [ ] Staging has a separate database instance and failure domain.
- [ ] The migration lineage is mapped and rehearsed for every nonempty target.
- [ ] The complete regression matrix passes on one SHA.
- [ ] Failure injection and the 48-hour soak pass.
- [ ] The staging evidence report contains no secrets or private content.
- [ ] No production action has occurred.

---

# Addendum: measured state and blocker evidence

Date: 2026-08-20
Author: the agent that ran the DaisyUI consolidation, the port-gap fan-out, and
the coverage audit
Status: accepted and incorporated into the plan above

The gate structure remains intact. The main plan now incorporates the measured
Gate 0 baseline, the missing JavaScript suite, database isolation, migration
lineage, configuration and authorization evidence, and recovery-test scope.
It also adopts the owner's two-tier icon decision, makes the current dark-only
palette explicit, and treats the style-pack rename as a palette migration.
This addendum remains as the measurement record. Everything here was verified
directly at the SHA given, not inferred.

## Current disposition

The implementation gates resolved the addendum's code-level findings after the
original measurement. Preserve the sections below as historical evidence; use
this disposition for the current plan:

| Finding | Current disposition |
| --- | --- |
| A1, missing browser tests and incomplete baseline | Resolved by Gate 0. The owned baseline now runs the Node suites, merged Elixir coverage, and release smoke against an exact SHA. |
| A2, staging shares a production database failure domain | Open and blocking Gates 12 and 15. Provision a separate staging database instance before any failure injection or soak. |
| A3, incompatible migration lineage on a nonempty prior database | Open and blocking Gate 13 for every prior-lineage target. Map and rehearse that lineage before deployment. |
| A4, component, icon, and palette conflicts | Resolved by Gate 4 and its compiled CSS contract tests. |
| A5, silent runtime configuration failures | Resolved by Gate 5 and its fail-closed runtime readiness checks. |
| A6, repository authorization violations | Resolved by Gate 7 in code, PostgreSQL constraints, and the populated migration rehearsal. |
| A7, missing recovery-worker tests | Resolved by Gate 8 with direct supervised-process recovery tests. |

Gate 9 also resolves the later build-lane requirements that the addendum helped
make measurable. It does not resolve transactional fleet deployment, isolated
staging, migration-lineage rehearsal for an inherited database, or staging
proof. Keep those items open until their named gates pass.

## A1. Gate 0 baseline, already measured

Gate 0 asks for a reproducible baseline. Most of it exists as of `d5679e8`:

| measurement | value |
| --- | --- |
| `mix test` | 1218 passed, 0 failed, 9 excluded |
| `mix test --only cluster` | 9 passed |
| `mix precommit` | exit 0 |
| `mix compile --warnings-as-errors` | exit 0, 0 warnings |
| `mix test --cover` total | 83.14% (415 modules) |
| hidden test filters | none — every `@moduletag :skip` was deleted and `:skip` removed from `test_helper.exs`; only `:cluster` is excluded |

Two qualifiers on that coverage number, both already in the coverage audit:

- `Cluster.Drain` and `Cluster.RaBootstrap` read as 0% **only** because the
  coverage run excludes `:cluster`. The plan's instruction to merge the two runs
  is not a nicety; without it those two modules are misreported as untested.
- Line coverage maps where nothing is looking. It is not a quality score.

**Gate 0 could not pass when this was measured.** Its item 4 asked to "run the
JavaScript tests for voice state, recording, and browser hooks," but **there are
no JavaScript tests in this repository.** `assets/` contains no test files and
`assets/package.json` declares no test script. Sarah has two Node test files
(~329 lines) covering voice state and recording; they were not carried across
in the port. That is a porting gap, not a step someone forgot to run. Gate 0 now
names creation of the missing suite as blocking work.

**Resolved after this measurement:** `assets/test/voice_state_test.mjs` and
`assets/test/voice_recording_test.mjs` now cover these behaviors,
`assets/package.json` provides `npm test`, and `mix precommit` runs the suite
through `mix assets.test`.

The first merged coverage attempt also exposed an instrumented anonymous Ra
query that crashed on a peer with `badfun`. Session-registry queries now use
stable module-function-argument descriptors, and all 9 cluster tests complete
under coverage. Coverage-aware peer shutdown now collects remote execution, and
direct `RaBootstrap` decision tests cover the previously untested worker. The
completed exact-SHA baseline supersedes that intermediate result. At
`d9ffc65f5cdd961cf228146a95e9d651e14692d2`, the merged default and cluster
result is 83.59% and passes the enforced 83% floor. The release smoke also
passes, and the inspected local receipt records zero automatic retries.

## A2. Blocker: staging is not isolated from production today

Gate 12 lists staging isolation as a requirement and Gate 15 calls for failure
injection and a 48-hour soak against staging. **Both are unsafe as currently
provisioned**, and the reason is not a missing control — it is the existing
topology:

```
Cloud SQL instance  openagentsgemini:us-central1:sarah-postgres
  tier              db-f1-micro   (shared core, ~25 max connections)
  availability      ZONAL         (no HA)
  databases         sarah              <- PRODUCTION
                    sarah_staging
                    openagents_staging <- STAGING
```

Verified: Cloud Run service `sarah` (`DB_NAME=sarah`, `POOL_SIZE=5`) and service
`openagents-staging` (`DB_NAME=openagents_staging`, `POOL_SIZE=5`) both mount
`/cloudsql/openagentsgemini:us-central1:sarah-postgres`. The 3-node fleet
connects to the same instance as well.

Consequences the plan should state explicitly:

- Staging and production share one shared-core instance with a small connection
  budget. Staging load consumes production's connection headroom.
- Running Gate 15 failure injection or a 48-hour soak against staging is
  therefore **a load test against production's database instance.**
- A single-zone instance means one zonal event takes staging and production
  together, so staging cannot serve as evidence of production resilience.

This does not require solving production HA. It requires staging to get its own
instance before Gate 12 is claimed, and Gate 15 must not run until it does.
Gates 12 and 15 now state that hold explicitly.

## A3. Blocker: openagents.com migrations cannot replay onto a Sarah database

The ground rule "preserve historical migrations, correct live schema problems
with new migrations" is right, but there is a specific landmine underneath it
that Gate 13 (deploy to staging reproducibly) will hit again on any real data.

On 2026-08-19, migrate-on-boot was enabled and immediately crash-looped the
staging container:

```
== Running 20260816214000 OpenAgents.Repo.Migrations.CreateUsers.change/0 forward
   create table users
** (Postgrex.Error) ERROR 42P07 (duplicate_table) relation "users" already exists
```

The service pointed at `sarah_staging`, which already held Sarah's tables, while
openagents.com's `schema_migrations` had no record of its own versions — its
migration history is a **different lineage** (Sarah's 57 files versus this
repo's, with 18 of Sarah's consolidated into one). Staging was unblocked by
pointing it at a brand-new empty `openagents_staging` database.

That fix works for staging precisely because staging has no data worth keeping.
**It does not generalise.** Any future cutover onto a database Sarah created
needs a written lineage plan first: which of this repo's migrations are already
satisfied by the existing schema, how `schema_migrations` gets baselined so those
are marked run rather than replayed, and which are genuinely new. Treat the
staging crash as the cheap rehearsal it was. Gate 13 now separates empty
current-lineage targets from nonempty prior-lineage targets and requires the
baseline map and rehearsal before deployment.

## A4. Four places the plan disagrees with a prior decision or current state

These were originally flagged for deliberate choices. Gate 4 now records their
disposition: retain the owner-approved Heroicons fallback, keep staging
deliberately dark-only without a nonfunctional toggle, control the palette-file
rename as a visual migration, and reject conflicting cascade-layer behavior.

**Heroicons, resolved.** Product surfaces now use Apps SDK glyphs. Heroicons
remains the deliberate fallback, is pinned to an immutable revision, and has no
current product call sites. `docs/ICONS.md` governs and inventories exceptions.

**The palette is dark-only, resolved.** The application removed its theme
control, browser theme state, and theme selectors. A light palette remains a
separate owner-approved design project.

**The palette file, resolved.** `assets/css/openagents.css` owns the palette
contract and loads after individually imported Basecoat structure. The retired
compatibility aliases are gone. Future renames remain controlled palette
migrations, not cosmetic changes.

**Why DaisyUI had to be removed rather than layered under.** Recording this so a
similar library is not reintroduced under a different name: DaisyUI emits
component styles — a flat `.btn` setting `background-color`, `color`, and
`border-color` — into `@layer utilities`. That layer must remain last or every
Tailwind utility breaks. A later-declared layer beats an earlier one *regardless
of specificity*, so DaisyUI's `.btn` outranked every `.btn[data-variant=…]` rule
in `sarah.css` and all eight button variants rendered identically on staging.
There is no layer ordering that fixes this. **Any component library that emits
into `utilities` cannot coexist beneath a design system** — that is the
acceptance test for Gate 4's "one component system", not merely counting the
libraries in `mix.exs`.

**Cascade behavior, resolved.** `assets/test/css_contract_test.mjs` compiles the
actual bundle and checks selector order, variant survival, retired aliases, and
theme absence. The gate now verifies behavior rather than dependency names.

## A5. Evidence for Gate 5, from failures already observed

Gate 5's "fail closed" requirement is correct and this is what its absence
actually looked like in this codebase. Four config reads survived the
re-namespacing and kept reading the `:sarah` OTP app:

| module | effect |
| --- | --- |
| `inference_proxy_controller.ex:104` | raised — the only one that was visible |
| `plugs/forge_git_auth.ex:52` | **silent** — operator token always `nil`, every forge push 401'd |
| `tools/selector.ex:153` | **silent** — returned config default |
| `tools/embeddings.ex:127` | **silent** — returned config default |

Separately, `Tools.Registry.install!` reads
`Application.get_env(:openagents, :tools, [])` — note the `[]` default where the
upstream uses `fetch_env!`. With the key unset the node booted with an **empty
tool catalog**: 5,874 lines of tool code compiled and unreachable, no error.

Three of four failures were invisible. That is the argument for Gate 5. It now
requires `fetch_env!` instead of `get_env/3` for settings whose absence changes
behavior. A default that silently degrades is worse than a crash at boot, and
`DEGRADE-001` already forbids undeclared degradation.

The same class of bug hid a fourth: `forge_hot_load_allowlist` was configured
with repo *paths* (`"lib/openagents"`, `"config"`, `"mix.exs"`) while
`HotLoader.allowlisted?/2` matches *module names*. Every hot-load was refused as
`needs_rolling_replace` and nothing could reach `live`. **Hot loading did not
work at all in this repository** and no error said so. Gate 11 should require a
functional push→live proof, not a configuration review — a well-formed config
value of the wrong *kind* passes review and fails silently. Gate 11 now requires
that functional proof.

## A6. Gate 7 has a concrete existing violation

Gate 7 asks for repository and tenant scoping. One instance is already known and
is pinned in tests as current behaviour rather than fixed, because changing
authorization semantics needs an owner:

`OpenAgentsWeb.ProjectController` destructures `"username" => _username` in
`show`, `items`, `create_item`, `update_item`, and `fields` — all five ignore it.
Only `index` filters by owner. **A project owned by `alice` is readable and
writable at `/users/bob/projectsV2/:n`.** It is consistent across all five
actions, so it reads as deliberate simplification rather than oversight, but it
is an authorization gap and not merely a GitHub-shape mismatch.

Also relevant to Gate 7: `AssigneeController` is a hardcoded stub whose `index`
always returns `%{assignees: []}` and whose `show` always 404s, while
`POST .../issues/:n/assignees` accepts any login. No user is ever reported
assignable, yet anyone can be assigned. Gate 7 now names both behaviors as
blocking authorization work.

## A7. The recovery-worker gap is inherited, not created by the port

Gate 8 correctly requires direct tests for `TurnRecovery`, `VoiceRecovery`,
`WorkRecovery`, and `Memory.SemanticWorker`, and the production hold conditions
correctly block on it. One fact changes who can answer the design questions:

**Sarah has no tests for any of those four modules either.** Verified directly.
The port faithfully carried across a gap that already existed upstream.

Two implications. First, this is a longer-standing risk than the Issues and
Projects gap was, not a lesser one — it predates the merge. Second, there is no
upstream test suite to port or consult, so writing these means deriving intended
behaviour from the invariants (`TURN-005`, `WORK-001`, and `VOICE-009` all
describe recovery behaviour that should be assertable) rather than translating
existing assertions. Budget accordingly; this is design work, not porting.
