# Full codebase audit

**Date:** 2026-08-21
**Commit measured:** `abda46ab664e` (origin/main)
**Scope:** the entire repository: `lib/`, `test/`, `config/`, `assets/`, `priv/repo/migrations/`, `ops/`, `infra/`, `rel/`, and `docs/`
**Method:** manual review of representative and highest-risk modules in each layer, cross-checked with targeted searches. Every finding cites file paths and line numbers current at the measured commit.

---

## 0. Verdict

This is a high-discipline codebase with unusually strong documentation, OTP practice, and operational tooling for a pre-production project. The structural debt is real but concentrated in exactly three places, all sharing one root cause: text chat, voice, and delegated work grew parallel implementations of the same turn and tool-step machinery instead of sharing one.

The most important security gap is an unauthenticated denial-of-service vector in the forge git HTTP endpoint. The most important process gap is that nothing enforces the 83% coverage threshold or runs verification remotely; every guarantee depends on a developer's local machine running `ops/ci/gate.sh`.

| Metric | Value |
|---|---|
| Application modules (`lib/`) | 502 |
| Application LOC | ~90,000 |
| Test files | 233 (~44,700 LOC) |
| Migrations | 77 (all with rollback paths) |
| Measured line coverage (2026-08-20 audit) | 83.14% overall |
| TODO / FIXME / `IO.inspect` in `lib/` | 0 |
| Committed secrets found by sweep | none |

---

## 1. What this codebase is

OpenAgents is a Phoenix 1.8 application (~70 bounded contexts) that combines:

- A public website with GitHub-authenticated accounts, an issues/projects surface mirroring the GitHub REST API shape under `/api/v3`.
- A chat surface with inference turns, tool steps, and provenance capture.
- Voice sessions, delegated work jobs, and a SCV worker role.
- A forge: canonical git hosting over smart HTTP with scoped personal access tokens.
- A distributed runtime: Horde registries and supervisors across nodes, Raft (`:ra`) for cluster session ownership, hot-upgrade releases with appup generation.
- Staging infrastructure as Terraform with tests asserting its own security posture.

The web role and the SCV worker role boot different supervision trees from one codebase (`lib/openagents/application.ex`).

---

## 2. What is strong

These are verified strengths worth protecting as the codebase evolves.

### 2.1 Authorization design

- Visibility is enforced in SQL, not after loading. Public reads filter `repository.visibility == "public"` inside queries (`lib/openagents/repositories.ex:45`), so a forgotten filter fails closed rather than leaking rows.
- Every `/api/v3` write route sits behind a bearer-token pipeline requiring scope `forge:write` (`lib/openagents_web/router.ex:235`). Session-cookie routes keep CSRF protection without exemptions.
- Admin status re-verifies on every LiveView event, not just at mount (`lib/openagents_web/user_auth.ex:107`), closing the stale-socket elevation hole. Admin identity anchors on immutable numeric GitHub IDs.
- `RouteAuthority` (`lib/openagents_web/route_authority.ex`) is an executable inventory of every route's auth classification, and a test fails when a new route ships unclassified. This is a rare structural guardrail; keep it current.

### 2.2 Token and secret hygiene

- API tokens are 256-bit random secrets stored as SHA-256 digests with `redact: true`, returned to the caller exactly once, capped at 90-day lifetimes, compared with `Plug.Crypto.secure_compare` under `FOR UPDATE` row locks (`lib/openagents/api_tokens.ex:52`).
- The OAuth flow uses PKCE S256 with single-use server-side state digests and TTL pruning (`lib/openagents/github_oauth.ex:18`).
- Device-flow and machine-pairing flows store only digests, enforce single-claim semantics under row locks, and hand secrets over once.
- A repo-wide sweep for AWS keys, private key blocks, GitHub tokens, OpenAI-style keys, and credential-bearing URLs found nothing committed. Detection regexes exist where such strings appear, which is exactly right.
- Parameter filtering goes well beyond the Phoenix default: `authorization`, `verifier`, `poll_secret`, `transcript`, and more are scrubbed (`config/config.exs:10`). `OpenAgents.LogSafety` plus `ops/ci/private-log-scan.exs` scan logs in CI with the same detection rules the runtime uses.

