# API rename audit: /api/v3 to /api/v1

Audit for issue #211. The API lives at `/api/v3` because it began by aiming at
parity with GitHub's v3 REST API, but the version in the path reads as this
API's own version, and this API is at its first version. This document records
every surface the rename touches, what breaks between the server rename and
the CLI release, and the recommended sequencing. Backward compatibility is not
required — there are no external users — but internal consumers that would
break mid-deploy are inventoried.

All counts are pinned to specific commits, because both repositories are under
concurrent edit:

- `openagents.com` at `28aece5` ("Refuse a backdated issuer key retirement
  instead of unverifying history").
- `openagents` monorepo at `022ebbd933`.

## Headline numbers

| Surface | Files | Hits |
| --- | --- | --- |
| Phoenix repo, total tracked | 134 | 1,534 |
| Phoenix `lib/` | 30 | 366 |
| Phoenix `test/` | 52 | 768 |
| Phoenix `docs/` | 34 | 210 |
| Phoenix `priv/` (site docs and contract) | 14 | 150 |
| Phoenix root (`AGENTS.md` 11, `INVARIANTS.md` 25, `README.md` 1) and `.agents/` (3) | 4 | 40 |
| Monorepo, total tracked | 26 | 118 |
| Monorepo `packages/openagents-cli` | 25 | ~115 |
| Monorepo elsewhere (`docs/teardowns/`) | 1 | 3 |

Every hit is the literal string `api/v3`. There is no other spelling of the
version in code: the only non-path occurrences in `lib/` are doc comments in
`ApiRouteAuthority` and the `"api_version" => "v3"` field in
`lib/openagents_web/controllers/api_extension_controller.ex:383`.

## Phoenix repo inventory

### Router

`lib/openagents_web/router.ex` mounts 23 `scope` blocks that begin with
`/api/v3` (21 hits; two scopes carry longer prefixes such as
`/api/v3/conversations/:conversation_id/boxes`). The unversioned scopes
(`/api`, `/api/operator`, `/api/contracts/...`, `/controller/...`) are outside
the rename.

### Route authority inventories

- `lib/openagents_web/api_route_authority.ex` (185 hits) is the single
  authority inventory for every `/api/v3` route: each entry is a literal
  `"METHOD /api/v3/..."` key carrying principal, family, and error contract.
  `test/openagents_web/api_route_authority_test.exs` proves the inventory and
  the router agree, so the rename must change the router and this table in the
  same commit or CI fails.
- `lib/openagents_web/route_authority.ex` (58 hits) classifies every Phoenix
  route including the API surface, with the same CI-enforced agreement
  (`test/openagents_web/route_authority_test.exs`, 49 hits).

### The GET /api/v3 root document and error envelope

- `lib/openagents_web/controllers/api_extension_controller.ex` (22 hits)
  publishes the root document: endpoint strings per family, extension
  descriptors, and the `"api_version" => "v3"` field at line 383, which
  becomes `"v1"`.
- `lib/openagents_web/api_error.ex` builds `documentation_url` from
  `Endpoint.url() <> "/api/v3"` at line 194, so every refusal envelope links
  to the root document. One line, but it appears in every error response.

### Links generated into responses

JSON views interpolate the path into `url` fields the API returns:

- `lib/openagents_web/controllers/issue_json.ex` (issue and pull URLs)
- `lib/openagents_web/controllers/stack_json.ex` (stack, pull, and
  merge-async operation URLs)
- `lib/openagents_web/controllers/pull_request_json.ex`
- `lib/openagents_web/controllers/label_json.ex`
- `lib/openagents_web/controllers/milestone_json.ex`
- `lib/openagents_web/controllers/project_json.ex`
- `lib/openagents_web/controllers/fleet_target_controller.ex`
  (`~p"/api/v3/admin/forge/targets/..."`)

Because these are interpolated at render time, they emit the new path the
moment the code deploys. Nothing stores an `/api/v3` URL in the database.

### Push receipts

`lib/openagents/forge/git_http.ex:477` appends the WAL receipt to the
side-band output that `git push` prints:

```
openagents wal-receipt seq=N link=HASH (GET /api/v3/repos/OWNER/REPO/pushes/N)
```

The `link` value is a WAL chain hash, not a URL, so only the parenthesized
`GET` path changes — one line. Receipts already printed into old terminal
scrollback and transcripts will name a path that stops existing after the
alias is removed; that is acceptable, since the durable identity of a receipt
is `seq` plus `link`, not the hint path.

### Contracts and manifests

- `priv/api-contracts/repositories-v1.json` (15 hits) names routes as
  `"METHOD /api/v3/..."` strings. It is served at
  `GET /api/contracts/repositories-v1.json` — the serving route itself is
  unversioned and does not change.
- The same file is vendored in the CLI at
  `packages/openagents-cli/contracts/repositories-v1.json`, and
  `packages/openagents-cli/src/api-contract.ts` pins its SHA-256
  (`REPOSITORY_CONTRACT_SHA256`), enforced by
  `test/api-contract.test.ts`. Renaming the paths inside the contract
  changes the bytes, so both copies and the pinned hash must move together.
- There is no OpenAPI document; the extension document at the API root and
  the contribution contract are the machine-readable manifests.

### The agent front door

`lib/openagents_web/contribution_contract.ex` (28 hits) generates the
standing instructions served at `openagents.com/agents.md` and its JSON
twin, listing `/api/v3` entry points. The rename flows through automatically
once this module changes; agents that cached the old page re-read it on
their next visit.

### UI and LiveView

Two user-facing occurrences:

- `lib/openagents_web/live/home_live.ex:544` — FAQ copy: "served under
  `/api/v3`. An existing client usually needs only a base URL change."
- `lib/openagents_web/live/thread_index_live.ex:51` — empty-state hint
  naming `POST /api/v3/threads`.

Both are copy changes and need explicit sign-off under the repo's
copy-change rule.

### Data-rights export inventory

`lib/openagents/data_rights/export_inventory.ex` (13 hits) names the
`/api/v3` route for each export mechanism, pinned by
`test/openagents/data_rights/export_inventory_test.exs` (11 hits).

### Site docs, repo docs, and skills

- `priv/docs/` (150 hits, 14 files) is the documentation served at `/docs`;
  `rest-api.md` alone carries 88 hits, `stacks-api.md` 20.
- `docs/` (210 hits, 34 files) — design docs, audits, runbooks. Historical
  audits can keep their `/api/v3` text with a dated note; live references
  (for example `docs/api-authentication.md`,
  `docs/github-api-issues-projects-assessment.md`) should be updated.
- `.agents/skills/openagents-work-management/SKILL.md` (3 hits) instructs
  agents that relative `openagents api` paths resolve under `/api/v3/`.
- `AGENTS.md` (11 hits, `CLAUDE.md` is a symlink to it), `INVARIANTS.md`
  (25 hits), `README.md` (1 hit).

### Tests

52 test files, 768 hits, all literal request paths
(`~p"/api/v3/..."` and string paths). Largest:
`project_controller_test.exs` (114), `issue_controller_test.exs` (74),
`thread_controller_test.exs` (73), `forum_api_controller_test.exs` (55),
`route_authority_test.exs` (49). All mechanical.

## Monorepo inventory

All 26 files with hits sit in `packages/openagents-cli` except one teardown
doc (`docs/teardowns/2026-08-23-openagents-coder-tui-agent-fleet-port-plan.md`,
historical). No other package or app in the monorepo calls the `/api/v3`
surface.

### The path is not one constant

`src/endpoint.ts` resolves only the **origin** (profile or `--api-url`); it
rejects any URL that carries a path. The version segment is scattered:

- `src/api-passthrough.ts:10` — `API_BASE_PATH = "/api/v3/"`, the resolver
  for `openagents api` relative paths.
- `src/coder-thread.ts:69`, `src/coder-resume.ts:42`,
  `src/coder-transcript.ts:22` — three separate
  `THREADS_PATH = "/api/v3/threads"` constants for the coder lane, resume
  picker, and transcript writer.
- `src/tracker-request.ts:103` — the `/api/v3/repos/{owner}/{repo}` base
  that `issue-client.ts` and `project-client.ts` build on.
- `src/repository-client.ts` (12 literals), `src/forum-client.ts` (7),
  `src/device-client.ts` (2, the device-authorization pairing flow).
- `src/coder-backends.ts`, `src/coder-skills.ts`, `src/cli.ts` — comments
  and one skill-text line.

### Shipped artifacts

The published npm package (`@openagentsinc/cli`, `files: ["dist",
"contracts", "README.md", "skills"]`) ships:

- `contracts/repositories-v1.json` with the `/api/v3` route strings and the
  SHA-256 pin in `src/api-contract.ts` (see the contract section above).
- `skills/openagents-cli/SKILL.MD` telling agents that bare `openagents api`
  paths resolve under `/api/v3/`.

The published version on npm is `0.3.5`, identical to the repo `HEAD`
version, so **every installed CLI in existence hardcodes `/api/v3`**.

### Surfaces that do not change

- The git credential helper (`src/git-credential-helper.ts`) matches on
  origin only, and the helper line written into git config is
  `!openagents --api-url ORIGIN auth git-credential` — no path. It keeps
  working across the rename as long as the installed binary is current;
  the helper itself makes no `/api/v3` request.
- Machine pairing (`src/computer-client.ts`) calls `/controller/pairings`
  and `/controller/status`, which are outside the versioned scope.
- The Phoenix contract route `GET /api/contracts/repositories-v1.json` is
  unversioned; only the strings inside the body change.

## The GitHub-compatibility question

**Verdict: octokit depends only on response shape plus an explicit base URL;
`gh` depends on the literal `/api/v3` path segment for any non-github.com
host.**

Evidence:

- The installed `gh` binary (v2.89.0, built on `go-gh` v2.13.0) contains the
  hardcoded format string `https://%s/api/v3/` alongside
  `https://%s/api/graphql`. This is `go-gh`'s REST prefix: when `GH_HOST`
  names any host other than github.com, `gh` constructs REST URLs as
  `https://HOST/api/v3/...` with no way to override the path segment. A
  forge that wants `GH_HOST=openagents.com gh ...` to work must serve
  `/api/v3` at that literal path.
- Octokit takes a full `baseUrl` (for GitHub Enterprise Server the
  documented value is `https://HOST/api/v3`); the version segment is part
  of caller configuration, not the client. Only the response shape and
  headers matter.
- The repo's own stated posture already stops short of drop-in tooling:
  `docs/github-api-issues-projects-assessment.md:390` and
  `priv/docs/rest-api.md:346` say pagination and link headers "do not
  provide complete Octokit or `gh` parity", and the homepage FAQ promises
  only "a base URL change" — the octokit story, not the `gh` story.
- One doc overstates it: `docs/episode-triage.md:1207` says the shape means
  "`gh` and octokit work unchanged". After the rename that stays true for
  octokit and becomes false for `gh` against a custom host, unless a
  permanent `/api/v3` alias is kept.

The rename therefore forfeits hypothetical `GH_HOST`-style `gh` drop-in
compatibility. Nothing in either repo currently exercises `gh` against
openagents.com, so this is a posture decision to record, not a breakage.

## Mid-deploy breakage analysis

Ordered by severity, for a hard cutover with no alias:

1. **Every installed CLI breaks.** Published `0.3.5` equals repo `HEAD`;
   all issue, project, repo, forum, `api`, coder, resume, and device-pairing
   commands 404 until the user updates to a release that targets `/api/v1`.
   The server cannot be renamed before that release exists, and the release
   cannot ship before the server serves `/api/v1` — a deadlock unless one
   deploy serves both.
2. **In-flight coder sessions die.** A running `openagents coder` session
   holds a thread grant and appends events to
   `POST /api/v3/threads/{id}/events`; long sessions span deploys. A hard
   cutover mid-session breaks transcript writes and the exit-time
   `DELETE /api/v3/threads/{id}` revocation.
3. **Agent instructions go stale.** The served `agents.md`, the skill inside
   the npm package, and `.agents/skills/openagents-work-management` all name
   `/api/v3`. Agents following cached instructions 404 until they re-read.
4. **Push receipt hint paths.** New pushes print the new path immediately
   (rendered, not stored). Old receipts in scrollback and transcripts point
   at a dead path once v3 stops answering; the WAL `seq`/`link` identity is
   unaffected.
5. **Not affected:** the git credential helper (origin-only), machine
   pairing (`/controller/*`), the contract-serving route
   (`/api/contracts/...`), and the database (no stored `/api/v3` URLs).

## Recommended sequencing

Serve both paths for one deploy, as a pure alias, then delete it. The alias
costs roughly 20 lines and one deploy of patience; a hard cutover saves those
lines but breaks every installed CLI and every in-flight coder thread during
the window between the server deploy and the npm publish. Given the deadlock
in breakage item 1, the alias is the cheapest ordering that never leaves a
consumer without a working path.

1. **Phoenix, one commit: rename to `/api/v1` and alias `/api/v3`.**
   Mechanical rename across router, `ApiRouteAuthority`, `RouteAuthority`,
   controllers, JSON views, `ApiError`, `ContributionContract`, the
   extension document (`api_version: "v1"`), the push-receipt line, the
   export inventory, `priv/api-contracts/repositories-v1.json`, `priv/docs`,
   tests, `AGENTS.md`, `INVARIANTS.md`, and `.agents/skills`. Add one plug
   ahead of the router that rewrites `path_info` `["api", "v3" | rest]` to
   `["api", "v1" | rest]` — a transparent rewrite, not a redirect, because
   old clients POST and do not follow redirects reliably. The router stays
   single-sourced at `/api/v1`, so the authority tests keep proving the real
   surface; one test pins the alias. All generated links and receipts emit
   `/api/v1` from this deploy on.
2. **Monorepo: point the CLI at `/api/v1`, publish `0.4.0`.** Update the
   scattered literals (or, better, route them through one exported
   constant), regenerate `contracts/repositories-v1.json` and
   `REPOSITORY_CONTRACT_SHA256`, update the shipped skill and README, bump,
   publish. Old `0.3.5` installs keep working through the alias; new
   installs use v1 natively.
3. **Update instructions and docs in both repos** (served docs are part of
   step 1's commit; monorepo docs ride step 2). Decide the `gh` posture
   explicitly: correct `docs/episode-triage.md`'s "gh works unchanged"
   claim, or commit to a permanent `/api/v3` alias for `GH_HOST` drop-in.
4. **Delete the alias** once the fleet's installed CLIs are `>= 0.4.0` —
   remove the plug and its test. If step 3 chose to keep `gh` drop-in,
   skip this step and record the alias as permanent in `INVARIANTS.md`.

## Estimated diff size

- **Phoenix**: about 1,530 single-line textual changes across ~134 files —
  a mechanical `sed` plus `mix precommit`, with three files needing thought:
  the router (23 scopes plus the alias plug), `api_extension_controller.ex`
  (`api_version` field), and the two LiveView copy lines (copy sign-off).
  Net new code: the rewrite plug (~20 lines) and one alias test.
- **Monorepo**: about 115 single-line changes across 25 files in
  `packages/openagents-cli`, plus the contract SHA recompute, a version
  bump, and an npm publish. Optional consolidation of the path constants
  adds a small refactor.

## Follow-up issues

1. **Rename the API surface to `/api/v1` and alias `/api/v3`** — Phoenix
   serves the whole surface at `/api/v1`, emits v1 links and receipts, and
   transparently rewrites `/api/v3` requests, all in one deploy.
2. **Ship CLI `0.4.0` targeting `/api/v1`** — every hardcoded path, the
   vendored contract and its SHA pin, and the shipped skill name v1;
   published to npm.
3. **Consolidate the CLI's API base path into one constant** — the coder
   thread, resume, transcript, tracker, repository, forum, and device
   clients all import a single versioned base, so the next rename is one
   line.
4. **Decide and record the `gh` compatibility posture** — either correct
   the "gh works unchanged" claim in `docs/episode-triage.md` and the
   compat framing, or make the `/api/v3` alias permanent for `GH_HOST`
   drop-in; record the choice in `INVARIANTS.md`.
5. **Delete the `/api/v3` alias** — after confirming installed CLIs are
   `>= 0.4.0`, remove the rewrite plug and its test (skipped if issue 4
   keeps the alias).
6. **Sweep remaining `/api/v3` references in docs and skills** — update
   live docs in both repos and annotate historical audits, so no standing
   instruction names the dead path.