### 2.3 OTP architecture

- Horde registry/supervisor pairs host cluster-wide singletons with `process_redistribution: :passive`; work jobs register under `{:work_job, job_id}` and treat `{:already_started, pid}` as success (`lib/openagents/work.ex:126`).
- `lib/openagents/cluster/session_registry.ex` is a pure `:ra_machine` holding ownership generations with fencing, so zombie writes are rejected structurally rather than by convention.
- Concurrency correctness leans on explicit row locks (`get_for_update!`) inside transactions — 105 `Repo.transaction` calls and 55 lock sites — instead of optimistic hope. Idempotent terminal paths handle races explicitly (for example `{:error, {:already_terminal, job}} -> {:ok, job}` at `lib/openagents/work.ex:525`).
- Feature-gated children enter the tree through clean `maybe_*` functions (`lib/openagents/runtime_supervisor.ex:54`); recovery workers run once at boot as `restart: :temporary`.

### 2.4 Testing culture

- Assertions target values and database state, not markup. LiveView tests click by DOM id or role, then assert on context state. Of roughly 400 selector-based interactions reviewed, only two page-level smoke checks assert raw HTML.
- No mock library anywhere. External services sit behind behaviour boundaries with configured test fakes; the forge integration test runs real git over real local HTTP against a temporary directory. The suite is network-free.
- Infra safety is pinned by ExUnit: `test/openagents/staging_candidate_contract_test.exs` reads the Terraform templates and asserts immutability, digest-pinned builder images, and absence of privileged flags. If someone loosens infra posture, tests fail before deploys do.
- The repository audited itself: [docs/2026-08-20-test-coverage-audit.md](2026-08-20-test-coverage-audit.md) measured 79.14% coverage, found the issues/projects layer at 33%, mapped the gap to exact TDD plan steps, added 279 tests, and published the receipts — including five defects the new tests caught.

### 2.5 Operations pipeline

- `ops/ci/gate.sh` runs thirteen stages (compile, production compile, precommit, cluster tests, JavaScript tests, relup proof, contracts, staging infra validation, release smoke) and writes a schema-versioned receipt keyed by SHA into `.git/openagents/release-gate-receipts/`. Downstream scripts verify receipts before building or promoting anything.
- `ops/deploy/build-image.sh` refuses dirty worktrees, requires the gate receipt, sets reproducible timestamps, then runs Erlang inside the built image to assert the embedded revision matches the git SHA.
- Container builds are digest-pinned, run as a non-root user, and install npm dependencies with scripts disabled. `.dockerignore` excludes `.env*`, `*.pem`, and `*.key`, so secret-shaped files cannot enter the build context by accident.
- Terraform uses write-only ephemeral database passwords, least-privilege custom IAM roles, private-only Cloud SQL, immutable tags, and bucket public-access prevention — asserted by `tftest` files under `infra/staging/tests/`.

### 2.6 Code hygiene

Zero `TODO`/`FIXME` markers, zero debug prints, effectively no commented-out code, shallow nesting throughout even in long functions, and moduledocs that explain rationale and cite invariants from [INVARIANTS.md](../INVARIANTS.md). All 77 migrations have rollback paths; none disable DDL transactions or migration locks.

---

## 3. Security findings

Ordered by severity. Each item names the fix owner area and concrete remediation.

### 3.1 Summary

| ID | Severity | Finding |
|---|---|---|
| S1 | High | Unauthenticated gzip decompression bomb on anonymous `git-upload-pack` |
| S2 | Medium | Comment update/delete ignores comment authorship |
| S3 | Medium | No rate limiting on unauthenticated table-inserting endpoints |
| S4 | Medium-low | Fleet container disables seccomp and AppArmor |
| S5 | Low | Client-controllable bookkeeping fields survive issue/comment creation |
| S6 | Low | Malformed numeric path segments return 500 instead of 404 |
| S7 | Low | CSP allows any websocket origin and inline styles; no `form-action` |
| S8 | Low | `OPENAGENTS_SECURE_COOKIES` evaluated at compile time |
| S9 | Low | Origin allowlist validator exists but is dead code |
| S10 | Low | Machine bearer token travels in websocket query string |
| S11 | Low | One-year session lifetime without step-up on sensitive actions |
| S12 | Informational | Health endpoints disclose build revision publicly |

### 3.2 Details

**S1 — gzip bomb on anonymous `git-upload-pack` (high)**

`lib/openagents/forge/git_http.ex` caps compressed input at 512 MiB (`@max_body_bytes`, line 30) but authorization runs before the body is read, so anonymous clients can POST gzip-encoded bodies to any public repo's `git-upload-pack`. `safe_gunzip/1` (line 354) calls `:zlib.gunzip/1`, materializing the full decompressed output in the request heap with no output cap. DEFLATE ratios near 1000:1 allow multi-hundred-GiB logical expansion, ending in an OOM kill of the BEAM. Remote, unauthenticated, trivially scriptable.

Remediation: stream-decompress with a hard byte cap using incremental inflation (`:zlib.safeInflate` chunked loops), reject beyond a fixed decompressed limit, and apply the same bound to `receive-pack`. Alternatively drop `content-encoding` handling entirely and require authentication for `upload-pack`.

**S2 — comment authorship ignored on update/delete (medium)**

`CommentController.update/2` and `delete/2` (`lib/openagents_web/controllers/comment_controller.ex:62`) resolve a writable repo membership and then call `Issues.update_comment/2` with no check that the acting principal wrote the comment (`lib/openagents/issues.ex:304`). Any member with `contributor` or above can rewrite or delete anyone's comment while the rendered JSON keeps the original author snapshot — silent impersonation within a repository, diverging from the mirrored GitHub contract.

Remediation: compare `comment.author_user_id` against the acting principal; allow only the author or elevated roles (`owner`/`maintainer`); return 404 otherwise to avoid enumeration.

**S3 — unthrottled unauthenticated insert paths (medium)**

The only rate limits in the tree cover chat turns, voice admission, and device-flow slow-down polling. Nothing throttles `POST /api/v3/device/authorizations` (one row per call, 600-second TTL), controller pairings, or `POST /auth/github` (rows retained up to 24 hours, `lib/openagents/accounts.ex:194`). Anonymous clients can inflate these tables and amplify database load.

Remediation: add an IP-scoped throttling plug in front of pairing, device authorization, and OAuth start; cap pending rows per source; add modest quotas on public `/api/v3` reads.

**S4 — container isolation disabled (medium-low)**

`infra/staging/templates/fleet-startup.sh.tftpl:200` passes `--security-opt seccomp=unconfined --security-opt apparmor=unconfined` plus host networking, apparently as a Bubblewrap workaround. Remediation: author a tailored seccomp profile permitting only the namespace syscalls Bubblewrap needs, restoring layered defense.

**S5 — mass assignment on create paths (low)**

`Issue.changeset/2` casts `state`, `locked`, `closed_at`, and `comments`; `Comment.changeset/2` casts `created_at` (`lib/openagents/issues/issue.ex:30`, `comment.ex:20`). Writers can create pre-closed issues with fabricated timestamps or backdated comment provenance. Update paths correctly drop identity fields. Remediation: whitelist client-settable fields on create; derive counters and closure timestamps server-side.

**S6 — malformed identifiers produce 500s (low)**

Routes carry no numeric constraints, and handlers call bare `String.to_integer/1` (`issue_controller.ex:40`, `comment_controller.ex:13`, four more files). `GET /api/v3/repos/o/r/issues/abc` raises `ArgumentError`, escaping the `Ecto.NoResultsError` rescues. Remediation: use `Integer.parse/1` plus explicit 404, as `ProjectController.cast_issue_number/1` already does, or add route segment constraints.

**S7 — CSP looseness (low)**

`connect-src ws: wss:` permits page-context connections to any websocket host (`lib/openagents_web/plugs/content_security_policy.ex:25`); `'unsafe-inline'` remains in `style-src`; `form-action` is absent. Everything else is strong: nonce'd scripts, `frame-ancestors 'none'`, `object-src 'none'`. Remediation: restrict websockets to same-origin or named dev hosts behind an environment conditional; add `form-action 'self'`.

**S8–S12 (low/informational)**

- `secure: Application.compile_env(...)` bakes cookie security at compile time (`lib/openagents_web/endpoint.ex:13`), making the runtime env var misleading. Read it at request time or document it as build-time.
- `OpenAgentsWeb.AllowedOrigins.for_production/2` validates https-only origins precisely for `check_origin`, but nothing calls it; raw CSV flows straight from env to config (`config/runtime.exs:410`). Wire it up and fail boot on invalid entries.
- Machine websocket tokens arrive as connect params, landing in proxy access logs (`controller_socket.ex:18`). Move to a subprotocol header or first-message handshake.
- Sessions last 365 days (`endpoint.ex:15`) with no recent-auth requirement for token issuance or data deletion. Shorten the window or add step-up.
- `/health` returns the build revision publicly (`health_controller.ex:7`); gate it behind operator auth.

### 3.3 Explicit non-findings

Checked and found sound: no missing auth on sensitive routes; no IDOR on the GitHub-style surface (public reads filtered in SQL; writes resolve writable membership per request); no CORS emissions anywhere; no CSRF exemptions; production `secret_key_base` required at boot; dev-only routes compiled out of other environments; OAuth redirect URIs pinned to https and `PHX_HOST` in production.

---

## 4. Code quality and smells

### 4.1 The root cause: three parallel turn/tool implementations

The same algorithm — validate arguments, digest, lock the parent row, dedupe by provider call id, sequence-check, insert a `"requested"` step — exists three times:

- `Conversations.request_tool_step/3` (`lib/openagents/conversations.ex:515`)
- `Voice.request_tool_step/2` (`lib/openagents/voice.ex:662`)
- `Work.request_job_step/2` (`lib/openagents/work.ex:298`)

Helpers are copy-pasted between them (`validate_raw_tool_arguments`, `tool_argument_digest`, `merge_refs` — the last byte-identical between conversations and voice). Drift has already happened:

- Argument size caps differ silently: 262,144 bytes for text turns versus 16,384 for voice, with no recorded decision.
- `Conversations.ToolStep` carries artifact and executor digests that `Voice.ToolStep` lacks, so voice outcomes skip digest verification that text turns enforce.

This is the highest-value refactor available: extract one shared ledger module or behaviour, make the tier differences explicit parameters, and force the divergence decisions into writing. Estimated effort: two to four days.

### 4.2 Oversized modules

| Module | Lines | Assessment |
|---|---|---|
| `ComponentsLive` | 2,639 | ~83 homogeneous demo clauses plus fixture data. Inert gallery content; splitting buys little. Lowest priority. |
| `ChatLive` | 1,897 | Genuine problem. One LiveView owns transcript, voice-session state, delegation-rail state machine, computer-live streaming (four dedicated `handle_info` clauses), and sidebar projections. `render/1` alone spans 502 lines. Split the delegation rail and computer-live panel into LiveComponents or extracted function-component modules. Two to three days. |
| `Voice` | 1,702 | Context plus admission control, rate limiting, its own tool ledger, and broadcast plumbing. Shrinks naturally if the shared ledger lands. |
| `Conversations` | 1,687 | Fat context carrying six responsibilities. `begin_inference/5` runs 131 lines; `request_tool_step/3` 112; `finish_turn/8` 100. The long functions are coherent but should shed the ~300 lines of provenance validators (`conversations.ex:1410`) into a capture module, and rate limiting into a helper. One to two days. |

### 4.3 Orphaned subsystem

`OpenAgents.Compensation` (`compensation.ex`, 554 lines, plus seven schemas under `compensation/`) has zero references outside itself and its own test file. Either wire it into a supervisor and product flow or delete it. Half a day including the migration cleanup decision.

### 4.4 Minor smells

- The recovery trio (`turn_recovery.ex`, `voice_recovery.ex`, `work_recovery.ex`) is structurally identical; one parameterized module would replace all three in under an hour. Defensible as-is given their size, but consolidation removes drift risk.
- `Issues.repository_stub/1` (`issues.ex:517`) fabricates `%Repository{}` structs as query tokens to satisfy pattern-matched helpers — a smell suggesting those helpers should take ids directly.
- Issue labels/assignees/milestones live both as denormalized JSON snapshots and join-table rows, with the dual-write hidden inside `Issues`. Pragmatic for API mirroring; document the invariant or centralize it.
- The `eventually/2` polling helper is duplicated across at least twelve test files; move it to `test/support`.

### 4.5 What is NOT wrong

No dead code beyond Compensation (checked `data_rights`, `diff`, `markdown` — all alive). No business logic leaks into controllers; they delegate to contexts and map results to statuses. Nesting stays shallow everywhere because transaction pipelines stay flat. Error handling converts exceptions to tuples or logs them at all but seven sites, each of which swallows deliberately with a comment explaining why.

---

## 5. Testing

### 5.1 State of play

233 test files against 502 modules, with measured coverage at 83.14% after the 2026-08-20 remediation wave. Domain schemas for the issues/projects surface sit at 100%. Recovery workers flagged in the earlier audit now have direct tests.

### 5.2 Gaps

1. **The coverage floor gates nothing.** `mix.exs` declares `threshold: 83.0`, and `ops/ci/coverage.sh` correctly unions default and cluster-only passes, but neither `mix precommit` nor `gate.sh` invokes the script. Add a coverage stage to the gate.
2. **No hosted CI.** Verification depends entirely on developers running the pre-push hook locally; nothing remote proves a push passed the gate. This is documented as deliberate, and the receipt system makes external attestation easy to add later — but today the guarantee is trust-based.
3. **Contexts without same-name tests.** Verified list includes `Audit`, `Mailer`, `BuildInfo`, `ComputerAgentJobs`, `ReleaseState`, `TurnRecovery` (covered indirectly), among others. `Audit` appears in only one indirect test; `Mailer` has zero test references.
4. **A known cross-user authorization gap is pinned as expected behavior.** Per the coverage audit, `ProjectController` ignores the `:username` segment, so a project owned by alice is readable and writable at `/users/bob/projectsV2/:n`. Tests deliberately document the divergence instead of fixing it. Decide: either implement username scoping or remove the segment from the contract.
5. **Test-rule violations.** Seven bare `Process.sleep/1` call sites contradict the repository's own testing rules (`coding_job_test.exs:118`, `computer_tools_test.exs:43`, `registry_and_runner_test.exs:39`, `builder_test.exs:266`, `ra_cluster_test.exs:160` and neighbors). Replace with monitors or the shared `eventually` helper.
6. **Async tagging is inconsistent**: 76 files tagged `async: true`, 109 tagged false, 48 untagged. Some serialization is likely habitual rather than required; audit and tag deliberately.

---

## 6. Infrastructure and deployment

### 6.1 Strengths

Reproducible, digest-pinned builds verified from the inside out; a receipt chain from gate to build to production preflight; fail-fast runtime configuration where every secret is required-or-explicitly-optional and integers are range-validated; staging evidence artifacts scanned for credentials before acceptance (`ops/staging/scan-evidence.sh`); complete migration rollback coverage including a heavyweight tenant-scoping backfill that fails closed via SQL exception if any row lacks a match (`priv/repo/migrations/20260820082100_add_repository_tenant_scoping.exs`).

### 6.2 Weaknesses

1. **Container isolation disabled** (see S4).
2. **Instance service accounts carry `cloud-platform` scopes**, broader than the IAM grants require. Narrow to storage, secret manager, and Cloud SQL admin scopes actually used.
3. **Transactional whole-table backfills are a future hazard.** The tenant-scoping migration updates six tables and rebuilds indexes inside one transaction. Fine at current scale; replaying this shape against large production tables risks lock storms. For post-cutover migrations, prefer batched backfills with `RETURNING BATCHES`-style loops.
4. **No container `HEALTHCHECK`**, and `curl` and `git` ship in the final image without documented justification. Add a healthcheck and prune or justify extra binaries.
5. **Cosmetics**: the LiveView signing salt is a committed generator value (`config/config.exs:260`); rotate per environment for defense-in-depth. Dev falls back to a checked-in token-vault encryption key (`config/dev.exs:36`) — documented as intentional and prod-safe, but a developer pointing dev at production GitHub apps encrypts real tokens under a public key; consider refusing the fallback when the configured OAuth client looks production-shaped. `config/dev.exs:19` embeds a personal username fallback.

---

## 7. Documentation

Exceptional by any standard. Every doc carries a status header enforced by script; `docs-check.exs` validates every markdown link, bans retired terms, and checks the invariant ledger for duplicate ids, missing proofs, and stale module references. `INVARIANTS.md` holds 74 numbered invariants spanning identity, memory, turns, tools, work, voice, and release, and moduledocs cite them by id. Seven ADRs record the load-bearing decisions. The dated audit/runbook trail shows a team publishing its own defects with receipts.

One gap: documentation describes intent better than operations-by-numbers. There is no capacity/planning doc stating expected scale (concurrent sessions, repository counts, message volumes) — which matters because several of the hazards above (backfill locking, rate-limit absence, gunzip exposure) change severity with scale. Adding an expectations section to [docs/architecture.md](architecture.md) would let reviewers weigh these tradeoffs correctly.

---

## 8. Prioritized remediation plan

Do these in order. Items 1–3 are small and contained; items 4–6 are the strategic debt paydown.

1. **Cap git-body decompression (S1).** Stream-decompress with hard output bounds in `read_git_body`/`safe_gunzip`. Hours, closes the only remotely exploitable DoS.
2. **Enforce comment authorship (S2).** Author-or-elevated check in both comment write actions. An hour.
3. **Wire the orphaned guardrails.** Call `AllowedOrigins.for_production/2` from `runtime.exs`; add the coverage stage to `gate.sh`; read `secure_cookies` at runtime. Half a day total, converts existing good intentions into enforcement.
4. **Extract the shared tool-step ledger** across conversations/voice/work (section 4.1). Two to four days. Highest refactor value: eliminates the triplication, forces the size-cap and digest-tier decisions to be explicit, and shrinks both fat contexts.
5. **Split `ChatLive`** — delegation rail and computer-live panel into LiveComponents; extract render sections. Two to three days.
6. **Throttle unauthenticated inserts (S3) and decide the ProjectController username question (section 5.2 item 4).** Both are product decisions with small implementations.
7. **Hygiene pass:** integer parsing (S6), CSP tightening (S7), create-path whitelisting (S5), Compensation fate (4.3), recovery-trio consolidation, bare-sleep removal, async tagging, narrow IAM scopes, tailored seccomp profile.

---

## 9. Closing assessment

Measured against its own stated standards — the invariants ledger, the gate receipts, the TDD workflow — this codebase mostly keeps its promises, and where it does not, it says so in writing. The weaknesses found here are concentration problems, not culture problems: one unshared algorithm replicated three ways, verification power trapped on developer laptops, and isolation shortcuts taken for staging convenience. Each has a contained fix, and the repository's own machinery (receipts, contract tests, docs linting) is exactly the right toolkit to land them.
