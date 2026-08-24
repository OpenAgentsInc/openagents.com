# OpenAgents invariant ledger

These contracts define the OpenAgents application. Every entry is explicitly
`Current` or `Proposed`. A current contract must name an executable test or a
concrete manual proof whose file exists in this repository. A proposed
contract describes a release gate, not current behavior, and cannot be used as
evidence that a feature is safe or enabled.

A change to a listed contract must update this ledger and its named proof in
the same commit. `ops/ci/docs-check.exs` verifies unique IDs and evidence-file
paths.

A proof must be capable of failing for the claim it names. `docs/taxonomy.md`
naming rule 7 says a contract is not true until its proof runs green; this is
its companion, because a green proof of the wrong population says nothing. A
contract that quantifies — "no route", "every surface", "nothing", "only" —
needs a proof that derives the population from something the code cannot lie
about: the router, `OpenAgentsWeb.RouteAuthority`,
`OpenAgentsWeb.ApiRouteAuthority`, a compiled BEAM import table, a database
constraint, a configuration list, or the repository tree. A test of the
surfaces someone thought of cannot fail on the surface they did not, so it is
green exactly when it would be most useful. Where enumeration is impractical,
narrow the claim to what its proof covers: a smaller true statement beats a
larger unprovable one. `docs/2026-08-23-invariant-proof-audit.md` classifies
every contract here against that rule and records what remains.

## OpenAgents identity and canon

### CANON-001 — Persona sources are immutable and status-labeled

Status: Current

Every historical source admitted to author OpenAgents's persona is pinned by
repository revision, path, content SHA-256, source status, admitted uses, and
explicit exclusions. The complete manifest has a canonical digest admitted by
the application and is validated before the supervision tree starts. Founder
direction, retired product material, unscheduled drafts, and scoped
performances cannot silently become runtime authority or ordinary voice.

Episode numbers are not source identity. The conflicting Episode 263 file is
quarantined, and the final Omega Alpha transcript is pinned by its actual path.

Evidence: `OpenAgents.Persona.SourceManifest`,
`priv/sarah/persona/sarah.v1.sources.json`, and
`OpenAgents.Persona.SourceManifestTest`.

### PERSONA-001 — Each inference uses one immutable persona artifact

Status: Current

OpenAgents's core identity, voice, and first-conversation greeting come from one
versioned artifact admitted by its exact content SHA-256. The artifact and its
source-manifest identity are validated and installed before the supervision
tree starts. Every provider request receives instructions composed from that
installed artifact; provider adapters contain no independent OpenAgents persona.

Evidence: `OpenAgents.Persona`, `priv/sarah/persona/sarah.v1.md`,
`OpenAgents.Context.Composer`, `OpenAgents.Turns.TurnServer`, and `OpenAgents.PersonaTest`.

### PERSONA-002 — One core OpenAgents identity composes with an admitted role

Status: Current

Protected identity and host safety precede surface truths, the selected role,
Blueprint expression facts, captured capabilities, and recalled evidence in a
deterministic composition. The public application selects only
`general_collaborator.v1`. Role selection accepts only typed host surface,
authority, request, and capability inputs; its canonical input/catalog receipt
is persisted immutably for text turns and voice sessions. User text, Blueprint,
profile memory, and bounded recalled evidence cannot select a role or replace
protected layers. Inactive coding, sales, company-operations, and public-
broadcast registers fail closed to the compatible general baseline or no role.

Evidence: `OpenAgents.Context.Composer`, `OpenAgents.Roles`, `OpenAgents.Roles.Catalog`,
`OpenAgents.Roles.GeneralCollaborator`, `test/openagents/roles_test.exs`,
`OpenAgents.Context.ComposerTest`, and `OpenAgents.RolesTest`.

### PERSONA-003 — Persona promotion requires revision-bound regression evidence

Status: Current

Every persona candidate is evaluated against the committed, source-labeled
behavior corpus. Promotion requires a complete passing report bound to the
exact persona, source manifest, corpus, and model revisions. All cases must
pass, so military, founder-voice, sales, false-recognition, or generic-assistant
containment failures cannot be averaged away.

Evidence: `OpenAgents.Persona.Evaluation.Runner`,
`priv/sarah/evals/persona/corpus.v1.json`,
`OpenAgents.Persona.EvaluationTest`, and `mix openagents.persona.verify_promotion`.

### BLUEPRINT-001 — Platform facts are source-linked immutable revisions

Status: Current

Every admitted OpenAgents Blueprint revision is a complete canonical snapshot of
typed platform facts. Facts carry stable IDs, source refs/status/time/digests,
compatibility, introduction/retirement revisions, and admission provenance.
Appending or retiring creates a revision; PostgreSQL rejects edits or deletion
of admitted rows. Compilation is deterministic and refuses conflict, stale
compatibility, missing provenance, private-memory sources, and prose that
claims data, pricing, tool, or action authority.

Every inference immutably pins the verified Blueprint revision and digest, or
pins the explicit-none state when no revision exists. Blueprint informs
expression below protected host layers and cannot attach a capability or
authorize execution.

Evidence: `OpenAgents.Blueprint`, the OpenAgents Blueprint schemas and migration,
`OpenAgents.Context.Composer`, `OpenAgents.Conversations.begin_inference/5`,
`test/openagents/blueprint_test.exs`, and `OpenAgents.BlueprintTest`.

### PROGRAM-001 — Model programs are immutable typed data, never effect authority

Status: Current

Every admitted model-program artifact has one full canonical digest covering
its signature, compiler/model/decoding identity, compatibility, Prompt IR,
parameters, independent datasets, optimizer budget, evaluator, metrics and
uncertainty, provenance, approval, predecessor, and activation status. Training
or validation cannot alias true holdout. Boot admits only pinned digests with
known predecessors.

The OTP reader returns only typed artifact data. Program outputs are proposals,
selections, or scores and cannot execute a tool, add a catalog entry, mutate
policy or protected identity, write memory, or promote/activate themselves.
Each applicable turn captures one immutable artifact identity before provider
work; an in-flight capture cannot observe another catalog.

Evidence: `OpenAgents.ProgramArtifacts`, `OpenAgents.ProgramArtifacts.Reader`,
`priv/sarah/programs/`, `test/openagents/program_artifacts_test.exs`,
`OpenAgents.Conversations.begin_inference/5`, and `OpenAgents.ProgramArtifactsTest`.

### DEGRADE-001 — Missing program artifacts degrade explicitly to a baseline

Status: Current

If an applicable signature has no admitted compatible artifact, capture returns
the deterministic baseline with no artifact ID/digest and a bounded degraded
receipt. Invalid or unapproved artifacts never enter the boot catalog. The turn
receipt immutably records either the exact artifact and catalog identity or the
explicit baseline reason before provider work.

Evidence: `OpenAgents.ProgramArtifacts.capture/1`,
`turn_receipts.program_artifact_receipt`, its database constraint/trigger,
`OpenAgents.ProgramArtifactsTest`, and degraded capture tests in
`OpenAgents.TurnProvenanceTest`.

### PROGRAM-002 — Shadow programs have no live effect or private report payload

Status: Current

Shadow signatures validate bounded typed input/output and run under a separate
task supervisor. The live turn never consumes their result. Memory and
collective outputs remain proposals; routing can name only a capability in its
captured input catalog. Malformed, late, failed, incompatible, and missing-
artifact paths degrade explicitly without writing memory, tools, policy,
Blueprint, collective data, or the user-visible answer.

PostgreSQL stores immutable terminal comparison metadata, digests, latency,
usage, and withheld output shape, never raw inputs or candidate values.
Replay data is explicitly synthetic or must enter through a future consented
fixture path; production conversations/profile memory are not datasets.

Evidence: `OpenAgents.ShadowPrograms`, `OpenAgents.ShadowPrograms.Signatures`,
`OpenAgents.ShadowPrograms.OpenAI`, `shadow_program_runs`,
`priv/sarah/evals/shadow/corpus.v1.json`, `test/openagents/shadow_programs_test.exs`, and
`OpenAgents.ShadowProgramsTest`.

### PROGRAM-003 — Promotion is offline, human-approved, and rollback-capable

Status: Current

A compiled candidate, pinned independent evaluation, human approval, and human
activation are separate append-only artifacts/events. Evaluation is bound to
distinct train/validation/true-holdout manifests, exact evaluator identity,
complete bounded cost, metrics/uncertainty, and passing safety/privacy gates.
Datasets are synthetic or carry an explicit consent receipt; private production
data has no implicit admission path.

Only a human actor receipt can approve, activate, or roll back. Activation
atomically advances a PostgreSQL pointer generation for later turn captures;
an in-flight capture remains unchanged. Rollback selects the pinned predecessor
and preserves the complete prior trail.

Evidence: `OpenAgents.ProgramLifecycle`, its artifact/event/activation schemas and
database guards, `test/openagents/program_lifecycle_test.exs`, the synthetic sample promotion
report, and `OpenAgents.ProgramLifecycleTest`.

## Identity and authorization

### IDENTITY-001 — Human browser and session identity

Status: Current

Every human browser interaction requires an active local user established through
the GitHub OAuth authorization-code flow. The immutable external key is GitHub's
numeric user ID; login and avatar URL are refreshable projections and never
authority. OAuth start uses high-entropy state plus PKCE S256. A short-lived
PostgreSQL attempt receipt makes state one-time even if an old encrypted cookie
is replayed. Phoenix exchanges the code and rereads `/user` server-side, then
stores the delegated GitHub token as encrypted server-side ciphertext for
GitHub repository tools. The token never enters the browser. The browser
session contains only OpenAgents's local user ID and is encrypted, signed,
HTTP-only, same-site, and secure in production.

Agent credentials use the separate agent identity contract below; they do not
create rows in `users` or require GitHub.

The first sentence quantifies over routes, so it is proven by enumerating
them: `OpenAgentsWeb.AuthenticatedRouteGateTest` dispatches every route
`OpenAgentsWeb.RouteAuthority` classifies `:authenticated_browser` without a
session and requires each to refuse. The two OAuth entries are in that class
and refuse the same way — an anonymous request reaches them and leaves with an
`auth_error` and no session.

Evidence: `OpenAgents.GitHubOAuth`, `OpenAgents.Accounts`, `OpenAgentsWeb.AuthController`,
`OpenAgentsWeb.Endpoint.session_options/0`, `OpenAgents.GitHubOAuthTest`,
`OpenAgents.AccountsTest`, `OpenAgentsWeb.AuthControllerTest`, and
`OpenAgentsWeb.AuthenticatedRouteGateTest`.

### IDENTITY-002 — Conversation lookup never accepts a client database ID

Status: Current

The browser supplies only its encrypted OpenAgents session. Server code loads the
active local user and resolves that user's internal storage owner and canonical
conversation. A route parameter, form value, mutable GitHub login, or LiveView
event must not select another user, owner, or conversation. All typed, memory,
data, voice, and telemetry routes fail before mutation without an active user;
health endpoints remain public and create no identity state.

The route half of that sentence is enumerated rather than sampled.
`OpenAgentsWeb.AuthGateTest` asks eleven hand-written paths whether they
redirect, which cannot fail for a route nobody added to the list, so
`OpenAgentsWeb.AuthenticatedRouteGateTest` derives the population from
`OpenAgentsWeb.RouteAuthority` instead: every route it classifies
`:authenticated_browser` must refuse an anonymous request with a redirect to
the public root or a `401`. A route added outside the `:authenticated`
pipeline fails there until it is reclassified.

Amended 2026-08-23 (issue #174): the LiveView event half used to rest on
each surface's own test, which cannot fail for a handler nobody wrote a test
for. Two mechanisms carry it, and `OpenAgentsWeb.LiveViewScopeTest` enumerates
both from the router and from compiled import tables.

- **Who is acting is re-resolved before every event.**
  `OpenAgentsWeb.UserAuth.on_mount/4` attaches a `:handle_event` hook in the
  `:ensure_authenticated` and `:ensure_admin` stages; each re-reads the account
  through `OpenAgents.Accounts.get_active_user/1`, and the operator hook
  rechecks `OpenAgents.Accounts.admin?/1`. A session banned or demoted between
  mount and click is halted, not served. Every LiveView route
  `OpenAgentsWeb.RouteAuthority` classifies `:authenticated_browser` or
  `:operator` must sit in a live session that mounts one of those stages, and
  the live sessions themselves are an exact declared set, so a new session is
  classified before it can carry a surface.
- **What is being resolved goes through a context.** No LiveView reaches
  `OpenAgents.Repo`. A view that writes its own query is a surface where the
  scope rule is restated from memory, which is how a handler comes to select a
  record its caller never had. `OpenAgentsWeb.AdminForumLinksLive` did exactly
  that — `Repo.get!(Forum.ActorLink, id)` straight from the event params — and
  now resolves through `OpenAgents.Forum.fetch_actor_link/1`.

What is still not enumerated: a context function that itself takes no acting
principal, called from a handler with a caller-supplied identifier, passes both
tests. `OpenAgents.DeviceAuthorizations.get_pending_by_user_code/1` is the
deliberate instance — the device code is the terminal's own bearer secret, and
the deciding half (`approve/2`, `deny/2`) binds the acting account.
`docs/2026-08-23-invariant-proof-audit.md` records the residue.

Evidence: `OpenAgentsWeb.UserAuth`, `OpenAgentsWeb.Router`,
`OpenAgentsWeb.ChatLive.mount/3`, `OpenAgents.Conversations.get_conversation_for_user/1`,
`OpenAgentsWeb.AuthGateTest`, `OpenAgentsWeb.AuthenticatedRouteGateTest`, and
`OpenAgentsWeb.LiveViewScopeTest`.

### IDENTITY-003 — Account continuity supersedes browser portability

Status: Current

One GitHub-authenticated user resolves the same canonical OpenAgents owner across
browsers and devices; no export/import ceremony is required for that account.
The disabled encrypted portability adapter remains only an explicit transfer
mechanism into the currently authenticated destination account. It does not
link accounts, change GitHub identity, grant authorization, or create automatic
sync between distinct users.

Each export derives a fresh AES-256-GCM key from a person-held passphrase using
the pinned PBKDF2 envelope and persists no key, passphrase, envelope, ciphertext,
payload, or claim in the portability plane. Decrypted claims may persist only by
passing the existing destination profile-memory admission contract. Portability
receipts may retain the opaque ciphertext-envelope digest for replay plus
bounded lifecycle metadata; they may not retain or index plaintext or a
content-derived claim derivative.

Destination replay/sequence, conflict, tombstone, and revocation receipts are
explicit. Rotation cannot revoke offline old bundles, tombstones propagate only
when a newer bundle is imported, and a lost bundle/passphrase is unrecoverable
by OpenAgents. Adapter failure leaves account-local operation unchanged.

Evidence: ADR 0002 (which supersedes ADR 0001's identity decision),
`OpenAgents.Memory.Portability`, its envelope and receipt schemas,
`test/openagents/memory_portability_test.exs`, and `OpenAgents.MemoryPortabilityTest`.

### IDENTITY-004 — Agent participation identity is bounded and durable

Status: Current

An agent can self-register without GitHub and receives a durable credential
whose only scope is `agent:participate`. The credential can participate on
public forum and issue surfaces but has no operator, promotion, deployment, or
membership authority. A human link is optional, and at most one active human
link is enforced by a database uniqueness constraint. The link delegates only
explicitly bounded authority. The agent remains the author recorded at creation
time, so linking or unlinking never rewrites attribution; an unlinked agent has
no owner.

Evidence: `OpenAgents.Agents`, `OpenAgentsWeb.Plugs.DualPrincipalAuth`,
`test/openagents/agents_test.exs`, and
`test/openagents_web/controllers/agent_controller_test.exs`.

### IDENTITY-005 — Box control is account-scoped and target-specific

Status: Current

The `box:control` API scope is independent from forge, deployment, chat,
agent participation, and `computer:control` scopes. A request can use it only
with a human account token or an agent whose linked human granted exactly the
Box target kind. Every request names a conversation owned by the effective
human account, and a foreign conversation or Box is indistinguishable from a
missing one.

Evidence: `OpenAgentsWeb.Plugs.AssignmentControlAuth`, `OpenAgents.Box`,
`OpenAgentsWeb.BoxController`, and
`test/openagents_web/controllers/box_controller_test.exs`.

### IDENTITY-006 — Assignment credentials are repository and branch scoped

Status: Current

An assignment credential identifies one durable assignment and can access only
its repository. Git receive-pack authorizes every requested ref update before
any ref moves; the credential can update only its assignment branch. It cannot
write a default or protected branch, close an issue, authenticate as an
operator, or access non-Git API routes. The credential stores only a digest,
expires with the assignment deadline, and is revoked when the assignment
reaches a terminal state.

Evidence: `OpenAgents.Forge.Assignments`,
`OpenAgentsWeb.Plugs.ForgeGitAuth`, `OpenAgents.Forge.GitHTTP`, and
`test/openagents/forge/assignment_test.exs`.

### IDENTITY-007 — Delegated Box control is explicit and revocable

Status: Current

An agent can control a Box only when its linked human grants the
`box:control` scope. The grant records the granter and lifecycle timestamps.
Unlinking or revoking the grant prevents new Box-control requests, while
historical agent authorship remains unchanged.

Evidence: `OpenAgents.Agents`, `OpenAgentsWeb.Plugs.AssignmentControlAuth`,
and `test/openagents/agents_test.exs`.

### IDENTITY-008 — Computer control is independent and computer-bound

Status: Current

The `computer:control` API scope is independent from `box:control` in both
directions. A human account token requires the Computer scope, and a delegated
agent requires an active `target_kind: computer` grant from a linked human.
Computer routes do not accept a Box grant, and Box routes do not accept a
Computer grant. The local computer controller remains authoritative over
declared roots, presence, probe-reported ACP agents, prompt bounds, and
execution; the API cannot widen a tier, add a root, or request an unadvertised
capability. Computer projections never expose a computer token, token digest, or
raw probe document.

Evidence: `OpenAgentsWeb.Plugs.AssignmentControlAuth`,
`OpenAgents.ComputerAgentJobs`, `OpenAgentsWeb.ComputersController`,
and `test/openagents_web/controllers/computer_control_api_test.exs`.

### IDENTITY-009 — Unified delegation preserves substrate authority

Status: Current

The unified delegation surface never widens the reach available through the
Box or Computer substrate. It resolves the target kind before enforcing the
matching human scope or delegated grant, then forwards to the existing
substrate authority without storing a mirrored delegation record. Box and
Computer identifiers are opaque, kind-prefixed references to their durable
substrate records; malformed, unknown, and foreign references are
indistinguishable from missing references. The projection is bounded and
redacted, and does not expose provider URLs, computer credentials, probe
documents, prompts, or subprocess environments.

Evidence: `OpenAgents.Delegations`, `OpenAgentsWeb.Plugs.DelegationAuth`,
`OpenAgentsWeb.DelegationsController`, `OpenAgents.BoxRuns`,
`OpenAgents.ComputerAgentJobs`, and
`test/openagents_web/controllers/delegations_controller_test.exs`.

### IDENTITY-010 — Computer assignment credentials are opt-in and delegation-scoped

Status: Current

An issue assignment has one target in the shared assignment ledger. A Computer
target receives its repository-and-branch-scoped forge credential only when its
owner explicitly enables scoped forge credentials for that Computer. The
plaintext credential exists only in memory while the delegation starts and is
delivered in the server-to-controller `agent` frame for injection into that
delegated process environment. It is not persisted in a job, journal, prompt,
output, shell environment, global Git configuration, or API response. The
credential expires with the assignment and is revoked when the assignment
completes, is cancelled, expires, or loses its computer or controller.
Computer validation and local controller refusal remain authoritative.

Evidence: `OpenAgents.Forge.Assignments`,
`OpenAgents.Forge.AssignmentCredentialVault`,
`OpenAgents.ComputerAgentJobs`, `OpenAgents.Work.DelegationServer`,
`test/openagents/forge/assignment_test.exs`, and
`test/openagents_web/controllers/computer_control_api_test.exs`.

### CAPACITY-002 — Box fan-out admission is bounded and durable

Status: Current

Fan-out admission records one durable plan and one logical item per requested
Box. PostgreSQL-backed admission locks enforce conversation, owner, and global
active limits before provider creation. Queued items retain their labels and
request order, hold no provider resource, and promote when a Box stops.
Generated labels are sequential within a conversation and remain stable for
the Box lifetime.
Admission records an estimated hourly burn rate, and conversation and owner
burn-rate ceilings are separate from accumulated usage. Later settlement must
use its own durable usage quantity rather than treating the current active
burn rate as historical spend.

Evidence: `OpenAgents.Box`, `OpenAgents.Box.Fanout`, and
`test/openagents/box_fanout_test.exs`.

### CAPACITY-003 — Box lifecycle reconciliation is one-way and observable

Status: Current

The supervised Box reconciler runs every 60 seconds. It refreshes mutable or
unsettled ledger rows against the provider, gives each provider request a
15-second receive timeout, reclaims Boxes after a 3,600-second TTL or 1,800
seconds of inactivity, and records the stop reason, lifetime, and settled cost. A live
non-terminal run prevents idle reclamation. Provider-terminal and
provider-missing responses release capacity and promote queued work. Provider
transport failures and rate limits record retry backoff without changing
lifecycle state. Provider Boxes without a ledger claim are reported durably;
only Boxes carrying this deployment's ownership marker in the provider `name`
are stopped. Reconciliation never resumes or recreates a Box.

Evidence: `OpenAgents.Box.Reconciler`, `OpenAgents.Box.Usage`, and
`test/openagents/box_reconciler_test.exs`.

### WORK-002 — Detached Box runs reconcile from durable evidence

Status: Current

Long-running Box work is admitted before dispatch and executes from a
run-specific directory containing its script, combined log, process ID, and
exit sentinel. The application polls that directory, stores bounded redacted
output, and treats a missing process without an exit sentinel as `lost`.
Dispatch ambiguity receives one probe and never an automatic second dispatch.
Cancellation and timeout record requested and effective timestamps separately.

Evidence: `OpenAgents.BoxRuns`, `OpenAgents.BoxRunServer`,
`OpenAgents.Box.Client`, and
`test/openagents/box_runs_test.exs`.

## Data authority and synchronization

### DATA-001 — PostgreSQL is authoritative

Status: Current

Visitors, conversations, messages, and turns are persisted before their state
is presented as accepted. PubSub and LiveView streams are projections; losing
either must not lose accepted data.

Evidence: `OpenAgents.Conversations.create_turn/2` and
`OpenAgentsWeb.ChatLiveTest` durable-turn test.

### DATA-002 — One canonical conversation per authenticated user

Status: Current

Database uniqueness enforces one internal storage owner per local user and one
conversation per owner. Initial greeting creation is coupled to first
conversation creation. Distinct users remain isolated; multiple sessions for
one user converge on the same conversation and therefore the same text and
voice limits. Pre-authentication browser rows remain inaccessible legacy data
and are never silently claimed during login.

A thread is not a conversation and does not count against this uniqueness: an
account holds as many threads as it has pieces of work, each with its own
objective, transcript, and model authority (THREAD-001).

Evidence: unique indexes and identity-source constraint in
`create_github_users`, `OpenAgents.Conversations.ensure_conversation/1`, and
account continuity/isolation/rate tests in `OpenAgents.AccountsTest`.

### DATA-003 — History is bounded and stable

Status: Current

The newest page and every older page contain at most the configured page size.
Ordering uses persisted timestamp plus UUID, and rendered rows use stable
message IDs.

Evidence: `OpenAgents.Conversations.list_messages/2` and bounded-history test.

## Memory and recall

### MEMORY-001 — Recall is confined to the current account conversation

Status: Current

Every recall snapshot and search is bound to one canonical conversation
resolved from the authenticated local user. A snapshot from another
conversation or user is refused, and no API offers a cross-conversation or
unscoped fallback. GitHub identity establishes account continuity but does not
turn conversation evidence into verified facts about a person.

The recall APIs are enumerable rather than remembered. Recall reaches
PostgreSQL only through the backend `:recall_search_backend` names in
`config/config.exs`, so the backends are the population, and each backend's
public API is its own `__info__(:functions)`. Every function in it is named
here with how its scope is closed — `capture_ref/3` by the conversation it is
given, `load_snapshot/2`, `search/3,4`, `search_page/3,4`, and `read/3,4` by
refusing a snapshot from another conversation — and every refusing entry point
is driven across a conversation boundary. A recall function added beside them
fails until this contract accounts for it.

Evidence: `OpenAgents.Memory.RecallSnapshot`, `OpenAgents.Memory.LexicalRecall`,
`OpenAgents.Memory.HybridRecall`, cross-scope tests in
`OpenAgents.Memory.LexicalRecallTest`, and the entry-point enumeration in
`OpenAgents.Memory.ScopeBoundaryTest`.

### MEMORY-002 — Recalled history is classified evidence, not current profile truth

Status: Current

Every materially used read source is represented by a host-built
`openagents.memory_evidence.v1` value with validated source/scope, observed and
recalled times, bounded claim and relevance, host classification, and validated
corroboration/conflict refs. The model cannot supply scope or classification,
fabricate a source that passes the scoped database read, or promote weak,
stale, conflicting, or irrelevant evidence. Current user correction outranks
older history. Conversation evidence never enters the separate profile-memory
plane through repetition, model confidence, or recall classification.

Historical source content remains untrusted quoted data. It cannot change
OpenAgents's identity, safety rules, captured catalog, execution scope, authority,
or host limits. Terminal receipts immutably retain each materially used source
ref and its host classification.

Evidence: `OpenAgents.Memory.Evidence`, `OpenAgents.Tools.ConversationRead`,
`OpenAgents.Context.Composer`, `turn_receipts.used_memory_evidence`, its terminal
database trigger, `OpenAgents.Memory.EvidenceTest`, and
`OpenAgents.TurnMemoryEvidenceJourneysTest`.

### MEMORY-003 — Profile memory is explicit, inspectable, correctable, and forgettable

Status: Current

Durable profile claims live in a separate account-owner plane. A record
is only active with a same-owner complete user-message source or a host-recorded
explicit owner assertion. Candidates never activate through repetition or
model confidence. Claims and their identity/provenance fields are immutable;
correction atomically supersedes the old record with a source-linked new one.
Lifecycle transitions are explicit and optimistic-generation checked.

Every record and source is available to bounded owner export. Forget and expiry
are terminal states retained for audit; explicit purge is allowed only after a
terminal state and removes the record plus every derived source link without
deleting the independent conversation source message.

Evidence: `OpenAgents.ProfileMemory`, the profile-memory schemas and database
constraint triggers, `OpenAgentsWeb.ChatLive`, `OpenAgentsWeb.MemoryExportController`,
`test/openagents/profile_memory_test.exs`, `test/openagents/profile_memory_test.exs`, `OpenAgents.ProfileMemoryTest`,
and memory-control journeys in `OpenAgentsWeb.ChatLiveTest`.

### MEMORY-004 — Scope and snapshot boundaries are database predicates

Status: Current

Recall scope is enforced by `messages.conversation_id` in every PostgreSQL
query, never by prompt instructions. Each inference immutably records a
`message:<uuid>` high-water ref for the last eligible message before the current
user turn. Searches apply its ordered timestamp/UUID cursor and admit only
complete user/assistant rows, so streaming or failed assistant text and normal
later inserts cannot enter the turn's recall view.

The queries are enumerable rather than remembered. Every Ecto query in a
recall backend rooted at the recall corpus (`messages`, `turn_tool_steps`,
`voice_tool_steps`) names `conversation_id`, and every query in a
profile-memory reader rooted at the profile plane names `owner_visitor_id` —
or, for the owner's own message and conversation reads, `visitor_id`. Both
populations are read from the modules' own source, so a query added beside the
enforced ones fails until it carries its scope, and a query rooted at a table
this contract gives no scope column fails until the column is named. What that
establishes is that the predicate is written; that it refuses is the behaviour
the recall and profile-memory tests drive.

Evidence: `OpenAgents.Conversations.begin_inference/5`, the generated `search_vector`
and partial GIN migration, `OpenAgents.Memory.LexicalRecall`, immutable turn receipt
triggers, snapshot/status/index tests in `OpenAgents.Memory.LexicalRecallTest`, and
the query enumeration in `OpenAgents.Memory.ScopeBoundaryTest`.

Search is discovery only. `conversation_search.v1` returns bounded excerpts;
`conversation_read.v1` must reread an exact source and bounded neighborhood
under the same host-supplied conversation/snapshot before historical wording is
treated as grounded. Foreign and unknown source UUIDs share one `not_found`
outcome, while materially returned refs are recorded on the turn receipt.

Evidence: `OpenAgents.Tools.ConversationSearch`, `OpenAgents.Tools.ConversationRead`,
`OpenAgents.Tools.RecallContext`, `OpenAgents.Tools.ConversationRecallToolsTest`, and the
end-to-end recall loop in `OpenAgents.TurnToolLoopTest`.

Recall's source universe covers durable tool activity as well as messages.
`conversation_search.v1` lexically matches terminal tool steps from both
surfaces (`turn_tool_steps`, `voice_tool_steps`) over tool name, status, and
bounded result/error text, returning typed `turn-tool-step:<uuid>` /
`voice-tool-step:<uuid>` refs classified as `tool_activity` with the same
excerpt bound and deterministic score/timestamp/id ordering as messages. A
tool step is observable at a snapshot only when it completed at or before the
watermark message's insertion instant, or when the assistant message that
concluded its work unit (turn or voice response) is itself admitted by the
message fence — both predicates compare immutable persisted values with the
immutable snapshot, so work later than the frozen turn never enters its recall
view. `conversation_read.v1` resolves those refs within the same
conversation/snapshot scope into a bounded step context (tool name, status,
bounded result/error, timestamps, executor disclosure) plus the nearest
admitted neighboring messages; foreign and unknown step refs share the
messages' single `not_found` outcome.

Evidence: tool-step queries and step reads in `OpenAgents.Memory.LexicalRecall`,
step-ref usage items in `OpenAgents.Memory.Evidence`, and the tool-step recall,
scope-refusal, and snapshot-fencing tests in
`OpenAgents.Tools.ConversationRecallToolsTest`.

Profile-memory queries likewise require `owner_visitor_id` in every predicate.
An opaque persisted snapshot pins both the owner's monotonic scope generation
and capture time. Activation and terminal generations reconstruct the active
set after concurrent correction, forgetting, or expiry; another account cannot
load or use the snapshot. Multiple authenticated sessions for the same account
intentionally share it. Unknown scope has no global fallback.

Evidence: `profile_memory_scopes`, `profile_memory_snapshots`, generation
columns and indexes in the profile-memory migration, `OpenAgents.ProfileMemory`, and
cross-browser/concurrent-snapshot tests in `OpenAgents.ProfileMemoryTest`.

### MEMORY-005 — Memory writes require exact current consent

Status: Current

A sampled tool call is a proposal, not write authority. `memory_remember.v1`
accepts only an exact bounded claim directly authorized by the current complete
user message, an exact host-recorded confirmation, or an exact first-party UI
action in the same account scope. Repetition, recalled text, classifier
confidence, and model arguments cannot substitute. `memory_forget.v1` applies
the same rule to one record, one category, or the whole account scope and is
idempotent without revealing foreign-record existence.

Each turn captures a persisted profile-memory snapshot before provider work.
List/search use only that frozen generation, while remember/forget return a
bounded reversible receipt after PostgreSQL commits. OpenAgents may acknowledge
only the exact successful result returned in the durable tool outcome.

Evidence: `OpenAgents.Memory.Consent`, the four `OpenAgents.Tools.Memory*` tools,
`turn_receipts.profile_memory_snapshot_ref`, `test/openagents/tools/profile_memory_tools_test.exs`, and
`OpenAgents.Tools.ProfileMemoryToolsTest`.

### MEMORY-006 — Semantic recall is scoped, disposable, and lexically degradable

Status: Current

Authoritative durable conversation rows — messages, and for lexical
tool-activity recall the terminal tool steps — remain the sole recall
authority; semantic embeddings exist only for messages. Embeddings are
asynchronous derivatives bound to the source message, exact conversation,
content digest, model/version manifest, and active generation. Hybrid queries
repeat the conversation and frozen snapshot predicates in PostgreSQL and admit
only ready rows whose digest still matches the authoritative complete message.
Each asynchronous embedding claim has a bounded lease and attempt number. A
provider task must finish before the lease, and a replacement worker may
reclaim only an expired running claim. Attempt fencing prevents a stale worker
from publishing a late derivative.
Correction, deletion, and rebuild invalidate derivative rows and produce
append-only receipts; a new manifest generation cannot read an older one.
Receipts cannot be edited or deleted while their authoritative conversation
exists. Exact authenticated-owner product-data deletion first removes that conversation and
may then delete its now-unlinked content-free receipts in the same transaction.

The pinned hybrid rank is deterministic reciprocal-rank fusion with stable
timestamp/UUID ties. A provider, manifest, shape, query, or incomplete-index
failure is explicitly `semantic_degraded` and returns the unchanged lexical
page. Hybrid recall is disabled by default and cannot be activated merely by
creating vectors; its committed comparison must preserve lexical fallback and
scope isolation while improving synonym recall.

Evidence: `OpenAgents.Memory.SemanticIndex`, `OpenAgents.Memory.HybridRecall`, semantic
derivative tables and triggers, `test/openagents/semantic_recall_test.exs`,
`priv/sarah/evals/recall/hybrid-comparison.v1.json`, and
`OpenAgents.SemanticRecallTest`.

### MEMORY-007 — Learned preferences require confirmation and never confer authority

Status: Current

Behavior preferences occupy an account-owner plane separate from conversation
evidence, profile facts, roles, tool catalogs, routing authority, and collective
artifacts. An observation or model confidence can create only a candidate. The
only admitted effects are finite presentation/interaction choices; every
candidate must pass policy review, an exact owner confirmation receipt, and a
separate durable activation receipt before it can affect composition.

Every turn freezes a monotonic preference snapshot. Applied and
current-instruction-overridden preferences are immutably recorded with exact
preference, effect-digest, and activation-receipt refs. A current user request
wins for that turn without rewriting the stored preference. Suspension,
correction, and deletion end the effect for later snapshot generations while
preserving historical turn provenance. Outcomes can be recorded only for a
preference actually applied to that exact owner turn.

Preference evidence and receipts remain append-only while their owner exists.
Exact authenticated-owner product-data deletion is the only exception: PostgreSQL cascades
the complete preference graph after the visitor root is gone, while rejecting
direct or foreign-scope receipt deletion.

Evidence: `OpenAgents.Preferences`, the preference schemas and database guards,
`OpenAgents.Context.Composer`, `turn_receipts.used_preferences`,
`test/openagents/preferences_test.exs`, the committed preference comparison, and
`OpenAgents.PreferencesTest`.

### MEMORY-008 — Experience is private, terminal, evidenced, and advisory

Status: Current

Work experience occupies an exact account-owner and conversation-work-scope
plane separate from profile facts, learned preferences, roles, tool authority,
and collective artifacts. Requested and running cases never enter recall.
Success requires a target receipt emitted by a succeeded governed tool step in
the same owner conversation; failure remains explicitly labeled failure. A
single success is one scoped observation, never a universal pattern.

Each turn either has no experience capture or freezes one deterministic,
bounded bank at a monotonic scope generation. Every projection names its
applicability and evidence; storage and projection both pass redaction.
Corrections create a new record, inspection/export remain bounded, and deletion
removes evidence, pattern, and bank derivatives while invalidating affected
banks. Crossing into collective work requires the independent exact-consent
candidate workflow and cannot directly publish or write a global pattern.
Default activation remains off until the committed memory-on/off evaluation
shows measured task benefit without scope or provenance regression.

Experience deletion receipts remain append-only while their owner exists.
Exact authenticated-owner product-data deletion is the only exception: PostgreSQL cascades
the scoped experience graph, including frozen banks linked to deleted turns,
then removes standalone deletion receipts only after the visitor root is gone.
Direct and foreign-scope receipt deletion remain rejected.

Evidence: `OpenAgents.ExperienceMemory`, the experience schemas and database guards,
`OpenAgents.Context.Composer`, `turn_receipts.used_experiences`,
`test/openagents/experience_memory_test.exs`, the committed benefit comparison, and
`OpenAgents.ExperienceMemoryTest`.

### MEMORY-009 — Graph memory is a disposable, generation-atomic projection

Status: Current

The relationship graph is never memory authority. Every node and edge belongs
to one account owner, one conversation work scope, one immutable manifest
generation, and at least one exact authoritative experience-record or pattern
membership. Deterministic identities preserve explicit entity, version, and
conflict fields without collapsing differing outcomes into asserted truth.

Source mutations emit an outbox row in the same PostgreSQL transaction. A
pending mutation makes the current graph unavailable; rebuild locks the source
scope, pins and digests one source snapshot, constructs a complete building
generation, and atomically retires the old generation and exposes the new one.
Dropping every graph table loses no authoritative memory, and replaying the same
source snapshot produces the same build digest.

Traversal requires the exact owner/work scope, current source policy eligibility,
finite depth and result bounds, and source provenance on every returned artifact.
Deletion uses an inspectable exact-generation cascade plan and append-only
completion receipt. Graph use remains disabled by default until its committed
paired evaluation demonstrates material relationship benefit with no scope or
membership regressions.

Graph operation receipts remain append-only while their owner exists. Exact
authenticated-owner product-data deletion is the only exception: manifest-owned projections
cascade with the visitor, and the same transaction removes standalone
memberships, mutation events, cascade plans, and operation receipts after the
visitor root is gone. Direct and foreign-scope receipt deletion remain rejected.

Evidence: `OpenAgents.GraphMemory`, graph manifests/artifacts/memberships/outbox and
database guards, `test/openagents/graph_memory_test.exs`, the committed graph comparison,
and `OpenAgents.GraphMemoryTest`.

### PRIVACY-001 — Secret-bearing profile memory is rejected, never scrub-stored

Status: Current

Before candidate storage, the host applies the pinned
`sarah.memory.policy.v1` policy to the claim, provenance/artifact metadata, and
same-owner source content. Credential, API/auth token, wallet/seed/payment,
encoded-secret, and local-path material rejects the whole candidate. The
rejected value, a hash of it, or a partially scrubbed shell is never persisted.
Only owner scope, fixed policy version, bounded reason/category, size bucket,
and time enter the rejection audit.

Every export or future model/UI projection re-applies
`sarah.memory.redaction.v1`. A value that fails revalidation is withheld as a
whole field. Stored policy identities are immutable, so later policy changes
cannot silently relabel old records or rejection evidence, which is why the two
identifiers above are the strings the code emits rather than tidier ones.

The projections are enumerable rather than remembered. The modules that name a
profile-memory schema are an exact set, and each is accounted for by what it
does with a stored claim: `OpenAgents.ProfileMemory` projects claims,
`OpenAgents.DataRights` erases the owner's plane by id, `OpenAgents.Memory.Portability`
compares claims for import admission and exports through `OpenAgents.ProfileMemory`,
and the four memory tools read only the category list. `OpenAgents.ProfileMemory`
is the one projector, so it is the one place the redaction policy is applied,
and a module that gains a dependency on the profile plane fails until this
contract says what it does with a claim.

Evidence: `OpenAgents.Memory.Policy`, `OpenAgents.Memory.Redaction`,
`profile_memory_policy_events`, immutable policy-version trigger,
`test/openagents/memory/policy_and_redaction_test.exs`, `OpenAgents.Memory.PolicyAndRedactionTest`,
and the projection enumeration in `OpenAgents.Memory.ScopeBoundaryTest`.

## Turn and provider lifecycle

### TURN-001 — At most one active turn per conversation

Status: Current

An active turn is `queued` or `streaming`. A partial unique PostgreSQL index is
the final arbiter; the UI's disabled composer is only feedback.

Evidence: `turns_one_active_per_conversation_index` and active-turn test.

### TURN-002 — Every accepted turn has durable paired messages

Status: Current

The user message, empty streaming assistant message, and turn record are
inserted in one transaction. Completion, failure, and cancellation update both
assistant-message and turn terminal state. PostgreSQL applies a one-megabyte
hard ceiling to every message, and the configured, lower assistant-message
ceiling applies to the complete accumulated stream rather than each delta.

Evidence: `OpenAgents.Conversations.create_turn/2`, `finish_turn/5`, and turn tests.

### TURN-003 — Provider work never blocks the LiveView

Status: Current

Each response executes in a temporary `TurnServer` under a dynamic supervisor;
the outbound provider call executes in a supervised task. Text deltas cross a
typed provider callback and are persisted before broadcast.

Evidence: `OpenAgents.Turns.TurnServer`, its named supervised provider task,
and `OpenAgentsWeb.ChatLiveTest` streaming test.

### TURN-004 — Interrupted work becomes explicit failure

Status: Current

Active records left by a runtime restart are marked failed during application
startup. A response is never left permanently presented as in progress without
an executing turn process. Recovery records the bounded provider-neutral
`runtime_restarted` code, fails every active provider and tool step in the same
transaction, and is idempotent.

Evidence: `OpenAgents.Conversations.recover_interrupted_turns/0`, the
`OpenAgents.TurnRecovery` application child, and the process-death recovery
test in `OpenAgents.TurnProvenanceTest`.

### TURN-005 — Tool continuations are serial, bounded, and commit-first

Status: Current

One turn may request a bounded number of tool calls and provider continuations
(sixteen of each today). Calls execute one at a time; parallel calls fail the
turn. Hitting an execution bound refuses the over-limit call with a durable
typed step outcome and drives one final tool-free report response, so the
person receives partial findings instead of a failed turn; only runaway
behavior past the report path fails the turn. Each continuation uses the exact
provider call ID and previous response ID only after rereading the matching
committed outcome. Cancellation reaches provider and tool tasks, while prior
text, receipts, provider steps, and tool outcomes remain durable on every
terminal path.

Evidence: `OpenAgents.Turns.TurnServer`, `OpenAgents.Providers.OpenAI.request_payload/1`,
`OpenAgents.TurnToolLoopTest`, and `OpenAgents.Providers.OpenAI.RequestPayloadTest`.

### PROVENANCE-001 — Every new inference has an immutable receipt

Status: Current

Before provider work starts, OpenAgents durably captures the exact model, persona,
role, instruction digest, canonical input digest, optional runtime artifact
identities, and first provider step. Identity fields never change; terminal
receipts and provider steps cannot be rewritten. Failures, cancellation, and
restart recovery preserve the captured chain. Turns created before this
contract remain explicitly legacy rather than receiving invented provenance.

Evidence: `OpenAgents.Conversations.begin_inference/4`, PostgreSQL provenance
triggers, `OpenAgents.Provenance.Canonical`, and `OpenAgents.TurnProvenanceTest`.

### PROVIDER-001 — Model providers are replaceable

Status: Current

Conversation and web code depend on `OpenAgents.Providers.Provider`, not OpenAI
event shapes. Adapters emit typed OpenAgents-domain lifecycle, text, tool-call,
usage, completion, failure, and cancellation events. A response ID is persisted
when announced, and matching explicit completion is required; stream closure
alone cannot produce a completed turn. Provider-specific events, credentials,
and raw errors never reach the receipt or browser. Response creation is a
non-idempotent mutation and the adapter sends it exactly once; continuation is
an explicit host decision backed by a committed tool outcome.

Replaceability is a claim about every module, so it is proven over every
module. The adapter is selected by configuration and reached through the
behaviour, so nothing outside its own namespace holds a compile-time
dependency on it. `OpenAgents.DependencyBoundaryTest` reads each compiled
module's import table and fails when one gains that dependency, which is what
the earlier adapter-behavior tests could not do: they exercised the adapter
rather than the code that must not know about it.

Evidence: `OpenAgents.Providers.ProviderEvent`, `OpenAgents.Providers.OpenAI`,
`OpenAgents.Providers.OpenAI.StreamDecoderTest`, `OpenAgents.Providers.Test`,
`OpenAgents.TurnProviderEventsTest`, and `OpenAgents.DependencyBoundaryTest`.

## Tool authority and execution

### TOOL-001 — A turn uses one immutable tool catalog

Status: Current

The registry validates configured tool specifications at boot. Before provider
work, each turn captures one catalog snapshot and writes its canonical digest
to the immutable receipt. Every call must match the exact tool name and version
in that snapshot; later registry builds or deployments affect only later turns.

Evidence: `OpenAgents.Tools.Registry`, `OpenAgents.Tools.Snapshot`,
`OpenAgents.Turns.TurnServer`, and `OpenAgents.Tools.RegistryAndRunnerTest`.

### COLLECTIVE-001 — Private material crosses scope only through exact consent

Status: Current

A collective candidate can be created only in the same transaction as an active
`collective_contribution` receipt from the owning person. The receipt binds the
exact browser-owned source refs and their content digest, source-scope digest,
category, intended use, attribution and compensation disclosures, policy
version/digest, confirmation nonce/digest, and grant time. Model suggestions,
profile-memory consent, product terms, and tool approval are different authority
types and cannot satisfy this gate.

The candidate remains keyed and queried by its private visitor owner. It stores
only the scope digest, opaque per-source provenance refs, redaction-policy
identity, generalized-kind placeholder, evaluator/status, and bounded
review/publication refs; it does not copy source refs, quotes, or identifying
context into candidate fields and has no registry/discovery/execution path.
Owner withdrawal atomically marks consent withdrawn and the unpublished
candidate terminal. If publication refs later exist, withdrawal instead creates
`revocation_pending` propagation state. Consent never publishes or admits a
module; those require separate independent operator review.

Evidence: `OpenAgents.Collective`, `OpenAgents.Collective.ConsentReceipt`,
`OpenAgents.Collective.Candidate`, database scope/state/transition constraints, and
the consent, isolation, raw-copy, and withdrawal cases in `OpenAgents.CollectiveTest`.

### COLLECTIVE-002 — Generalization is bounded, content-free, and reproducible

Status: Current

Only an authenticated privacy reviewer in the candidate owner's scope can run
generalization or inspect opaque lineage. The versioned fixed-vocabulary
generalizer recognizes a bounded supported signal and emits one admitted schema
for evaluation cases, prompt examples, module patterns, or reusable work
patterns. Output is scanned again for secrets, contacts, identifiers, paths,
exact source fragments, authority-bearing fields, and size before storage. It
cannot copy private sources or manufacture executable capability/authority.

The append-only generalization receipt contains candidate/source/policy/
generalizer/output digests, kind-support signal, source count, risk/utility, and
bounded reason codes—never rejected content. Unsupported/high-risk material is
terminally rejected with no generalized payload. A successful payload becomes
immutable, and identical kind/signal/policy inputs produce the same output
digest. This is conservative de-identification, not a claim of mathematically
irreversible anonymity, and it still grants no publication/module authority.

Evidence: `OpenAgents.Collective.Generalizer`,
`OpenAgents.Collective.GeneralizationReceipt`, generalized-candidate database
constraints/triggers, and adversarial schema, reproducibility, lineage, and leak
scans in `OpenAgents.CollectiveGeneralizerTest`.

### COLLECTIVE-003 — Publication requires independent evidence and operator authority

Status: Current

A generalized candidate reaches the cross-user collective catalog only when its
contribution consent remains active, its privacy generalizer is bound to an
authenticated reviewer, and a different authenticated evaluator records a
pinned artifact, pinned dataset, versioned policy, and passing privacy, safety,
regression, novelty, utility, compatibility, and no-authority-expansion result.
A separately authenticated operator, distinct from both reviewers, must then
write the publication receipt. Self-review, self-approval, missing digests,
failed dimensions, withdrawn consent, and legacy unbound generalization receipts
fail closed.

Publication creates a new immutable `openagents.module_artifact.v1` through the same
artifact validation and registry dependency admission used by first-party
modules. The artifact contains only the reviewed generalized payload and opaque
attribution lineage. It begins `disabled` in a staged collective catalog and
has no installed executable, discovery, routing, or invocation path. Review,
operator-decision, and publication receipts are append-only and bind all actor,
policy, evaluation, artifact, predecessor, attribution, and derived-data-plan
evidence. An operator rejection is terminal for that immutable candidate and
publishes nothing.

Consent withdrawal creates revocation propagation. Revocation or staged
regression rollback writes a successor receipt and revoked artifact digest,
excludes the module from all new catalog projections, and marks the bounded
delete/rebuild plan required while preserving content-free historical evidence.
A privacy revocation cannot be rolled back, and an already published module
version is never overwritten.

Evidence: `OpenAgents.Collective.Reviewer`, `OpenAgents.Collective.Publisher`,
`OpenAgents.Collective.ReviewReceipt`, `OpenAgents.Collective.OperatorDecisionReceipt`,
`OpenAgents.Collective.PublicationReceipt`,
`OpenAgents.Modules.Artifact.from_collective/1`, database transition/append-only
guards, and `OpenAgents.CollectivePublicationTest`.

### COMPENSATION-001 — Attribution accounting never creates payout authority

Status: Current

Technical invocation cost, contributor attribution, compensation eligibility,
and payment are distinct facts. An event is compensation-eligible only when an
operator-admitted policy with `payout_authority: false` binds an exact immutable
module artifact to contribution allocations totaling one million parts, the
invocation is uniquely persisted and billable, its terminal outcome is accepted
by an authenticated outcome reviewer, the artifact is not revoked, and the
invocation/outcome has not already been classified. A model proposal, module
publication, invocation, or successful tool result alone cannot make an event
eligible or payable.

Eligible units are allocated deterministically by contribution reference with
integer remainder handling. Unique invocation and outcome keys prevent double
counting. Revocation blocks future eligibility but never rewrites historical
events. Refund, chargeback, fraud/dispute, and policy-migration handling occurs
only through append-only signed adjustments; statements deterministically
reconcile gross, adjustment, and net units for one policy and contributor.

Every policy, module allocation, outcome decision, event, share, adjustment,
and statement is append-only. Contributor/operator projections expose opaque
lineage, digests, counts, units, and reconciliation state but never arguments,
results, conversation content, user identity, payment instructions, custody, or
a payout operation.

Evidence: `OpenAgents.Compensation`, its seven typed receipt schemas and database
constraints, `test/openagents/compensation_test.exs`, and duplicate, revocation,
allocation, adjustment, reconciliation, privacy, and no-payout cases in
`OpenAgents.CompensationTest`.

### REPUTATION-001 — An attestation is scoped signed evidence, never a score

Status: Current

A reputation attestation is one Ed25519-signed canonical claim binding an
issuer key, a subject, an accepted outcome, a repository, an issue, a revision,
an artifact digest, an admitted verifier policy version and digest, a
confidence in parts per million, evidence references, a timestamp, and a nonce.
The six event types — completion, verification, review, payment, reversal, and
revocation — stay distinct facts.

Issuance requires an accepted-outcome receipt that already reached its admitted
terminal state, so an invocation, a presence signal, token volume, online time,
or unverifiable narration can never produce an attestation. The verifier policy
rules carry `global_score: false`, no function returns a ranking, and subject
evidence is counted inside one repository with a `score` of `nil`.

Verification is independent of the interface. A client recomputes the claim
digest, checks the signature against the admitted public key, compares the
policy digest and version, resolves each evidence reference, and reads the
revocation state. Because the claim covers the issue, the revision, the
subject, the outcome, and the verifier, a valid attestation presented for
another issue, revision, verifier, or actor fails its binding. A reversed or
invalidated outcome produces a linked invalidating attestation, and the revoked
claim and signature stay readable. Retiring a key never invalidates the history
it signed, and a private key never enters the database.

Disclosure follows repository authority: an attestation is `public` only where
the repository is public or its transparency level admits ledger disclosure
(TRANSPARENCY-001), evidence must
stay inside the repository, and a `private` attestation withholds the outcome
reference and every evidence reference from the signed claim while remaining
verifiable.

Evidence: `OpenAgents.Reputation`, `OpenAgents.Reputation.Claim`,
`OpenAgents.Reputation.Attestation`, `OpenAgents.Reputation.SigningKey`,
`OpenAgents.Reputation.PolicyReceipt`, the append-only and uniqueness
constraints on `reputation_attestations`, `OpenAgentsWeb.ReputationController`,
`test/openagents/reputation_test.exs`, and
`test/openagents_web/controllers/reputation_controller_test.exs`.

### SETTLEMENT-001 — A bounty pays once, against fingerprinted evidence

Status: Current

Bounty settlement is a separate authority from attribution accounting. A payment
leaves the treasury only when an operator-admitted treasury policy bounds the
amount, the daily budget, the attempt count, and the admitted self-custodial
destination kinds; the priced specification carries a named buyer, a sats
amount, acceptance criteria, a verification policy, an expiry, and a fingerprint
over all of them; the claim pins that fingerprint and the claimant's own
destination; a verification under the specification's own verifier policy digest
accepts the exact commit the claim delivered; and the settlement request carries
an approval reference and an idempotency key.

A repriced specification, a moved fingerprint, a rejected verifier, a commit
without its own verification, a missing approval, an expired claim, a dispute,
an exhausted budget, or an exhausted attempt bound each stop the payment. One
idempotency key names one payment intent, one intent per claim can reach `paid`,
one receipt exists per intent, and a payment hash is unique, so a duplicate
request, a retry, and a lost acknowledgement all resolve to the first receipt
instead of a second payment. Expiry, dispute, and refund are append-only
adjustments that never rewrite a receipt.

The treasury never holds the claimant's keys and never provisions a wallet for
them: the domain hands an authorized request to the configured gateway and
records the returned evidence, and an unconfigured gateway fails closed. Public
projections publish only the amount, the status, reference kinds, and the
evidence the repository's disclosure level admits, never a destination, a
claimant or buyer reference, an operator identity, an approval reference, or a
gateway reference. The claimant can export the full receipt, including their own
destination, without a hosted wallet.

Evidence: `OpenAgents.Settlement`, `OpenAgents.Settlement.PaymentGateway`, its
seven append-only schemas with their uniqueness and partial-uniqueness
constraints, and the pricing, claim, verification, duplicate, stale-commit,
approval, budget, retry, reconciliation, expiry, dispute, refund, privacy, and
receipt-export cases in `test/openagents/settlement_test.exs`.

### MODULE-001 — Every invocation pins one immutable admitted module

Status: Current

The captured turn registry contains provider-neutral module artifacts whose
canonical digest covers typed input/output, lifecycle state, side-effect and
approval classes, capability/data scopes, policy facets, executor identity,
publisher/maintainer, provenance, compatibility/dependencies, predecessor,
deprecation, rollback, and attribution policy. The artifact also binds the
loaded BEAM executor identity. Immediately before invocation the runner verifies
that loaded identity; missing or changed bytes fail closed. Durable tool-step
identity records the registry, route receipt, artifact, executor, module version,
attribution-policy version/digest, side-effect class, arguments, invocation key,
and explicit billing identity.

Only admitted or explicitly deprecated modules are projected into discovery and
provider schemas. Disabled and revoked artifacts remain visible to provenance
inspection but are unavailable to new turns. A registry replacement can affect
only a later turn; predecessor and rollback metadata never mutate an already
captured snapshot. First-party recall remains subject to `TOOL-001` through
`TOOL-004` and its existing conversation/profile scope predicates.

Evidence: `OpenAgents.Modules.Artifact`, `OpenAgents.Modules.Registry`,
`OpenAgents.Tools.Registry`, the module identity columns and database transition
constraint on `turn_tool_steps`, `OpenAgents.Modules.RegistryTest`, and module
invocation reconciliation tests in `OpenAgents.ToolStepPersistenceTest`.

### MODULE-002 — Discovery and lifecycle never grant model authority

Status: Current

The model-facing discovery tool receives the exact registry already captured by
its turn and returns at most twenty bounded public metadata references. It cannot
register a module, reveal executable/provider schemas or private configuration,
or grant execution, scope, approval, or authority. Every later use must
revalidate both the registry and artifact digests against the same capture;
stale references fail closed. Deprecated modules are excluded from default new
selection but remain available to an explicit historical projection.

Stage, admit, deprecate, disable, revoke, and predecessor rollback are host-only
operator operations requiring an authenticated operator identity and a unique
approval receipt. Artifact, provenance, policy, compatibility, and dependent
impact checks run before an append-only PostgreSQL receipt is committed. Text
and voice surfaces apply the latest receipts only when capturing a new registry;
an in-flight turn/session keeps its prior snapshot. Revoked modules cannot be
restaged or admitted, and active dependents block disable/revoke.

Evidence: `OpenAgents.Modules.Discovery`, `OpenAgents.Tools.ModuleDiscover`,
`OpenAgents.Modules.Lifecycle`, `OpenAgents.Modules.LifecycleReceipt`, the append-only
database trigger, and the discovery/lifecycle tests.

### MODULE-003 — Routing proposals cannot weaken explicit policy

Status: Current

Module routing receives a captured registry, a versioned/digested host policy,
an intent digest, required capability/effect/data scope, and application-created
authorities. Publisher, cost class and numeric budget, quality, privacy,
residency, jurisdiction, censorship-resistance, approval, side effect, runtime,
scope, and authority are hard filters applied before deterministic ranking. A
model/program proposal is only a reference to revalidate. It cannot add a
candidate, change policy, infer away a stricter constraint from casual language,
or trigger an unauthorized fallback.

The exact decision is persisted before tool-step dispatch without raw prompt
content. Immediately before execution the host revalidates registry, artifact,
policy, scope, and authority; the tool runner then independently repeats its
scope/authority/effect checks. No eligible module produces a typed unavailable
or refused outcome. An unadmitted routing-program identity is rejected, and an
absent/degraded optional program uses the reproducible deterministic baseline.

Evidence: `OpenAgents.Modules.RoutingPolicy`, `OpenAgents.Modules.Router`,
`OpenAgents.Modules.RouteReceipt`, `OpenAgents.Modules.RoutingReceipts`, the append-only
route-receipt trigger, `OpenAgents.Turns.TurnServer`, and router/tool-loop tests.

### MODULE-004 — Every capability surface preserves the same authority boundary

Status: Current

Every route and invocation names exactly one admitted surface from `text`,
`voice`, `search`, `computer`, `repository`, `mcp`, or `agent`. The selected
artifact must admit that surface, kind, and effect; revalidation refuses a
surface change. Voice and text share the admitted persona, role, Blueprint,
memory authorities, registry, and outcome envelope rather than forking OpenAgents's
identity.

Read-only work requires exact application-created scope and authority.
Reversible writes require exact current-user consent, and external effects
require an external or operator approval receipt bound to module, version, and
scope. Every successful non-read effect returns a target receipt, and every
outcome discloses the actual executor. Large catalogs are bounded by schema
count and encoded size; above either ceiling only discovery is exposed, and
its proposals pass ordinary revalidation. Missing executors fail honestly.

Evidence: `OpenAgents.Modules.SurfacePolicy`, the `surface` field on module route
decisions/receipts, `OpenAgents.Tools.Registry.prompt_catalog/1`,
`OpenAgents.Tools.Runner`, `test/openagents/surface_eval_test.exs`, and the surface, catalog,
approval, receipt, voice-interruption, and degradation tests.

### TOOL-002 — Model requests never widen host authority

Status: Current

Tool name, arguments, recalled text, and prompt content grant no scope or
authority. The runner checks the application-created execution context against
the captured specification before implementation code runs. It admits read-only
tools, explicitly scoped reversible writes, and external effects only with the
surface-specific approval and target-receipt contract.
Reversible memory writes still pass their current-consent, owner, policy,
conflict, and optimistic-generation gates.

Evidence: `OpenAgents.Tools.ExecutionContext`, `OpenAgents.Tools.Runner`, and the scope,
authority, schema, and side-effect runner tests.

### TOOL-003 — Tool outcomes are durable before provider continuation

Status: Current

Every provider call ID maps to one ordered immutable request row. A worker must
atomically claim `requested -> running`; duplicate requests return the existing
row and duplicate claims cannot execute it again. Provider continuation output
can be constructed only by rereading a committed terminal outcome. Active
steps block normal turn completion and become explicit cancelled, failed, or
interrupted outcomes with the containing turn.

Evidence: `OpenAgents.Conversations.ToolStep`, the `turn_tool_steps` constraints and
transition trigger, `OpenAgents.Conversations.tool_continuation_output/1`, and
`OpenAgents.ToolStepPersistenceTest`.

### TOOL-004 — Every outcome identifies the actual executor

Status: Current

Every success, failure, refusal, cancellation, timeout, or unavailable result
is a bounded `openagents.tool_outcome.v1` envelope naming the captured module version
and actual executor/disclosure. Attribution and target receipt refs are bounded
and validated; one OpenAgents interface never implies OpenAgents performed hidden work.
The terminal invocation adds an immutable normalized outcome receipt and bounded
usage/cost projection before provider continuation. OpenAgents's continuation and UI
activity disclose the executor; UI activity renders at most the bounded
durable outcome projection UI-002 sanctions, never an unbounded payload.
Success may rely on the normalized outcome receipt for local/read-only work;
target-system refs remain separately preserved whenever an effect or source
produces them.

Evidence: `OpenAgents.Tools.Tool`, `OpenAgents.Tools.ExecutionResult`,
`OpenAgents.Tools.Runner`, `OpenAgents.Conversations.ToolStep`, the invocation-ledger
database constraints, normalized-outcome tests, and executor-disclosure UI tests.

### TOOL-005 — The offered set names only tools this caller can reach

Status: Current

A tool the caller cannot use is not offered to the model. Every surface that
builds a model-facing catalog resolves the caller once for the turn —
`OpenAgents.Tools.Reach.caller/1` from the execution context, or
`caller_for_user_id/1` where the surface already holds the visitor — and the
selector drops every tool whose declared `reach:` the caller does not hold
before ranking, so an unreachable tool takes neither a top-K slot nor an
always-include slot.

Three requirements exist, and each tool's specification declares which apply:

- `:signed_in_owner` — the conversation resolves to an active account through
  `OpenAgents.Tools.OwnerContext`. `computer_list`, `computer_probe`,
  `computer_run`, `computer_devin`, `computer_agent`, `deep_work`, and
  `incident_lookup` declare it.
- `:paired_computer` — that account has an active paired Computer.
  `computer_probe`, `computer_run`, `computer_devin`, and `computer_agent`
  declare it. `computer_list` deliberately does not: listing zero Computers is
  how the model learns to say "pair one first".
- `:operator` — that account holds operator authority. `scv_deploy` declares
  it, because SCV-001 spends OpenAgents capacity rather than the caller's.

Repository tools declare no reach: their gate is per-repository membership,
which depends on an argument the catalog has not seen. Box tools declare none
either: their gate is deployment configuration, not who is asking.

The narrowing decides what is offered and never what is allowed. Each tool
re-resolves its own owner and re-checks its own gate at execution (TOOL-002),
so a stale or wrong catalog cannot widen authority. An unknown requirement
refuses the whole registry at boot rather than narrowing nothing.

A caller's identity reaches the catalog as a visitor id, never an account id.
The two are separate identifier spaces and no surface substitutes one for the
other; a context that cannot name its owning visitor builds the unbound
context instead.

"Every surface" is proven by enumerating surfaces.
`OpenAgents.Tools.Selector.reachable/2` narrows nothing when it is given no
caller, so a new catalog builder that omits `:reach` offers the whole catalog
and every existing test stays green. `OpenAgents.DependencyBoundaryTest`
compares the set of modules whose compiled import table names
`OpenAgents.Tools.Selector` against the two this contract names, and requires
each of them to name `OpenAgents.Tools.Reach` as well.
`test/openagents/tools/reach_test.exs` enumerates the other axis, the tools
and their declared requirements.

Evidence: `OpenAgents.Tools.Reach`, `OpenAgents.Tools.Selector`,
`OpenAgents.Tools.AdmittedCatalog`, `test/openagents/tools/reach_test.exs`,
`test/openagents/chat/open_router/tool_runtime_test.exs`, and
`OpenAgents.DependencyBoundaryTest`.

### TOOL-006 — The shipped tool catalog is a closed, read-only set

Status: Current

The catalog the product installs at boot is enumerated, not accumulated. Every
module in `config/config.exs` under `:tools` is read-only, requires an
authority every conversation caller already holds, and is admitted by name.
A tool that ships must work for every caller that can see it; offering a tool
that always refuses trains the model and the person to ignore refusals.
TOOL-005 narrows the offer to what this caller can reach; this invariant
narrows what exists to be offered at all. Neither substitutes for the other.

Modules that are not admitted stay in `lib/openagents/tools/` and stay under
test through the broader fixture catalog in `config/test.exs`, which must
remain a superset of the shipped set. Unregistering is not deleting, and being
under test is not admission. Re-admitting a module is a policy change subject
to the criteria in `docs/2026-08-23-agent-tools-zero-base.md`.

Evidence: `OpenAgents.Tools.Registry`, `OpenAgents.Tools.ConversationExecutionContext`,
and `test/openagents/tools/shipped_catalog_test.exs`.

### DEGRADE-002 — Tool degradation is explicit and deterministic

Status: Current

Unknown versions, invalid schemas or arguments, scope/authority refusal,
unsupported effects, cancellation, timeout, crashes, and oversized/invalid
output become typed bounded outcomes. They never silently execute a substitute
tool, widen scope, expose raw exceptions, or fabricate success.

Evidence: `OpenAgents.Tools.Runner` and its failure-path tests.

Lexical recall unavailability is the typed `lexical_unavailable` tool failure.
The failed step remains in the receipt and the provider may only describe the
available path honestly; it may not guess at history or silently substitute a
different authority plane.

Evidence: the committed recall evaluation, `OpenAgents.TurnToolLoopTest`, and
degradation tests in `OpenAgents.Tools.ConversationRecallToolsTest`.

## Delegated work

### WORK-001 — Delegated jobs are durable, budgeted, governed, and never die silently

Status: Current

A `deep_work.v1` call is only delegation, never execution: it starts one
durable `work_jobs` row scoped to the caller's conversation and owner and
returns immediately with a job reference, so the requesting turn or voice
response acknowledges in one sentence while the work runs server-side. The
worker drives the same configured text provider under the same composed
persona instructions, the same captured tool-catalog snapshot, and the same
governed `OpenAgents.Tools.Runner`, with each tool call committed as an ordered
`work_job_steps` row before execution and continued only from its committed
terminal outcome. A job's authorities never include `work.delegate` or
`memory.write`, its provider request never advertises `deep_work`, and an
arriving recursion call is refused with a durable typed outcome, so
delegation depth stays at one and a job cannot widen the caller's authority.

Every job is bounded — thirty-two tool calls, thirty-two continuations, a
ten-minute wall clock — and a tripped bound refuses the over-limit call with
a durable typed step outcome, forces one final tool-free report response, and
ends the job as explicit `budget_exhausted`. Every terminal path (`completed`,
`failed`, `interrupted`, `budget_exhausted`) stores a non-empty report:
streamed report text is persisted as it arrives, and a job that dies before a
narrative gets an honest host summary of its committed step evidence.
PostgreSQL constrains status transitions and makes terminal jobs and terminal
steps immutable. A delegation additionally binds one account-owned computer,
its admission-time authority snapshot, its bounded execution budget, and its
immutable request. Only the generation-fenced ACP session ID may change after
admission; workers read computer, agent, working directory, and wall-clock
authority from the immutable fields. Startup recovery RESUMES orphaned active
jobs (#97): it
restarts each job's supervised worker, which re-claims through the generation
fence and continues — a delegation by its durably checkpointed ACP session id,
deep work from its committed evidence. A job whose cluster singleton is still
alive (a fleet survivor) answers `already_started` and is never disturbed or
double-adopted; the restart is recorded as a degraded `runtime_restarted`
incident; and only a job whose worker cannot start at all is finalized
`interrupted` with its partial report intact. On terminal state the
bounded report becomes a durable assistant conversation message linked to the
job, so it enters ordinary recall and later provider context; a live voice
session receives the report through the existing typed-message injection as a
best-effort projection that can never rewrite the committed terminal state.

Evidence: `OpenAgents.Work`, `OpenAgents.Work.Job`, `OpenAgents.Work.JobStep`,
`OpenAgents.Work.JobServer`, `OpenAgents.WorkRecovery`, `OpenAgents.Tools.DeepWork`, the
work-job migration triggers, `OpenAgents.WorkJobTest`, and
`OpenAgents.DeepWorkToolLoopTest`.

### SELF-EDIT-001 — Every behavior change is anchored to a pushed commit (2026-08-19)

Status: Current

OpenAgents may edit her own source only through governed repository tools acting
on a per-job clone of her own forge, and nothing she writes becomes running
behavior except through the receipted pipeline. Concretely:

- **The pushed commit is the artifact.** Every behavior change to the
  running system is anchored to a commit pushed to the forge; the WAL entry
  that acked that push is its durable digest. Hot-loaded code is a
  *projection* of a pushed commit, never authority: a node restart that
  converges to the promoted fleet target (or, absent one, to the image) is
  always correct and loses nothing that was ever authority.
- **Mutation stays inside the job's clone.** Repository write tools operate
  only under that job's workspace clone whose origin is the local forge —
  never GitHub, never the baked source, never another job's clone. Pushes go
  only to that job's own `openagents/job-<id>` branch; a push to any other ref is
  refused with a typed outcome. The clone is removed when the job ends.
- **Promotion is an operator action.** No OpenAgents tool can promote, deploy, or
  hot-load. The job's report links the pushed SHA; the `/admin/forge`
  Promote click (enumerated by ADMIN-001) is the human approval receipt, and
  the allowlist of hot-loadable modules remains operator-owned data. The
  operator API under FLEETPROMOTE-001 is the same approval by a scripted
  operator, not a way around one.
- **Receipts reconstruct what ran.** Tool outcome receipts carry the commit
  SHA of every push; push, build, and deploy receipts chain from that SHA;
  together they let an operator reconstruct exactly which code was live
  when, with no step inferred.

"No OpenAgents tool can promote, deploy, or hot-load" quantifies over every
tool module, not over the six the product ships, so it is proven that way.
`OpenAgents.DependencyBoundaryTest` reads the compiled import table of every
module in `lib/openagents/tools/` and fails when one gains a dependency on
`OpenAgents.Forge.Promotion`, `OpenAgents.Forge.Targets`,
`OpenAgents.Forge.HotLoader`, `OpenAgents.Forge.Deployment`,
`OpenAgents.Forge.RelupDeployment`, or `OpenAgents.Forge.RollingReplacement` —
including a module that is written and tested but not yet admitted, which is
where the next tool comes from. `sarah.tool.scv_deploy.v1` reaches
`OpenAgents.SCV.Deployments` rather than any of these; SCV-001 governs it, and
it starts a coding agent rather than changing what the fleet runs.

Evidence: `OpenAgents.Tools.Repository` (clone confinement, branch discipline,
typed refusals), `OpenAgents.Work.Coding`, `OpenAgents.Forge.Pushes` /
`OpenAgents.Forge.Targets` / `OpenAgents.Forge.HotLoader` receipts, ADMIN-001,
`OpenAgents.CodingJobTest`, the repository tool tests in
`test/openagents/tools/repository_mutation_tools_test.exs`, and
`OpenAgents.DependencyBoundaryTest`.

### SCV-001 — An SCV spends our capacity only under operator authority and fixed bounds

Status: Current

An SCV deployment is the one lane where OpenAgents runs a coding agent on
hardware we own and pay for, rather than on a computer the person paired and
powers. Every other execution path is bounded by something outside our
control; this one is not, so its ceiling is written down and enforced rather
than assumed.

- **One entry point, and it is operator-only.** Every surface that starts an
  SCV enters `OpenAgents.SCV.Deployments.start/2`, which refuses any account
  that is not an OpenAgents operator with `:operator_required` before a row is
  written or a process is spawned. The refusal lives in the code that starts
  the run, not in whatever advertised it, so a model that calls the tool on
  behalf of a signed-in non-operator is refused exactly as an unauthenticated
  caller is. `sarah.tool.scv_deploy.v1` declares `external_effect` under the
  `explicit_operator_approval` class, and the matching receipt is minted only
  for operators, so `OpenAgents.Modules.SurfacePolicy` refuses the same call a
  second time and independently.
- **It is a work job, not a second job system.** The durable unit is a
  `work_jobs` row of kind `scv`, so an SCV inherits the seven statuses, the
  PostgreSQL transition triggers, the Horde cluster singleton, the
  `owner_node`/`generation` fence, the startup recovery sweep, cancellation,
  and the bounded report that lands in the conversation as a durable assistant
  message. An interrupted SCV is finished honestly rather than resumed: a
  killed coding-agent process has no session to re-attach, so a worker that
  adopts a row at a bumped generation ends it `interrupted` instead of paying
  for the same objective twice.
- **Four bounds, fixed at admission.** The objective is capped at 2,000 bytes;
  the wall clock and the captured-output ceiling are snapshotted onto the row
  when the run is admitted, so a configuration change mid-run cannot widen a
  run already in flight; the executor enforces the wall clock and this
  application independently backstops it; and the number of SCVs queued or
  running across the whole application is capped by configuration. A tripped
  concurrency ceiling refuses the call with `:scv_capacity_reached` rather
  than queueing unbounded work.
- **It reads; it does not write.** The run is admitted only under the
  `read_only` permission profile in the `opencode-core` environment, against a
  disposable clone of a forge repository at an exact 40-character revision
  resolved by the application. The caller names a repository the operator may
  read as `owner/name`; a filesystem path from a caller never reaches an SCV.
  The workspace is removed on every terminal path, including the one that runs
  when the worker died. In staging and production that workspace must sit on a
  durable path: a container's `System.tmp_dir!()` is the writable image layer
  on the boot disk, which the node already shares with Docker and the import
  workspace, so a repository cloned there is how a node runs out of room while
  its durable volume idles. Configuration names the root, and a node refuses
  to boot with an SCV lane enabled and a clone root under `/tmp`.
- **No job may deploy one.** `scv.deploy` is a turn authority only. Job
  authorities never include it, so neither a deep-work job, a delegation, a
  coding job, nor an SCV can start another SCV.
- **It is metered and visible.** Token usage is recorded into the shared
  `inference_grants` ledger, the same one the coding kind uses, so "how much
  did an SCV spend" is a query. Each run's lifecycle events reach the
  content-free public projection on the status page through the existing
  `[:openagents, :scv, :event]` telemetry, and every non-completed terminal is
  recorded as a typed incident.
- **It is off by default.** The lane is admitted only when the `scv_deploy`
  feature is enabled, which `OpenAgents.RuntimeConfig` accepts only alongside
  the work lane and tools, only with an admitted model slug and bounds, and
  only above the staging gate that admits advanced product features.

The one-entry-point clause quantifies over surfaces, and
`test/openagents/scv/deployments_test.exs` proves the refusal at the gate
rather than that every caller passes through it.
`OpenAgents.Work.start_scv/1` is what an admitted deployment calls to write
the row and start the worker, and it is public, so a second caller would be an
SCV that skipped admission. `OpenAgents.DependencyBoundaryTest` compares the
set of modules whose compiled import table names `start_scv/1` against the one
this contract names, so that caller fails the proof before it can exist.

Evidence: `OpenAgents.SCV.Deployments`, `OpenAgents.Work.Scv`,
`OpenAgents.Work.ScvServer`, `OpenAgents.Tools.ScvDeploy`, `OpenAgents.Work.Job`
(the `scv` kind), `OpenAgents.RuntimeConfig`,
`test/openagents/scv/deployments_test.exs`, and
`OpenAgents.DependencyBoundaryTest`.

### OUTCOME-001 — An agent-authored claim is accepted only against the accepted-outcome contract

Status: Current

When an agent claims that work is complete, the claim counts as an accepted
outcome only when every part the contract names holds; anything less is a
typed non-accepted result, and human-only work stays outside the gate
entirely.

- **The issue is the canonical record, and it must be scoped.** A claim
  anchors to an issue that states its problem, scope, acceptance criteria,
  and success metrics. A claim against an issue missing any of those sections
  is `incomplete`, never accepted.
- **The attempt is bound, not implied.** Each execution attempt records the
  issue number, repository, authority, budget, and exact revision it
  produced. An attempt bound to a different issue or repository, an
  unadmitted verifier, or a violated producer-verifier separation policy is
  `unauthorized`.
- **Green must have been able to be red.** The claim records an admitted
  verifier, a falsifier, and a terminal result. A failed terminal result is
  `failed`, and a result carrying any of the five named false-green classes
  — `false_green_fixture_assert`, `false_green_api_mirror`,
  `false_green_mocked_seam`, `false_green_coverage_theater`,
  `false_green_round_up` — is `failed` even when the verifier reported green.
- **Every criterion names its evidence.** An accepted outcome explains which
  receipt satisfied each acceptance criterion, so the issue page can show the
  mapping; a criterion with no evidence makes the claim `incomplete`.
- **The public projection is content-free about private material.** A
  projection of an evaluation carries the result state, typed reasons,
  criterion names, and public receipt references only — never prompts, logs,
  private repository names, or private receipt references.
- **Human-only work is not gated.** Work by a human actor and repositories
  with agents disabled evaluate to `not_applicable` and remain fully usable.

The committed contract is `priv/api-contracts/accepted-outcome-v1.json`, and
`OpenAgents.AcceptedOutcome.validate/1` refuses a contract whose required
sections, attempt fields, false-green classes, or result states drift from
the code that enforces them.

Evidence: `OpenAgents.AcceptedOutcome`,
`priv/api-contracts/accepted-outcome-v1.json`,
`docs/accepted-outcome-contract.md`, and
`test/openagents/accepted_outcome_test.exs`.

### THREAD-001 — A thread owns its own model authority, and names it exactly once

Status: Current

A thread is the unit of agent work: one objective, its turns, its transcript,
and its budget (`docs/taxonomy.md`). It is account-scoped, plural, and
disposable. A thread belongs to the account's owner visitor and requires no
conversation, so DATA-002 is unchanged — the account still has exactly one
conversation, and a thread is not one.

- **A grant names exactly one fence.** `inference_grants.conversation_id` is
  nullable and `inference_grants.thread_id` is nullable, and
  `inference_grant_exactly_one_fence` refuses any row that names both or
  neither. A grant is the only way a client reaches a model without holding a
  provider key, so an unfenced grant would be unattributable spend and a
  doubly-fenced one would be spend attributed twice. PostgreSQL refuses both,
  and `OpenAgents.Inference.Grant.mint_changeset/1` refuses the same rows
  earlier.
- **A fence, once set, cannot be acquired or exchanged.** The immutability
  trigger compares both fence columns with `IS DISTINCT FROM`, so a
  thread-scoped grant cannot later acquire a conversation and a
  conversation-scoped grant cannot later acquire a thread. Comparing a NULL
  column with `<>` yields NULL and raises nothing, which is exactly how a
  machine-less grant could once have acquired a machine
  (`priv/repo/migrations/20260819080000_allow_machineless_inference_grants.exs`).
- **A thread's authority is singular.** At most one active grant may name a
  thread, enforced by `inference_grants_one_active_thread_index`.
  `OpenAgents.Threads.mint_grant/1` revokes the thread's active grants and
  advances `threads.generation` in the same transaction as the mint, so an
  earlier generation's token is provably stale rather than merely old.
- **Authority does not outlive the thread.** Every terminal transition
  (`OpenAgents.Threads.finish/2`, `OpenAgents.Threads.cancel/2`) revokes the
  thread's active grants inside the transaction that writes the terminal row,
  and `mint_grant/1` refuses a thread that is not open. Deleting a thread — or
  the account, under the DATA-004 cascade — deletes its grants with it.
- **A thread is bounded.** The objective is capped at 32 KB and the terminal
  report at 32 KB, both by check constraint; every transcript entry is pinned
  to `openagents.thread.event.v1` with a 16 KB payload ceiling and no
  `updated_at`; and a thread is open with no report or terminal with one,
  never both and never neither.

- **Authority is capped at admission.** `OpenAgents.Threads.open/3` refuses an
  account already holding `maximum_open_threads_per_account` open threads with
  `:thread_quota_reached`, and `POST /api/v3/threads` renders that as a `429`
  naming the limit. The cap is taken before any row is written, so a refused
  caller leaves nothing behind. Because a thread has at most one live grant,
  capping open threads caps the account's concurrent thread-scoped authority by
  the same number.
- **A thread's budget is its own.** `OpenAgents.Threads.ceilings/0` reads the
  `thread_grant_*` settings and passes them to `OpenAgents.Inference.mint/1`,
  which otherwise applies the delegation ceilings. A delegation is one probe
  run the server admitted before minting anything; a thread is authority a
  caller asked for. The two budgets are stated separately, and neither moves
  the other.
- **Expiry revokes without being asked.** `OpenAgents.Threads.reap_expired/1`
  runs at admission and on every read of a thread: an active grant past
  `expires_at` becomes `expired`, and an open thread that has minted authority
  and holds none becomes `failed` with `authority_expired`. An abandoned thread
  therefore cannot hold an account's admission slot, and a lapsed token is not
  merely refused on presentation — it stops being live in the ledger.
- **Authority reaches only the account that opened the thread.**
  `OpenAgents.Threads.get_for_user/2` joins through the owner visitor, so
  another account's thread id resolves to `nil` and the route refuses it with
  the same `not_found` an absent id gets. No route returns a grant token for a
  thread the caller did not open, and the token is returned exactly once, at
  the mint.

  Amended 2026-08-23 (issue #174): that sentence quantifies over routes, so it
  is enumerated rather than sampled. A plaintext grant token comes into
  existence in one place, `OpenAgents.Inference.mint/1`, and leaves
  `OpenAgents.Threads` through `mint_grant/1` and `open_and_mint/2,3`, so every
  module that can hold one carries a compiled import edge to one of them.
  `OpenAgents.Threads.GrantTokenReachTest` reads those edges from each module's
  BEAM import table and asserts four exact sets: the modules that mint a token
  (`OpenAgents.Threads`, `OpenAgents.Work.Coding`,
  `OpenAgents.Work.DelegationServer`, `OpenAgents.Work.Scv`), the modules that
  receive one from a thread (`OpenAgentsWeb.ThreadController` alone), the
  routed handlers among them (the same one controller), and
  `OpenAgents.Threads`'s own export table, so a new function that hands a
  caller a token is classified before anything can call it. It then dispatches
  every route the router gives that controller and requires a token in the body
  only at the mint. A second route that renders a grant fails there.

Evidence: `OpenAgents.Threads`, `OpenAgents.Threads.Thread`,
`OpenAgents.Threads.Event`, `OpenAgents.Inference.mint/1`,
`OpenAgents.Inference.expire_elapsed_for_owner/1`,
`OpenAgentsWeb.ThreadController`,
`priv/repo/migrations/20260823221415_create_threads_and_thread_events.exs`,
`priv/repo/migrations/20260823221416_allow_thread_scoped_inference_grants.exs`,
`test/openagents/threads/grant_fence_test.exs`,
`test/openagents/threads/grant_token_reach_test.exs`,
`test/openagents/threads_test.exs`, and
`test/openagents_web/controllers/thread_controller_test.exs`.

## Tenant deployment control plane

### DEPLOYPLANE-001 — A deployment intent carries no authority

Status: Current

A deployment request states what a tenant wants deployed. Every authority
decision comes from durable records instead: repository membership rechecked at
each sensitive transition, the environment's protection policy, and published
evidence. A request names a full 40-character commit SHA and a `sha256:`
artifact digest; a branch or tag is provenance, never something resolved later.

The plane authenticates a human holding `deployments:write` or a short-lived
workflow grant. `forge:write` is not deployment authority, and no route in this
plane reaches the operator fleet-promotion surface behind
`deployments:promote`, which FLEETPROMOTE-001 governs. A private repository is readable only by a member, and
cross-repository reads, approvals, cancellations, and provider bindings are
denied.

Evidence: `OpenAgents.Deployments`, `OpenAgents.Deployments.Authority`,
`OpenAgents.Deployments.Principal`, `OpenAgentsWeb.DeploymentController`,
`OpenAgentsWeb.ApiRouteAuthority`, `test/openagents/deployments_test.exs`, and
`test/openagents_web/controllers/deployment_controller_test.exs`.

### DEPLOYPLANE-002 — A workflow grant binds to exactly one context

Status: Current

A grant issued to a workflow is single-context and short-lived: it binds one
repository, one environment where applicable, one source ref, one source
workflow, and one workflow run ID, with a clamped lifetime. Presenting a grant
cannot widen repository, environment, commit, artifact, or audience authority,
and a workflow principal can never approve a request. Revocation takes effect
before the next sensitive transition.

Evidence: `OpenAgents.Deployments.WorkflowGrant`,
`OpenAgents.Deployments.Authority`, and `test/openagents/deployments_test.exs`.

### DEPLOYPLANE-003 — Policy admits a run on exact bytes, with a durable explanation

Status: Current

`OpenAgents.Deployments.Policy` evaluates allowed branches, allowed tags,
allowed source workflows, freeze, deployment window, artifact age, required
checks, and required approvals, and persists an explanation for every rule it
evaluated. A required check satisfies a requirement only when it names the same
commit SHA and the same artifact digest and is younger than the environment's
validity limit, so a green result cannot be replayed onto different bytes. A
missing required check leaves the request pending rather than admitting it.
Approvals honor separation of duties: a requester cannot approve its own
request. Preview environments may supersede an in-flight request; production
never supersedes implicitly.

Evidence: `OpenAgents.Deployments.Policy`,
`OpenAgents.Deployments.Protection`,
`test/openagents/deployments/policy_test.exs`, and
`test/openagents/deployments_test.exs`.

### DEPLOYPLANE-004 — One lifecycle defines every legal transition

Status: Current

`OpenAgents.Deployments.Lifecycle` is the only definition of legal deployment
states and transitions, and transitions are enforced transactionally against
the durable row. Terminal states have no successors, a run cannot skip
`deploying` on its way to `succeeded`, and a run already `deploying` cannot be
superseded. Every transition appends a sequenced deployment event whose payload
is bounded and redacted, so event polling, subscriptions, and receipts cannot
disclose a secret.

Evidence: `OpenAgents.Deployments.Lifecycle`, `OpenAgents.Deployments.Event`,
`test/openagents/deployments/lifecycle_test.exs`, and
`test/openagents/deployments_test.exs`.

### DEPLOYPLANE-005 — Only an admitted, immutable execution reaches a provider, and uncertainty fails

Status: Current

A provider receives an immutable execution object built after admission. It
never receives caller credentials, its idempotency is keyed by run ID, and
secrets are resolved at execution time only for its own bound environment as
references rather than stored values. A provider failure, exception, exit,
timeout, or unknown result terminalizes the run as failed; only an explicit
provider success produces a success receipt.

`OpenAgents.Deployments.Worker` claims queued runs under renewable leases,
re-evaluates policy and membership before handing work to the provider,
observes cancellation during execution, and reconciles runs whose lease expired
after a crash. The worker starts only when the `deployment_control_plane`
feature is enabled, validated by `OpenAgents.RuntimeConfig`; the API surface
records and evaluates runs regardless.

Evidence: `OpenAgents.Deployments.Execution`,
`OpenAgents.Deployments.Provider`, `OpenAgents.Deployments.Providers.Fake`,
`OpenAgents.Deployments.SecretResolver`, `OpenAgents.Deployments.Worker`,
`OpenAgents.RuntimeSupervisor`, `test/openagents/deployments_test.exs`, and
`test/openagents/runtime_config_test.exs`.

## Fleet release authority

### FLEETPROMOTE-001 — Fleet promotion needs the operator scope and live operator standing

Status: Current

Promoting a commit as the OpenAgents fleet target is release authority over
this system, not a tenant action. DEPLOYPLANE-001 governs a repository
deploying its own code under `deployments:write`; this governs the OpenAgents
release itself, and no route in that plane reaches it.

Two conditions authorize every promotion, and holding one is never enough:
the credential carries the exact `deployments:promote` scope, and
`OpenAgents.Accounts.admin?/1` is true for the promoting account at request
time. The second check is what makes operator removal effective immediately,
including for an unexpired privileged token. Authority is never inferred from
a login, a repository membership, a Git push credential, or `forge:write`.
Only a current operator can be issued the scope at all, and a privileged
credential's maximum lifetime is shorter than an ordinary one's.

Identity is exact. A promotion names one full 40-character commit SHA that the
WAL-backed repository already contains, so a push never promotes itself and
the API cannot ask for "whatever is newest". A caller-generated idempotency
key names one promotion: the same key with the same bytes returns the original
target, and the same key with different bytes is refused. An optional
expected-current-target ID is a compare-and-set precondition, so two
concurrent operators cannot unknowingly supersede each other.

The `/admin/forge` **Promote** button and `POST /api/v3/admin/forge/targets`
are one authority path, not two implementations of one policy. Both call
`OpenAgents.Forge.Promotion`, which calls `OpenAgents.Forge.Targets.promote/4`,
so both write the same append-only `forge_fleet_targets` receipt carrying the
promoting operator's identity in `promoted_by`, and both broadcast the same
lifecycle event. The API states an intent only: the builder, classifier,
direct-load, relup, and rolling-replacement lanes still own execution. A
promotion publishes no image identity and admits no node; RELEASE-006 governs
what a booting node may run, and this surface never widens it.

Every attempt — granted or refused — records bounded audit evidence naming the
operator, the repository, the environment, the source channel, the request ID,
and a digest of the idempotency key. Neither the plaintext credential nor the
plaintext key is ever stored, and a status response discloses no node
identity, filesystem path, or unrestricted failure detail.

Refusals carry the one `/api/v3` envelope, `OpenAgentsWeb.ApiError`, with a
stable code per refusal reason so a release client can tell "you may not do
this" from "someone promoted first" from "those bytes are not in the forge".

"One authority path, not two implementations" is a claim about every caller,
so the callers are the proof. `OpenAgents.DependencyBoundaryTest` asserts two
exact sets from the compiled import tables: `OpenAgents.Forge.Promotion` is
the only module that calls `OpenAgents.Forge.Targets.promote/4`, and
`OpenAgentsWeb.AdminForgeLive` and `OpenAgentsWeb.FleetTargetController` are
the only modules that call `OpenAgents.Forge.Promotion`. A third surface, or a
second writer that skips the scope and standing checks, fails there.

Evidence: `OpenAgents.Forge.Promotion`, `OpenAgents.Forge.Targets`,
`OpenAgentsWeb.Plugs.OperatorApiTokenAuth`,
`OpenAgentsWeb.FleetTargetController`, `OpenAgentsWeb.AdminForgeLive`,
`OpenAgents.ApiTokens`, `OpenAgentsWeb.RouteAuthority`,
`OpenAgentsWeb.ApiRouteAuthority`, `OpenAgentsWeb.ApiError`,
`OpenAgents.DependencyBoundaryTest`,
`test/openagents/forge/promotion_test.exs`,
`test/openagents_web/controllers/fleet_target_controller_test.exs`, and
`test/openagents_web/route_authority_test.exs`.

## Interface and release

### VOICE-001 — Spoken identity is admitted before media

Status: Current

Standalone OpenAgents's first voice artifact is `openagents.voice.openai.marin.v1` using
native OpenAI Realtime `gpt-realtime-2.1` at low reasoning effort. It is a
deliberate repository-local revision of the earlier Leda direction, not a
silent fallback or a change to One. Boot refuses unadmitted architecture,
provider, model, voice, reasoning, or duration values. Any future custom voice,
Leda cascade, or built-in replacement requires a reviewed artifact revision
and regression evidence.

Evidence: `OpenAgents.Voice.Config`,
`test/openagents/voice/config_test.exs`, and `OpenAgents.Voice.ConfigTest`.

### VOICE-002 — Browser media admission cannot acquire server authority

Status: Current

Voice is default-disabled. When enabled, an active authenticated user may send
only a bounded SDP offer through the same-origin, CSRF-protected endpoint.
Phoenix supplies the OpenAI credential, session configuration, and stable
privacy-preserving safety identifier derived from OpenAgents's local user ID. The browser receives only a bounded SDP
answer; provider credentials, call identity, protected configuration, and
future tool control remain server-side. Invalid identity, configuration, SDP,
provider location, and provider failure all fail closed without raw provider
details.

Evidence: `OpenAgentsWeb.VoiceCallController`,
`OpenAgents.Voice.OpenAI.CallClient`, `OpenAgents.Voice.OpenAI.CallClientTest`, and
`OpenAgentsWeb.VoiceCallControllerTest`.

### VOICE-003 — Durable voice history is generation-fenced

Status: Current

PostgreSQL owns every admitted voice generation and permits at most one active
generation per conversation. Provider events, response receipts, and
transcript items repeat the admitted generation; both runtime matching and
database constraints reject stale work. Ordered normalized events commit under
a locked session row, exact provider-event retries are idempotent, immutable
session provenance cannot be rewritten, and a terminal generation rejects
late events.

The supervised runtime owns only live connection state. Startup or process
loss makes the affected generation explicitly failed; it never invents a
successful resume or transcript.

Evidence: `OpenAgents.Voice`, the `create_voice_runtime` migration,
`OpenAgents.VoiceSessions.SessionServer`, `OpenAgents.VoiceRecovery`,
`test/openagents/voice_sessions_test.exs`, `OpenAgents.VoiceTest`, and
`OpenAgents.VoiceSessionsTest`.

### VOICE-004 — Only bounded provider-neutral voice evidence becomes durable

Status: Current

OpenAI wire events are decoded behind the provider adapter. Audio deltas,
partial transcript deltas, credentials, SDP, provider error text, and unbounded
wire payloads never enter OpenAgents's durable voice domain. Final user
speech may be stored; OpenAgents speech is bound to a started response receipt and
is marked interrupted when barge-in supersedes it. Completion without a
started receipt rolls back. Provider-reported usage remains absent when the
provider did not report it rather than being invented as zero.

Call audio is the single deliberate exception, and it enters through a
different door: not the provider event path but a browser upload, under the
separate bounds of VOICE-012. The distinction is the point — a bounded recorded
artifact is not the same as letting the provider wire into the database.

Evidence: `OpenAgents.Voice.ProviderEvent`,
`OpenAgents.Voice.OpenAI.EventDecoder`, `OpenAgents.Voice.ResponseReceipt`,
`OpenAgents.Voice.TranscriptItem`, and their voice runtime tests.

### VOICE-005 — Microphone capture is explicit, fenced, visible, and finite

Status: Current

Only a direct `START VOICE` action may request microphone access. New tracks
begin disabled and may transmit only while the browser peer and control channel
are open, playback is usable, the user has not muted, and LiveView projects a
ready state from the current server generation. Reconnect, failure, end,
navigation, or hook destruction disables and stops every media track, closes
the data channel and peer connection, clears remote audio, stops and finalizes
any recording, and best-effort closes the server generation. Typed chat never
asks for microphone access.

Recording is part of what capture means, so it is disclosed on the same terms.
While recording is on, the surface that carries `START VOICE` states before the
microphone opens that calls are recorded, stored, and readable by an operator,
and names the retention window; a visible marker announces capture while it is
running, and appears only while it is actually running. Recording off makes no
such claim anywhere.

Evidence: `assets/js/voice_controller.js`, `assets/js/voice_state.mjs`,
`assets/js/voice_recording.mjs`, their Node tests, the disclosure tests in
`OpenAgentsWeb.ChatLiveTest` and `OpenAgentsWeb.DataControllerTest`, and
`assets/test/voice_state_test.mjs`.

### VOICE-006 — Voice controls project server truth and preserve typed OpenAgents

Status: Current

Browser peer events cannot claim a durable listening, responding,
interrupted, ended, or failed state. The visible lifecycle is derived from the
browser-scoped, generation-fenced PostgreSQL session projected by LiveView.
Explicit interruption commits before provider cancellation. Voice admission is
refused during a text turn; sending typed input while voice is active ends the
voice generation first, so two OpenAgents responses cannot run in parallel. Voice
failure leaves the typed conversation intact and available.

Evidence: `OpenAgentsWeb.ChatLive`, `OpenAgentsWeb.VoiceCallController`,
`OpenAgents.VoiceSessions`, their tests, and `assets/test/voice_state_test.mjs`.

### VOICE-007 — Every live response freezes one governed OpenAgents context

Status: Current

Automatic provider response creation is disabled. A final user transcript first
becomes a complete conversation message, then Phoenix captures the exact
persona/role, Blueprint, program-or-explicit-baseline receipt, tool catalog,
conversation high-water mark, profile-memory snapshot, selected evidence, and
composed spoken instructions. Only then may Phoenix request a response. A
provider response without that immutable context fails the generation.

Voice presentation may make delivery brief and speech-appropriate, but cannot
override protected identity, evidence grammar, tool authority, or completion
honesty. A session refuses changed persona, Blueprint, or tool-catalog identity
rather than silently mixing revisions.

Long calls stay governed rather than unbounded: when a completed response's
provider-reported input size crosses the configured compaction threshold —
and only at a quiet boundary with no active tool chain, no queued input, and
no compaction already in flight — the host drives one text-only, tool-free
maintenance response under the same frozen context, asking for a progress
summary that preserves exact values and the next action. That summary is
byte-bounded and durable on the session row (`compaction_summary`,
`compaction_count`) before the runtime deletes old provider items it knows by
id and injects one bounded system summary item. The summary is continuity
evidence only: it never rewrites or displaces `voice_transcript_items` /
`messages` transcript authority, the compaction response cannot re-trigger
itself, pruning never happens without a persisted summary, and new person
input always supersedes an in-flight compaction.

Evidence: `OpenAgents.Voice.ContextCapture`, `voice_response_contexts`,
`OpenAgents.Context.Composer`, `OpenAgents.VoiceSessions.SessionServer`,
`OpenAgents.Voice.record_compaction_summary/3`, and governed context and
compaction tests in `OpenAgents.VoiceSessionsTest`.

### VOICE-008 — Realtime function calls use the governed tool runner

Status: Current

Realtime exposes the same captured typed registry used by text turns. Model
function arguments remain proposals: Phoenix validates call identity, schema,
scope, authority, consent, generation, and module version through
`OpenAgents.Tools.Runner`. Each request and normalized terminal outcome is durable
before any `function_call_output` or continuation is sent to OpenAI. Unknown,
malformed, unauthorized, stale, interrupted, and failed calls cannot become an
effect claim. Durable tool steps retain the raw model arguments as user-owned,
deletable conversation evidence alongside the canonical argument digest;
durable provider events and operational telemetry remain digest-only and
content-free.

Host bounds refuse rather than kill: a call past the per-cycle tool budget is
refused with a `tool_call_limit_reached` continuation and one tool-free report
response, never a session failure, and the composed instructions disclose that
the budget exists. Every provider `function_call` item receives a terminal
`function_call_output` — including cancelled calls after a barge-in — so the
provider conversation never holds an orphan call the model must narrate
around. Continuation payloads are byte-bounded; the durable tool step keeps
the full result.

Evidence: `OpenAgents.Tools.Registry.realtime_catalog/1`,
`OpenAgents.Voice.ToolStep`, `voice_tool_steps`,
`OpenAgents.VoiceSessions.SessionServer`, and voice tool tests in
`OpenAgents.VoiceTest` and `OpenAgents.VoiceSessionsTest`.

### VOICE-009 — Text and voice share one append-only conversation authority

Status: Current

Final user transcriptions and completed OpenAgents transcripts project into the
same ordered `messages` table as text. Provider item identity makes retries
idempotent. Interrupted OpenAgents speech is cancelled evidence and never enters
provider history as a complete answer; when it re-enters composed context it
is explicitly labeled interrupted and non-complete, and a barge-in truncates
the provider-side assistant item to the approximate playback position so the
model's conversation cannot retain speech the person never heard. PostgreSQL
forbids rewriting voice
message content or provenance; a correction is a later message, not an
in-place edit. Starting a text turn serially ends the live voice generation,
so text and voice cannot produce parallel OpenAgents answers.

Evidence: `messages` voice provenance and transition constraints,
`OpenAgents.Voice.persist_transcript/3`, `OpenAgents.Conversations.provider_messages/1`,
`OpenAgentsWeb.ChatLive`, cross-modal chronology tests in `OpenAgents.VoiceTest`, and
`priv/sarah/evals/voice/corpus.v1.json`.

### VOICE-010 — New voice admission is live-governed, globally bounded, and attributable

Status: Current

The deploy flag and append-only PostgreSQL release control are independent.
Only the latest `open` control admits a new call; `draining` and `disabled`
refuse it without ending active calls or typed OpenAgents. Every session pins the
exact control row. Admission serializes on a database advisory lock before
counting active sessions, so simultaneous authenticated requests cannot exceed the
global budget. Per-conversation attempt, one-active-generation, duration,
response-token, session-token, estimated-cost, tool, and payload limits remain
separate, explicit ceilings. Session budget ceilings are abuse backstops, not
working limits, and their enforcement is disclosed: one host notice at 80%
lets the model wrap up, and a budget-ended session records and surfaces
`usage_budget_reached` rather than presenting as a silent disconnect.

Evidence: `OpenAgents.Voice.ReleaseControl`, `OpenAgents.Voice.admit_session/2`,
`voice_release_controls`, `OpenAgents.Voice.Usage`,
`OpenAgents.Voice.ReleaseOperationsTest`, and
`test/openagents/voice/release_operations_test.exs`.

### VOICE-011 — Voice operations are measurable without becoming a content sink

Status: Current

Operational telemetry is built from strict fields and may never contain
credentials, browser/conversation identity, SDP, provider call identity, raw
audio, transcript content, composed instructions, raw tool arguments/results,
or provider error prose. Recording adds bytes to the product but not to this
path: chunk payloads and content digests never enter telemetry, aggregate
reports, or logs, while byte counts and durations remain operational fields. Browser observations accept only a finite event enum,
derive a reduced browser family/major on the server, and stop at 64 events per
session. Aggregate reports read only timing, state, normalized kind, browser,
usage, and cost fields. Missing samples remain missing and block the canary;
health cannot substitute for media, quality, browser, load, or rollback proof.

Evidence: `OpenAgents.Voice.OperationalTelemetry`,
`OpenAgents.Voice.Operations.Report`, `OpenAgents.Voice.ClientEvent`,
`OpenAgentsWeb.VoiceTelemetryController`, their redaction and controller tests, and
`test/openagents/voice/release_operations_test.exs`.

### VOICE-012 — Call audio is bounded, sealed, fenced evidence — never authority

Status: Current

Voice media never reaches OpenAgents: it flows browser-to-OpenAI over WebRTC while
the server holds only a lifecycle sideband. A recording is therefore what one
browser uploaded, not what was said. It can be withheld, truncated, or stopped
at will, so it never displaces `voice_transcript_items` as the conversation
record and never becomes evidence for a OpenAgents response.

Audio may become durable only under every one of these at once: recording is
enabled and a recording key is configured, so audio is sealed at rest or not
stored at all; each slice commits under the locked session row against the
admitted generation, in strict sequence, with a repeat of a stored sequence
idempotent and a gap refused; chunk size, chunk count, and total bytes are
explicit ceilings, past which the recording becomes `truncated` and further
slices are refused; and uploads are accepted only within a bounded grace window
after the call ends, because the tail slice arrives after the recorder stops.
The session is resolved from the encrypted session cookie, never from a
client-supplied identifier.

A recording is stored, read, and deleted as a whole ordered concatenation; a
single slice is not media. Statuses distinguish a clean upload from a
truncated, abandoned, or failed one, so partial audio is never presented as a
whole call. Audio carries its own retention window, shorter than the
operational voice window, and is deleted by that sweep and by DATA-004 cascade.

Recording failure never affects the call: an unsupported browser, a blocked
audio graph, a refused upload, or a missing key all yield an unrecorded
conversation rather than a failed one.

Recording is a property of the voice surface, not a per-account setting. While
it is enabled there is no opt-out flag and none may be added without changing
this contract; the disclosure states the situation rather than offering a
choice, and typed chat remains available and is never recorded. No account
route returns stored audio and account export carries recording metadata rather
than its sound, but the operator route named in ADMIN-001 unseals and streams
it; the seal here defends against a stolen database, not against the person who
holds the key.

Evidence: `OpenAgents.Voice.Recordings`, `OpenAgents.Voice.Recording`,
`OpenAgents.Voice.RecordingChunk`, `OpenAgents.Voice.RecordingVault`, the
`create_voice_recordings` migration, `OpenAgentsWeb.VoiceRecordingController`,
`assets/js/voice_recording.mjs`, `OpenAgents.Voice.RecordingsTest`,
`OpenAgentsWeb.VoiceRecordingControllerTest`, `assets/test/voice_recording_test.mjs`,
and `test/openagents/voice/recordings_test.exs`.

### ADMIN-001 — One operator reads across accounts, including call audio, and writes on an enumerated set of surfaces

Status: Current

IDENTITY-002 confines every ordinary server path to the active user's own data.
`/admin` is the second deliberate exception after LEADERBOARD-001, and it is
the opposite kind: the leaderboard publishes a narrow projection to the
internet, while this reads a wide one for exactly one person.

Operator access is an allowlist of GitHub's immutable numeric IDs, never of
logins — a login can be renamed and the freed name claimed by someone else, and
`users.github_id` is already the identity root. A banned account is never an
operator. The check runs on mount and again on every event, so removal from the
allowlist takes effect on the connected socket rather than at the next
reconnect. A non-operator receives exactly what an unauthenticated visitor
receives, with no flash and no distinct status, so the surface never announces
that it exists. No product surface links to it.

This contract states what that authority is, not what it ought to be. It
constrains nobody; it makes the surface countable, and the proof fails when the
count changes.

**What the operator reads.** The `/admin` panel shows the bounded fields of
`OpenAgents.Admin.Call`: account display identity, call lifecycle, model, token
total, transcript-item count, and recording completeness metadata. Calls with no
uploaded recording are listed with the reason rather than hidden, so the panel
cannot present an incomplete history as a complete one. No routed controller
returns transcript content, composed instructions, tool catalogs, provider call
identity, or recall material.

Decrypted call audio is the exception, and it is deliberate.
`OpenAgentsWeb.AdminRecordingController` answers `GET /admin/recordings/:id/audio`
for any account's recording, resolving it through `OpenAgents.Admin.get_recording/1`
and unsealing each chunk from `OpenAgents.Voice.RecordingVault` on the way out.
The sealing under VOICE-012 defends against a stolen database, not against the
operator, and the product says so rather than implying otherwise: the voice
disclosure in `OpenAgentsWeb.MemoryLive` tells every account that call audio is
readable by an operator. A route that hands one person another person's voice is
worth naming exactly, so it is named here and enumerated in the proof.

That read is not audited, and this ledger records the absence rather than
covering it. An access log written by the operator's application into the
operator's database is evidence to the operator and to nobody else, so it would
read as a control while constraining nothing — the failure mode
`docs/taxonomy.md` naming rule 7 exists to prevent. Making the read
accountable needs the signature or external anchor that `docs/forge-operator-independence.md`
already names as missing from the WAL, and until that exists the honest
statement is that the operator can listen and no record of it survives.

**What the operator writes.** The operator path is not read-only. Every write it
holds is enumerated below, and the proof asserts the enumeration rather than the
sentence:

- Promoting an already-pushed commit as the fleet deploy target, from
  `/admin/forge` and from `POST /api/v3/admin/forge/targets`
  (`OpenAgents.Forge.Promotion` into `OpenAgents.Forge.Targets`), receipted with
  the promoting operator's identity in the append-only `forge_fleet_targets`
  ledger. Only SHAs present in the WAL-backed repository are promotable, so the
  surface cannot introduce code — it can only approve code that already survived
  the push path. Under FLEETPROMOTE-001 the token path is stricter than a browser
  session rather than looser.
- Connecting and disconnecting Codex accounts and starting SCV deployments from
  `/admin/scv/accounts` (`OpenAgents.SCV.CodexAccounts`,
  `OpenAgents.SCV.Deployments`).
- Forum moderation: closing, reopening, and pinning a topic and hiding or
  deleting a post, from `OpenAgentsWeb.ForumTopicLive` and from
  `PATCH /api/v3/forum/topics/:id` and `PATCH /api/v3/forum/posts/:id`; and
  approving or rejecting an identity claim from `/admin/forum/claims` and
  `PATCH /api/v3/forum/claims/:id`.
- Suspending and reinstating an agent under `/api/operator/agents/:handle`.
- Creating, authorizing, recording against, and deleting artifact listings under
  `/api/operator/artifact-listings`.
- Creating, cancelling, resuming, and replaying continual-learning jobs under
  `/api/operator/continual-learning/jobs`.

Reading a private forum board and raising a repository's transparency tier to
`glass` are operator reads that widen with the same allowlist
(`OpenAgents.Forum`, `OpenAgents.Transparency`).

None of these touches an account row, a conversation, a message, or a ban.
That bound is what remains of the original read-only claim, and it is the part
that is true.

The enumeration is executable. `OpenAgentsWeb.RouteAuthority` classifies every
router entry, and the proof compares the operator-class routes against a
declared table; separately it compares every module that consults
`OpenAgents.Accounts.admin?/1`, read from each module's compiled import table,
against a second declared table. A new operator route or a new operator gate
anywhere in `lib/` fails the proof until this contract is amended to name it.

Evidence: `OpenAgents.Accounts.admin?/1`, `OpenAgents.Admin`,
`OpenAgents.Admin.Call`, `OpenAgentsWeb.AdminLive`,
`OpenAgentsWeb.AdminRecordingController`, `OpenAgentsWeb.RouteAuthority`,
`OpenAgents.AdminTest`, `OpenAgentsWeb.AdminLiveTest`,
`test/openagents_web/controllers/admin_recording_controller_test.exs`, and
`test/openagents_web/operator_surface_test.exs`.

### DATA-004 — The authenticated user can export and delete OpenAgents product data

Status: Current

The server resolves export and deletion only from the active local user in the
encrypted session and verifies that user owns the internal storage root.
Export provides canonical messages, profile memory, voice summaries,
tool-step evidence (raw arguments plus digests), and the account chat backend's
own runs and event stream, with explicit bounds. That export is scoped to one
conversation; what an account authors outside it leaves through
`GET /data/export/account` under `EXIT-001`. Exact confirmation deletes the visitor root only while text
and voice are inactive; database cascades remove
conversation, memory, receipt, module, collective, and voice records — call
audio included, through `voice_recordings`' cascade to the session. The export
names each call's recording — status, container, size, duration claim, digest,
and that it is encrypted at rest — without embedding the audio, because a JSON
export is the wrong container for Opus and base64 in a text field would be
worse. No product route returns stored audio to an account; what an account
gets is disclosed and exported as metadata, and deletion removes it. The one
route that returns the audio itself is the operator route ADMIN-001 enumerates,
and the voice disclosure states that an operator can read it.
Detailed terminal voice
operations purge automatically after 90 days while the minimal provenance stub
follows canonical voice messages until complete deletion. Disposable semantic
rows cascade with their messages, and the same transaction removes content-free
semantic invalidation receipts only after their authoritative conversation no
longer exists. Governed preference observations, snapshots, effects, and
receipts likewise cascade only through deletion of their owning visitor root.
Private experience scopes, records, evidence, patterns, and frozen banks also
cascade through that root; standalone experience deletion receipts are removed
in the same transaction only after the owner no longer exists.
Derived graph manifests and artifacts cascade with the owner; standalone graph
memberships, outbox events, cascade plans, and operation receipts are likewise
removed in that transaction only after deletion of the visitor root.

The minimal local account record (GitHub numeric ID, current login/avatar,
access status, authentication timestamps, and currently the encrypted GitHub
token ciphertext) is retained so deletion cannot erase a ban or bypass
authorization. The token is never exported. Gate 6 must add and prove explicit
disconnect/revocation and token-removal behavior; product-data deletion must
not be described as removing the token until that implementation lands. A
later account-erasure contract must separately define moderation retention and
re-enrollment behavior.

Evidence: `OpenAgents.DataRights`, `OpenAgentsWeb.DataController`,
`OpenAgents.Voice.Retention`, database foreign keys and purge trigger,
`OpenAgentsWeb.DataControllerTest`, and `OpenAgents.Voice.ReleaseOperationsTest`.

### UI-001 — Authentication gates the one-conversation interface

Status: Current

The public default route is an authentication boundary and cannot invoke
OpenAgents. It exposes one GitHub login action and only bounded authentication error
copy. The protected `/chat` route exposes transcript, contextual turn state,
bounded history, composer, and only the minimal account control required to
show the authenticated GitHub avatar/login and submit logout. User transcript
rows use that same validated GitHub avatar projection. The browser image policy
allows only same-origin/data images and the exact GitHub avatar origin. The
interface contains no conversation list and no workspace/settings chrome. The
sidebar (2026-08-17, an owner-directed reversal of this invariant's earlier
blanket "no sidebar" clause) navigates only OpenAgents's own surfaces — memory,
leaderboard, the operator panel, export — and may never list or switch
conversations.

`/leaderboard` is the one additional route reachable without a session. It is
permitted only because it makes the same guarantee the public root makes: it is
read only, cannot mount or invoke OpenAgents, holds no conversation, exposes no
composer or action, and creates no identity state. It is a published projection
governed by LEADERBOARD-001, not a second product interface, and it does not
introduce navigation chrome into the conversation.

`/admin` is an operator tool rather than a product surface. It is reachable
only by the allowlisted operator under ADMIN-001, cannot mount or invoke
OpenAgents, and holds no conversation. The panel at `/admin` itself only reads
and pages; the writes the wider operator surface holds are enumerated in
ADMIN-001 and reach no account, conversation, message, or ban. It adds nothing
to the conversation interface: no link, no affordance, and no chrome, for
operators and non-operators alike. Being an operator tool is not license for product
chrome — the anti-references in `docs/architecture.md` still describe what the product
does not become.

The boundary clause is enumerated rather than sampled. Per-surface LiveView
tests are what let the operator half of this contract stay green while it was
wrong, and they would do the same for a new product route added outside the
`:authenticated` pipeline. `OpenAgentsWeb.AuthenticatedRouteGateTest`
dispatches every route `OpenAgentsWeb.RouteAuthority` classifies
`:authenticated_browser` without a session and requires each to refuse, so a
route that serves an anonymous visitor fails before anyone writes a test for
it. `OpenAgentsWeb.OperatorSurfaceTest` enumerates the operator half.

Evidence: `OpenAgentsWeb.HomeControllerTest`, the `OpenAgentsWeb.ChatLiveTest` surface
test, `OpenAgentsWeb.LeaderboardLiveTest`, `OpenAgentsWeb.AdminLiveTest`,
`OpenAgentsWeb.AuthenticatedRouteGateTest`, `OpenAgentsWeb.OperatorSurfaceTest`,
`OpenAgentsWeb.Router` browser policy, `docs/architecture.md`, and `docs/component-library.md`.

### UI-002 — Tool activity is a bounded projection of PostgreSQL truth

Status: Current

The interface renders tool activity only from the durable, already-scrubbed
step row: stable step ID, sequence, public capability label, status, the
step's durable `raw_arguments`, the bounded durable result/error, executor id
and disclosure, and lifecycle timestamps. Every argument-, result-, or
error-derived string is byte-capped in `OpenAgentsWeb.ToolActivity` before it
reaches a template — collapsed titles to one bounded line, expanded payloads
to a hard cap. Provider identifiers (call/item/response IDs) and private
recall content never enter socket assigns or HTML. The executor disclosure
remains available verbatim for every terminal step — in the row's expansion;
availability, not collapsed-row placement, is the contract. PubSub carries an
invalidation signal and LiveView rereads PostgreSQL. Reload reconstructs
activity, and terminal turn state clears the active band while restoring the
composer and cancellation state.

(Amended 2026-08-17, issue #79: previously this invariant kept raw arguments
and results out of the browser entirely. The owner directed that the durable,
scrubbed step values render — bounded — so titles can say what actually ran.)

(Amended 2026-08-18, issue #85: one bounded scrubbed **ephemeral live
projection** may also render — the streamed computer-delegation chunk stream,
re-broadcast by `OpenAgents.ComputerActivity` on the owner conversation's PubSub
topic (`computer_live:<conversation id>`) while `OpenAgents.Computer` collects it.
The chunk text is the controller's already secret-scrubbed output, re-bounded
server-side before broadcast: per event, cumulative (the same 65,536-byte
ceiling the collection enforces), and in event count, with an explicit
truncation marker once capped. PubSub stays projection, never authority:
nothing about the stream is persisted, reload degrades to status-only, and the
durable step outcome remains the record. Computer tokens, argv, env, prompts,
and paths never enter a live event, and the topic is owner-scoped by
construction, so only the owner's conversation ever receives it.)

Evidence: `OpenAgents.Conversations.list_tool_step_activity/1`,
`OpenAgents.Voice.list_tool_step_activity/1`, `OpenAgentsWeb.ToolActivity`,
`OpenAgents.ComputerActivity`, `OpenAgentsWeb.ChatLive`, and tool activity tests in
`OpenAgentsWeb.ChatLiveTest`, `OpenAgentsWeb.ToolActivityTest`,
`OpenAgents.ComputerActivityTest`, and `OpenAgentsWeb.ChatDelegationRailTest`.

### UI-003 — Product surfaces render only through the sanctioned component library

Status: Current

OpenAgents's interface is built from `OpenAgentsWeb.UI` components over Basecoat
primitives vendored at a pinned tag and styled by the OpenAgents pack. Every
web import exposes that one module; product surfaces compose its primitives
with surface-specific layout classes from the sanctioned style pack. No
component accepts provider identifiers or private recall content as an
attribute; tool activity reaches `event_header` only as the bounded projection
UI-002 sanctions, so UI-002 cannot be violated through a primitive.
Basecoat's JavaScript is never loaded and the account menu uses the native
popover API, so the identity control works without custom client-side script.
Where Basecoat has no equivalent, the primitive wraps the browser's own control
rather than reimplementing it: `audio_player/1` is a native `<audio controls>`
in an OpenAgents-styled box, keyboard operable and announced by the user agent,
and it requires an accessible name because a page of recordings is otherwise a
page of identically announced players.
The shared corner radius, the self-hosted Geist faces, exactly two owned themes,
and the reserved semantic color meanings hold across every component. The
system preference selects light or dark through `prefers-color-scheme`; it does
not introduce a third palette. Depth is limited to the sanctioned lift, halo,
and state-ring tokens.
Adopting an additional Basecoat component requires a
`docs/component-library.md` change and an explicit per-component import. The
application exposes one system, light, and dark preference control. A
synchronous, content-free bootstrap applies the stored choice before first
paint and synchronizes changes across tabs. A unique response-scoped CSP nonce
admits only that bootstrap; `script-src` does not allow arbitrary inline code.
Apps SDK UI glyphs are preferred; the pinned Heroicons fallback has an explicit
inventory and no current product call sites.

Evidence: `assets/vendor/basecoat/README.md`, `assets/css/openagents.css`,
`priv/static/fonts`, `OpenAgentsWeb.UI`, `OpenAgentsWeb.ComponentCatalog`,
`OpenAgentsWeb.UITest`, `OpenAgentsWeb.UIGalleryLiveTest`,
`test/openagents_web/component_catalog_test.exs`,
`test/openagents_web/icon_affordances_test.exs`,
`test/openagents_web/live/components_live_test.exs`,
`test/openagents_web/home_controller_test.exs`, and
`assets/test/css_contract_test.mjs`.

### LEADERBOARD-001 — The public board publishes one bounded projection

Status: Current

IDENTITY-002 confines every other server path to the active user's own data.
The leaderboard is the single deliberate exception, and it is an exception to
publication rather than merely to cross-account reads: unauthenticated
visitors and crawlers can read it.

What may be published is exactly the fields of `OpenAgents.Leaderboard.Entry`: a
rank, the GitHub login, the GitHub name, the validated GitHub avatar URL, and
one non-negative integer token total. Nothing else crosses the account
boundary — no conversation, turn, receipt, or voice-session identifier, no
model identifier, no message, transcript, memory, or recall content, no
activity timestamp, no typed/spoken split, and no priced cost. The struct is
the contract: a field added there is published to the internet.

Totals are derived only from the two planes that already hold a merged total,
`turn_receipts.usage` and `voice_sessions.usage`. Provider steps, voice
response receipts, tool-step invocation counts, and off-path shadow-program
runs are excluded, so no account is credited twice and none is credited for
work it did not drive. Accounts appear only while active, not withheld by
`users.public_leaderboard_opted_out`, and above zero tokens; banned accounts
and legacy browser-only visitors never appear. Deleting product data under
DATA-004 removes an account from the board by cascade, without a separate
erasure path.

PostgreSQL stays authoritative. The board is computed once per interval by a
single process and pushed to local subscribers, because a public surface has
unbounded anonymous viewers and a per-socket reread would turn one busy voice
call into a database amplifier. A lost cache costs a recompute, never data.

Evidence: `OpenAgents.Leaderboard`, `OpenAgents.Leaderboard.Entry`,
`OpenAgents.Leaderboard.Server`, `test/openagents/leaderboard_test.exs`, `OpenAgents.LeaderboardTest`,
and `OpenAgentsWeb.LeaderboardLiveTest`.

### OBSERVABILITY-001 — Telemetry is bounded, content-free, and never authoritative

Status: Current

Immutable domain receipts remain the authority; operational telemetry is only a
lossy health projection, and versioned evaluation reports remain separate
release evidence. OpenAgents telemetry accepts only finite plane/status/surface
vocabularies, bounded public identifiers, counts, and durations. Message,
transcript, prompt, instruction, memory, argument, result, payload, person, and
secret values are refused and never become labels, even as hashes.

Release read-back recomputes aggregate plane states and zero-tolerance leakage,
consent, provenance, executor-disclosure, and attribution-reconciliation checks
from authoritative PostgreSQL records without selecting private content. A
metric cannot prove an answer or target-system effect. Nonzero zero-tolerance
checks block release; stuck work is an explicit warning requiring review.

Evidence: `OpenAgents.Observability`, `OpenAgents.Observability.Readback`,
`OpenAgents.Observability.ReleaseGate`, `OpenAgentsWeb.Telemetry`,
`test/openagents/observability_test.exs`, and `OpenAgents.ObservabilityTest`.

### RELEASE-001 — Schema precedes traffic

Status: Current

The production image runs all pending Ecto migrations before starting the HTTP
server. Health is successful only when PostgreSQL answers.

Evidence: Docker `CMD`, `OpenAgents.Release`, the `/status` route, and
`HealthControllerTest`.

### RELEASE-002 — Secrets remain runtime-only

Status: Current

Session, database, provider, and GitHub OAuth credentials enter through ignored
local runtime configuration or Secret Manager and are absent from source, the
Docker build context, and image build arguments. Staging mounts only staging
GitHub secret names through a dedicated runtime identity; production values and
its prepared identity are distinct and remain unmounted until production
cutover. Missing or environment-mismatched GitHub configuration fails startup
without printing any credential value. The GitHub token-encryption key is
runtime-only because the application retains delegated tokens as encrypted
server-side ciphertext. The Cloud Logging default sink excludes only OpenAgents
OAuth callback request entries so the platform cannot persist authorization-code
or state query values; application and audit logging remain enabled.

Evidence: `OpenAgents.GitHubOAuth.RuntimeConfig`,
`OpenAgents.GitHubOAuth.RuntimeConfigTest`, `config/runtime.exs`, `.gitignore`,
`.dockerignore`, the `openagents-oauth-callback-requests` logging exclusion, and
`ops/ci/release-smoke.sh`.

### RELEASE-003 — Every published hostname can establish LiveView

Status: Current

Production accepts the primary `PHX_HOST` plus explicitly configured HTTPS
aliases for Phoenix origin checks. Invalid, insecure, or path-bearing origins
fail startup rather than silently weakening socket validation.

Evidence: `OpenAgentsWeb.AllowedOrigins`, `OpenAgentsWeb.AllowedOriginsTest`, and the
production WebSocket read-back.

### RELEASE-004 — CI runs on owned infrastructure only, and gates every release

Status: Current

The target release gate permits no hosted CI: no GitHub Actions workflows, no
GitHub-hosted or third-party runners, and no repository automation, secrets, or
scheduling handed to external CI compute. All checks run on owned machines.
The full local matrix binds unit, browser, distributed cluster, direct
transaction, release, relup, version-chain, interrupted-install, rolling
replacement, and repository-contract evidence to the exact candidate SHA.
Relup and rolling coordinators refuse a stale or absent receipt before they
change a node. `.githooks/pre-push` invokes the same gate. A bounded, logged
emergency override exists only for operator-directed recovery.

Staging evidence remains a separate later gate. A local receipt does not claim
that the candidate passed staging or authorize a production release.

The absence clause is checked by reading the repository rather than by
running the gate. `ops/ci/gate.sh` and `OpenAgents.Forge.GateReceiptTest`
establish that the owned gate runs and binds its receipt to a candidate SHA;
neither would notice a `.github/workflows/ci.yml` appearing beside them.
`OpenAgents.HostedCIAbsenceTest` reads the paths every hosted provider
configures itself from and fails when one exists.

Evidence: `ops/ci/gate.sh`, `.githooks/pre-push`,
`OpenAgents.Forge.GateReceipt`, `OpenAgents.Forge.GateReceiptTest`,
`ops/relup-proof/run.sh`, `ops/relup-proof/version-chain.sh`,
`ops/relup-proof/kill-during-install.sh`, and
`OpenAgents.HostedCIAbsenceTest`.

### RELEASE-005 — Every code change has a fail-closed deployment class

Status: Current

Direct BEAM candidates use an exact-fleet prepare, canary, apply, verify,
commit, and rollback transaction. An application transition between any two
concrete `X.Y.Z` versions uses a two-way relup, versioned process state,
node-by-node health checks, and reverse installation. Every structural or
unclassified candidate uses digest-addressed rolling replacement with readiness
drain, remaining-capacity and quorum checks, exact rejoin verification, and
last-known-good image recovery. A failed relup or replacement aborts before
another node changes.

A packaged relup describes the two revisions it was built from. The appup is
derived from both builds' compiled modules, so the relup carries an instruction
for every module whose code differs, and packaging refuses when the generated
relup omits one. A node therefore cannot install part of a revision while
reporting itself converged. A version that a node already unpacked from
different artifact bytes is refused rather than reused.

The reverse path restores the `from` release rather than a fixed one. Each
direction's target state schema travels in the appup, so a downgrade migrates
process state to the schema the `from` release compiled — including a pair
whose schemas match, which keeps its schema instead of being forced back to
schema 1. Reverse verification checks release status, node readiness, and that
exact schema before it restores permanence, and a downgrade that is given no
target schema refuses instead of guessing.

All deployment workers remain disabled until isolated staging proves their
complete provider and topology. Current means that the local mechanism and its
refusal and recovery paths exist; it does not authorize staging or production.
`OpenAgents.Forge.RelupDeployment.run/2` has no production caller, and the
release gate runs neither `ops/forge/package-relup.sh` nor
`ops/relup-proof/install-proof.sh`.

Evidence: `OpenAgents.Forge.Deployment`, `OpenAgents.Forge.RelupDeployment`,
`OpenAgents.Forge.RelupNode`, `OpenAgents.ReleaseState`,
`OpenAgents.Release.Appup`, `OpenAgents.Forge.RollingReplacement`,
`test/openagents/forge/relup_deployment_test.exs`,
`test/openagents/forge/relup_node_test.exs`,
`test/openagents/release/appup_test.exs`,
`test/openagents/cluster/code_change_test.exs`,
`test/openagents/forge/rolling_replacement_test.exs`, and
`docs/operations/release-deployment-fallbacks.md`.

### RELEASE-006 — A rolling replacement admits only authority-bound image identities

Status: Current

Before the first node is replaced, the rolling coordinator publishes the
authorized rolling identity — the exact source SHA, the exact image digest, the
previous pair, and the exact expected node set — onto the newest
`needs_rolling_replace` Forge target. That published record is the only thing
that widens what a booting node may run.

While a roll is active a node may serve only when its booted image is exactly
the live target's image identity or exactly the published rolling identity. A
node matching neither is admitted by nothing durable: it stays out of readiness
and out of the load balancer unless it can converge on the live target's
artifact. Matching the SHA alone is not enough, and neither is matching a
digest that no target authorized.

Publishing the same identity again resumes an interrupted roll and preserves
every recorded observation. A different identity is accepted only while no node
has yet been observed under the published one, so an in-flight roll can never
be redirected under running nodes. As each node rejoins, its exact observed SHA
and image digest is recorded against that authority; a node the coordinator
rolled back records the previous identity instead.

Settlement to `live` is bound to the same authority. It requires the published
record, a result carrying the authorized SHA, image digest, previous pair, and
exact expected node set, and an exact-identity observation from every expected
node. A roll that ended with any node on another identity refuses with
`rolling_nodes_not_converged` and leaves the target `needs_rolling_replace`,
which is recoverable by rerunning the roll and auditable from the target row.
Settlement clears no evidence: the authority and its observations remain on the
settled row.

No part of this path is an operator flag change or a manual restart of
`OpenAgents.Forge.BootConverge`. A node that boots into the authorized image
enters readiness on its first convergence attempt, and the worker's own
periodic attempt follows the target to `live` after settlement.

Evidence: `OpenAgents.Forge.RollingReplacement`, `OpenAgents.Forge.Targets`,
`OpenAgents.Forge.BootConverge`,
`test/openagents/forge/rolling_boot_convergence_test.exs`,
`test/openagents/forge/rolling_replacement_test.exs`,
`test/openagents/forge/target_lifecycle_test.exs`,
`test/openagents/forge/boot_converge_test.exs`, and
`docs/operations/production-deploy-runbook.md`.

### RELEASE-007 — The release image keys toolchain layers on pinned inputs only

Status: Current

A container layer's cache key includes every `ARG` and `ENV` declared above it
in the same stage, whether or not the instruction reads them. A value that
moves with the source — the candidate SHA, its commit timestamp, the release
version — therefore rebuilds everything below it. Declaring
`OPENAGENTS_BUILD_REVISION` at the top of a stage reinstalls the operating
system, Node.js, Codex, and OpenCode for every candidate, so two adjacent
revisions share nothing.

Every per-candidate value is declared as late as the build allows. In the
builder stage the Debian snapshot, the pinned Node.js toolchain, Hex, rebar3,
`mix deps.get`, `mix deps.compile`, the npm install, and the Tailwind and
esbuild install sit above `OPENAGENTS_BUILD_REVISION` and `SOURCE_DATE_EPOCH`,
which enter immediately above the first application source layer.
`OPENAGENTS_RELEASE_VSN` enters immediately above the `COPY VERSION` that
already keys those layers. In the runtime stage the Debian snapshot, the pinned
Geist faces, the pinned Codex package, the pinned OpenCode binary, and the
generated locale sit above `SOURCE_DATE_EPOCH`. Those layers key on their own
checksum-pinned inputs, so two adjacent source revisions reuse all of them.

Lateness never costs identity. `OpenAgents.BuildInfo` reads
`OPENAGENTS_BUILD_REVISION` at compile time, so the revision is still declared
before `mix compile` and the packaged release still carries the exact candidate
SHA. `SOURCE_DATE_EPOCH` still reaches the runtime image as an `ENV`. Both
publishing paths refuse an image whose embedded revision or whose
`org.opencontainers.image.revision` label is not that exact SHA, and the
release gate runs the ordering proof in its `contracts` stage.

Evidence: `OpenAgents.BuildInfo`, `ops/deploy/build-image.sh`,
`ops/staging/publish-candidate.sh`, `ops/ci/contracts.sh`, and
`test/openagents/release/image_layer_cache_test.exs`.

### RELEASE-008 — A relup refuses a topology OTP cannot inspect, before it installs

Status: Current

`:release_handler.install_release/1` first builds the set of processes it will
suspend, code-change, and resume. For every running application it asks
`:supervisor.get_callback_module/1` for the application's top supervisor, and
that function reads the process state as a `supervisor` record. An application
whose top process is an Elixir `DynamicSupervisor`, a Horde supervisor, or a
bare `GenServer` returned from `Application.start/2` raises `badrecord` there.
`release_handler` reports `cannot find top supervisor` and drops that supervisor
from the set it upgrades, so the application's own top process is never
suspended and never code-changed while the release installs around it.
`:release_handler.check_install_release/1` never performs this walk, so it
cannot refuse the transition.

`OpenAgents.Forge.RelupTopology` performs the same walk first.
`OpenAgents.Forge.RelupNode.check_topology/2` is the coordinator's first fleet
step, ahead of staging, unpacking, and `check_install`, so a refusal transfers
no artifact and reaches no point of no return. The node keeps its previous
permanent release, and because the current release never changed the coordinator
attempts no reverse installation. The refusal is bounded and explicit: it names
each incompatible application and its registered supervisor, and the deployment
receipt records that exact reason against the exact candidate identity, for
example `check_topology:incompatible_topology:libring:HashRing.Supervisor`.

A refusal is a classification, not a fault to route around. It means OTP release
handling cannot express this fleet's topology, so the candidate belongs on the
digest-addressed rolling replacement lane, which does not depend on release
handling and remains eligible for the same bytes. The release gate proves the
refusal in its `relup_topology` stage against the running `libring` application,
whose `HashRing.App.start/2` returns a `DynamicSupervisor` registered as
`HashRing.Supervisor`. Widening the preflight to admit such an application is
not a fix; starting an OTP `supervisor` as that application's top process is.

Evidence: `OpenAgents.Forge.RelupTopology`, `OpenAgents.Forge.RelupNode`,
`OpenAgents.Forge.RelupDeployment`,
`test/openagents/forge/relup_topology_test.exs`,
`test/openagents/forge/relup_deployment_test.exs`, `ops/ci/gate.sh`, and
`docs/operations/release-deployment-fallbacks.md`.

### RELEASE-009 — A candidate's lane is chosen from the fleet's topology verdict

Status: Current

A deployment lane is a decision taken in front, not the residue of a failure.
Before any node is touched, `OpenAgents.Forge.DeploymentLane.classify/2` folds
three inputs into one lane: the build manifest's structural classification, the
hot-load allowlist, and the fleet's own relup topology verdict read from every
member by `fleet_topology/1`. The chosen lane, the reasons that chose it, and
the verdict it was chosen against travel together, and the rolling target
carries all three.

The verdict is a property of the running fleet, not of the candidate bytes, so
it is a runtime read rather than a gate artifact. The release gate runs on a
builder that is not the fleet, and a fleet node can restart into a different
application set between the gate and the deployment, so the only reading true
at the moment of choosing is the one taken then. The gate keeps proving the
RELEASE-008 refusal in its `relup_topology` stage.

The read fails closed in every direction. A member that cannot be reached, that
raises, or that answers with anything but a report counts as unreadable; an
empty member list is unread rather than unanimous; and an absent verdict is
treated as unsupported. Only a fleet where every member answered and no member
named an application OTP release handling cannot inspect supports relup.

A fleet that cannot support relup therefore never enters the relup lane. The
candidate is classified onto digest-addressed rolling replacement with the
verdict recorded as its reason — `topology_incompatible:libring:HashRing.Supervisor`
for the concrete case RELEASE-008 describes — instead of entering the lane and
refusing on its first preinstall step. That refusal is unchanged and remains
the backstop: this invariant decides, and RELEASE-008 still guards.

The relup lane also requires its caller to admit it, which
`OpenAgents.Forge.HotLoader` does not. RELEASE-005 keeps the relup workers
disabled until isolated staging proves their provider and topology, and
`OpenAgents.Forge.RelupDeployment.run/2` still has no production caller, so the
coordinator sees only the direct and rolling lanes and a relup-shaped candidate
records `relup_lane_unadmitted`. Neither condition is an operator flag: the
verdict comes from the fleet and the admission is a named argument.

The verdict is content-free. It carries a count of fleet members and a count of
unreadable ones, never their names, alongside the bounded
application-to-supervisor entries `OpenAgents.Forge.RelupTopology` already
produces.

Evidence: `OpenAgents.Forge.DeploymentLane`, `OpenAgents.Forge.HotLoader`,
`OpenAgents.Forge.RelupTopology`,
`test/openagents/forge/deployment_lane_test.exs`,
`test/openagents/forge/hot_loader_test.exs`, and
`docs/operations/production-deploy-runbook.md`.

### STATUS-001 — The status page publishes one bounded, content-free projection

Status: Current

The public `/status` page and `/api/status` publish exactly one projection
(`OpenAgents.NetworkStatus`, schema-versioned): cluster membership and quorum,
Raft membership, per-node release/hot-load versions, uptimes, and counts.
Counts only, never content — no computer names, job goals or ids,
conversation data, provider identifiers, or internal node names/addresses
(nodes render as stable positional labels). It shares the leaderboard's
UI-001 posture (read-only, cannot mount or invoke OpenAgents) and renders through
the sanctioned component library (UI-003).

The page must render DURING incidents: nothing in the projection may require
quorum, the database, or a full fleet — every gathered field degrades
independently (an unreachable node reports as unreachable; a failed count is
absent), and the per-node fan-out is time-bounded and briefly cached so page
traffic cannot become an rpc storm. Legacy JSON pollers of `/status` keep the
old health payload via content negotiation until they migrate to `/health`
or `/api/status`.

Evidence: `OpenAgents.NetworkStatus`, `OpenAgentsWeb.NetworkStatusLive`,
`OpenAgentsWeb.Plugs.StatusProbeCompat`, `OpenAgents.NetworkStatusTest`, and
`OpenAgentsWeb.NetworkStatusLiveTest`.

### TRANSPARENCY-001 — Public transparency surfaces publish per-repo leveled projections

Status: Current

The public transparency surfaces — `/changelog`, `/api/changelog`, and the
forge web UI (`/<owner>/<repo>`, `/<owner>/<repo>/commit/:sha`,
`/<owner>/<repo>/blob/:ref/*path` — addressed exactly like the GitHub URLs
they replace, with the owning account as a **literal** route scope rather
than a wildcard first segment, so no other path on the domain is shadowed)
— publish bounded projections of the forge
receipt chain and repository content at an explicit per-repo disclosure
level (`OpenAgents.Forge.Visibility`: `:l0` dark → `:l1` pulse → `:l2` ledger →
`:l3` glass). The level map is operator-owned configuration
(`:forge_public_visibility`), never derived from request data; a repo
without a configured level is `:l0` and its surfaces 404, indistinguishable
from a repo that does not exist. Ledger surfaces (`:l2`) may publish shas,
summaries, changed-file paths, module and node counts, timings, deploy
results, WAL sequence numbers, and principal *roles*; browsable source and
diff bodies require `:l3`.

**A private repository publishes documents, not history.** `openagents` is
private and runs at `:l2`. Below `:l3`, the blob view serves only paths on
the operator-owned published allowlist (`:forge_public_paths`), and only at
the current default-branch head: an allowlisted path at an arbitrary ref is
a 404, because publishing one document must never become a window into
every past revision of that file, or into the repository's history. Adding
a path to that allowlist is a deliberate publication decision, and
operator documentation (runtime configuration, deployment mechanics,
operator identifiers) stays off it — `docs/2026-08-20-integration-hardening-and-staging-readiness-recommendations.md` is never
published.

Bounds that hold at every level: no secrets or credentials beyond what the
repository content itself carries (RELEASE-002 keeps secrets out of the
repo), no cross-user conversation or memory content, no operator identity
(role prefixes only — `OpenAgents.Changelog` and the commit view publish the
principal's kind, never its id), no internal node names, and every git read
and receipt scan is size- and count-bounded with honest truncation markers
(`OpenAgents.Forge.Browse` caps blobs, diffs, messages, and listings). An entry
whose `visibility` is `l1` renders without its sha or links until its
`disclosure_after` passes — the security-embargo lane — and is shown, never
silently omitted.

Projections are derived, append-only, and never authority: `changelog_entries`
rows join to receipts but the pushed commit, the WAL, and the receipt rows
remain the only truth about what shipped (A7); deleting or down-leveling a
public entry never alters them. The pages share the leaderboard's UI-001
posture (read-only, mount without a session, cannot mount or invoke OpenAgents),
render only through the sanctioned component library (UI-003), and the
timeline is briefly cached so anonymous traffic can never become a query
storm (LEADERBOARD-001's amplifier rule). STATUS-001 is unchanged: `/status`
stays content-free; content publication happens only on these surfaces and
only per the repo's configured level.

Evidence: `OpenAgents.Forge.Visibility`, `OpenAgents.Forge.Browse`, `OpenAgents.Changelog`,
`OpenAgents.Changelog.Entry`, `OpenAgentsWeb.ChangelogLive`, `OpenAgentsWeb.CodeRepoLive`,
`OpenAgentsWeb.CodeCommitLive`, `OpenAgentsWeb.CodeBlobLive`,
`OpenAgentsWeb.ChangelogController`, and their tests.

### REPOSITORY-001 — GitHub identity names repositories; OpenAgents owns stored snapshots

Status: Current

Every hosted namespace retains one immutable GitHub user or organization ID.
GitHub slugs are projections and old slugs remain aliases after a rename.
Reserved product-route segments cannot become namespaces. A database repository
row resolves every browser, API, and Git request to one opaque storage key; the
initial `OpenAgentsInc/openagents.com` repository keeps the historical
`openagents.com` key so existing WAL and object storage remain authoritative.

Repository creation atomically records the repository, owner membership,
idempotency receipt, and durable provisioning work. A GitHub import freezes an
authorized branch-and-tag ref map, stores no GitHub credential, persists the
accepted objects through the forge WAL, and schedules no later synchronization.
OpenAgents becomes the source of truth for the imported snapshot. Public ready
repositories permit anonymous Git reads. Private reads and every write require
an admitted repository principal, and read-only members cannot push.

Amended 2026-08-21 (workspace-wide issue and project lists): who may read a
repository is one composable predicate, `OpenAgents.Repositories.readable_by/2`
— public and `ready`, or a membership in a reading role — and the surfaces
that answer "which repositories may this reader see" compose it rather than
restating the join. That is `OpenAgents.Repositories`, `OpenAgents.Issues`,
`OpenAgents.Projects`, and `OpenAgents.Notifications`.

Amended 2026-08-23 (issue #166): the sentence above used to say *every*
surface that lists or resolves a repository, which is more than its proof
covers and more than is true. Roughly thirty modules join the repositories
table, and most reach a row by an identifier a caller already passed
authorization for — a milestone's repository, a stack entry's repository, a
pull request's repository. Those are not visibility decisions and do not
compose the predicate. Nothing enumerates which joins are which, so a module
that does make a visibility decision with its own restated join would not fail
any proof here.

Amended 2026-08-23 (issue #175): the two kinds are now separated by the code
rather than by a reader, and the separation is enumerated by
`OpenAgents.Repositories.VisibilityJoinTest`.

A **visibility decision** starts from something the caller supplied — an
`owner` and a `name`, or a listing with no prior authorization — and ends with
a row. An **ownership reach** starts from a row the caller was already
authorized for and follows `repository_id`; it decides nothing and owes
nothing. Every visibility decision either composes `readable_by/2` or is one of
five sites that states the rule itself for a principal the predicate does not
model, each named below.

- **Path resolution is five exports and no more.**
  `OpenAgents.Repositories.get_visible_by_path!/3` and `visible_by_path/3`
  apply the caller's own predicate; `get_public_by_path!/2` applies it with an
  anonymous reader; `get_writable_by_path!/3` applies the write predicate; and
  `get_by_path!/2` applies none. The exports matching `*_by_path*` are an exact
  set, so a sixth way to turn a caller-supplied path into a row is classified
  before anything can call it. The callers of the two that do not apply the
  caller's predicate are exact sets too:
  `OpenAgentsWeb.DeploymentController` for the unfiltered resolver, whose
  `:workflow`, `:operator`, and `:system` principals are not users and are
  gated by `OpenAgents.Deployments.Authority`; and `OpenAgents.Issues`,
  `OpenAgents.Projects`, `OpenAgentsWeb.CommentController`,
  `OpenAgentsWeb.IssueController`, and `OpenAgentsWeb.OgImageController` for
  the anonymous one.
- **Listing composes the predicate.** The modules that compose `readable_by/2`
  are `OpenAgents.Repositories`, `OpenAgents.Issues`, `OpenAgents.Projects`,
  `OpenAgents.Notifications`, and `OpenAgents.DataRights.AccountExport` — five,
  not the four the amendment above named.
- **The predicate's terms live in one file, plus four stated exceptions.**
  Every site in `lib/` naming a repository's `visibility` or `lifecycle_state`
  against `"public"` or `"ready"` is classified, and the four that decide reach
  outside `OpenAgents.Repositories` are `OpenAgents.Forge.GitHTTP` (Git
  transport admits `:operator`, `:machine`, and `:assignment` principals the
  predicate does not model), `OpenAgents.Deployments.Authority` (the
  deployment plane's non-user principals), `OpenAgents.Reputation` (the
  attestation transparency tier, which is disclosure rather than row reach),
  and `OpenAgentsWeb.RepositoryAccess` (a narrower file-level allowlist
  layered above row admission it takes from `get_visible_by_path!/3`).

Three restatements were removed rather than declared, and two were wrong.
`OpenAgents.Issues.get_issue_by_path!/3` and
`OpenAgents.Projects.get_project_by_path!/3` each carried a copy of the public
half that omitted `lifecycle_state`, so an issue or project in a repository
that had not finished provisioning resolved there and nowhere else.
`OpenAgents.SCV.Deployments` carried a structural clone that admitted any
membership row rather than one in a reading role, and resolved the path without
the namespace-alias join a rename leaves behind. All three compose the
predicate now.

The role filter inside `readable_by/2` is a guard for a role that does not
exist yet: every role `repository_memberships_role_check` admits is a reading
role, so removing the filter reddens nothing. The vocabulary is pinned against
that constraint instead, and a fifth role fails until someone says whether it
reads.

What is still not enumerated: a listing that applies no predicate at all names
no term and calls no resolver, so it passes every test above.
`OpenAgents.DataRights.AccountExport`'s push-receipt and deployment joins are
that shape — each is scoped to the acting account's own rows, and each selects
a repository's `owner` and `name` without the predicate, which the same
module's `repository_work_export/1` explicitly applies.
`docs/2026-08-23-invariant-proof-audit.md` records the residue.

Reading across repositories obeys the same rule as reading one: the
workspace-wide lists at `/issues` and `/projects` join their tables to that
predicate, so no filter, search term, or page number they accept can surface a
row from a repository the reader could not open directly. The duplicate that
`list_visible_repositories/1` held had already lost the `ready` half and
disagreed with the paged read about the same repository; there is one copy now.

Amended 2026-08-22 (explicit issue and project repository scope): production
contexts accept a repository or a resource that already carries its repository
identity. No context function selects a default repository or grants membership
as a side effect. The Projects V2 API uses
`/api/v3/repos/:owner/:repo/projectsV2`; every project, item, and field query
includes that repository. Optional bearer authentication lets a member read a
private repository's issues and projects, while anonymous readers and
nonmembers receive `404 Not Found`. Every write still requires `forge:write`
and a writable membership in the same repository.

Evidence: `OpenAgents.Repositories`, `OpenAgents.Repositories.Provisioner`,
`OpenAgents.Repositories.Importer`, `OpenAgents.Forge.GitHTTP`,
`test/openagents/repository_lifecycle_test.exs`,
`test/openagents/repositories/provisioner_test.exs`,
`test/openagents_web/controllers/repository_controller_test.exs`,
`test/openagents_web/controllers/issue_controller_test.exs`,
`test/openagents_web/controllers/project_controller_test.exs`,
`test/openagents/issues_workspace_test.exs`,
`test/openagents_web/live/issue_workspace_live_test.exs`,
`test/openagents_web/live/project_workspace_live_test.exs`,
`test/openagents/repositories/visibility_join_test.exs`, and
`test/openagents/forge/git_http_test.exs`.

### API-001 — Every OpenAgents extension field is published before it is served

Status: Current

The GitHub-shaped API under `/api/v3` grows OpenAgents-specific fields in one
namespaced object per resource. GitHub-shaped keys keep their exact shape, so a
GitHub client sees an additional `openagents` object and nothing else, and
every OpenAgents field lives inside it.

Discovery is mechanical, not tribal. `GET /api/v3` enumerates each extension
field with its type, its enum values, its owning version, and the endpoints it
belongs to. A response carrying an extension names the namespace in the
`x-openagents-extensions` header. A filter the root document lists is refused
by the endpoint that names it when the value falls outside the published enum,
with a stable field-level `422`.

These are enforced, not merely followed. The governance test reads the root
document and the live responses and fails on any disagreement: a field served
inside `openagents` that the root document does not enumerate, a documented
field no response carries, a documented filter an endpoint accepts any value
for, or a published enum that has drifted from the value the context derives.
A governance rule nothing enforces would be a contract with no proof.

Derived fields state their sources, including whose visibility.
`issue.openagents.progress` is derived from the reader's own readable boards
through `OpenAgents.Repositories.readable_by/2`, the one predicate every
repository surface composes, so a column on a board in a private repository the
reader cannot open never becomes a fact about a public issue. The filter and
the field read the same query, so a listed issue always reports the value it
was listed under.

Evidence: `OpenAgentsWeb.ApiExtensionController`, `OpenAgentsWeb.IssueJSON`,
`OpenAgents.Issues`,
`test/openagents_web/controllers/api_extension_governance_test.exs`,
`test/openagents_web/controllers/api_extension_controller_test.exs`,
`test/openagents_web/controllers/issue_controller_test.exs`, and
`test/openagents/issue_progress_test.exs`.

### CONTRIBUTION-001 — The agent front door is derived from the application

Status: Current

Every deployment publishes one participation contract in two representations:
`/agents.md` for a reader and `/agents.json` for a client. Both are rendered
from `OpenAgentsWeb.ContributionContract`, so they carry the same contract
identifier, version, revision, and digest and cannot drift apart by editing
one of them. `GET /api/v3` points at both and republishes that digest, so an
agent that starts at the API description finds the contract without guessing a
path, and an agent receipt can record which instructions it followed.

A consumer detects a breaking change from the identifier. The major version is
part of `contract`, matching the other published contracts here: while it reads
`openagents.contribution.v1` every difference is additive, and a breaking
change publishes a new identifier. `digest` is the SHA-256 of the document with
its own digest removed and object keys sorted, so a changed digest under an
unchanged identifier means the wording or a derived value moved.

The document is derived rather than written beside the application. Each
published request carries the classification of the authority that owns its
surface, and only that one: `/api/v3` requests carry the principal, family, and
error contract from `OpenAgentsWeb.ApiRouteAuthority`, which is proven against
what the enforcing pipeline does to an anonymous request, and every other
request carries the class, principal, and scope from
`OpenAgentsWeb.RouteAuthority`. Publishing both for one route would let the
document contradict itself. Credential scopes come from
`OpenAgents.ApiTokens.allowed_scopes/0`, and the base URL is the origin the
request arrived on, so a staging deployment describes staging.

The contract advertises nothing that does not exist. It names the capabilities
an agent would reasonably try and that no route serves, and the proof fails the
moment one of those routes starts resolving, so implementing a listed absence
forces the list to be corrected. It never directs a push to GitHub: the remote
it publishes is admitted by `ops/ci/push-remote-check.sh` and every target it
names as refused is refused by that same guard.

It carries no instance data. The bytes are identical for an anonymous and an
authenticated reader, and private repositories and issues appear in neither
representation; private data is reached only by an authenticated call to a
route the contract names.

Evidence: `lib/openagents_web/contribution_contract.ex`,
`lib/openagents_web/controllers/agent_front_door_controller.ex`,
`lib/openagents_web/controllers/api_extension_controller.ex`, and
`test/openagents_web/contribution_contract_test.exs`.

### REPOSITORY-002 — Development pushes go to the forge, never to the mirror

Status: Current

This repository's own commits reach the forge first. The forge records each
push in the durable WAL and serves what the WAL holds, so GitHub is a
projection of the forge in the same sense that a slug is a projection of a
GitHub ID. A push sent straight to GitHub inverts that: the WAL never sees the
objects, and nothing reports the divergence until a clone disagrees with the
site.

The mirror that would keep GitHub current is not running. `mirror_url/1` reads
`:forge_mirror_urls`, which is empty in `config/config.exs` and set by no
environment, so `MirrorWatch` reports `off` and GitHub receives only what
someone pushes to it. `mirror_now/1` is a `git push --mirror`, a force push of
every ref, so configuring a mirror overwrites whatever direct pushes left on
GitHub rather than merging with it. Configuring that mirror is what makes this
contract complete; until then it keeps the forge authoritative and lets GitHub
go stale, which is the honest trade and not an accident.

`ops/ci/push-remote-check.sh` admits only forge hosts and refuses every other
remote, whatever URL form it takes. `.githooks/pre-push` runs it before the
release gate, since where a push is going costs nothing to check and the gate
costs minutes. A bounded, logged override exists for operator-directed
recovery, such as mirroring by hand while the forge is unreachable.

The check is a guard, not a deployment: it refuses a wrong destination and
makes no claim about the candidate. `ops/dev/install-push-guard.sh` installs
it at Git's default hook path, so a clone refuses the wrong destination
without also owing a release-gate receipt for every push; a machine that sets
`core.hooksPath` runs the guard and the gate together instead. `mix precommit` runs the installer in `--ensure`
mode, so a clone becomes guarded on the way to its first push without anyone
having read this entry; `--ensure` never fails the build, because a machine
that has chosen `core.hooksPath` or that keeps its own pre-push hook has made
a decision the installer will not overrule. A clone that never runs precommit
is still unguarded, which is why `AGENTS.md` states the rule as well.

Evidence: `ops/ci/push-remote-check.sh`, `ops/dev/install-push-guard.sh`,
`.githooks/pre-push`,
`OpenAgents.Forge.Pushes`, `OpenAgents.Forge.MirrorWatch`, and
`test/openagents/push_remote_contract_test.exs`.

### REPOSITORY-003 — Every accepted push replays onto an empty cache

Status: Current

The WAL is the durable push authority and each node's bare repository is a
disposable projection of it, so an entry that cannot re-materialize is lost
data, not a slow start. A node that loses its cache must be able to rebuild the
repository from seq 0 alone.

Replay applies one entry at a time and moves the refs to the post-state that
entry recorded before the next entry runs. It has to. `git bundle unbundle`
writes objects and no refs, a `ref_update` entry carries no payload at all, and
`git receive-pack` re-runs push *admission* policy — expected-old-OID locks and
shallow-boundary checks — that was already decided when the push was accepted.
Replayed against the wrong ref state git refuses the request, a refusal
discards the entry's whole object quarantine, and `receive-pack` exits 0 while
doing it. Converging after every entry replays each request against exactly the
ref state its client saw, which is the state the WAL recorded.

An entry's exit status is therefore not evidence of anything. Each entry proves
its outcome instead: every object ID it introduces must exist before its refs
move. An entry that cannot prove it does not advance the applied sequence. The
node then rebuilds from seq 0, and a rebuild that also cannot prove it fails
closed with a `503` rather than serving a repository missing commits.

A bundle entry states the shallow graft only when it records a `shallow` key.
An import records one, including an explicit empty list for a complete clone; a
`GitPlane.batch_update_refs/3` batch records none, and that silence leaves the
graft alone. Reading silence as "no boundaries" ungrafts a shallow repository
mid-replay, after which git walks past the boundary into parent commits the WAL
never held and every later entry fails on them.

No entry format changed to make this hold, so entries written before it replay
under it unchanged: the contract is about how replay reads the log, not about
what pushes write. `receive.shallowUpdate` stays off, so an accepted push
cannot move the graft either, and the boundary an import records remains the
only one.

Evidence: `OpenAgents.Forge.Sync`, `OpenAgents.Forge.Repos`,
`OpenAgents.Forge.CacheReadiness`, `test/openagents/forge/wal_replay_test.exs`,
and `test/openagents/forge/sync_test.exs`.

### EXIT-001 — The export ledger matches the surface in both directions

Status: Current

One operator runs this forge, so "you can leave with your work" is a claim a
user cannot check by inspection. `OpenAgents.DataRights.ExportInventory` turns
it into a ledger with four statuses — `portable`, `partial`, `blocked`, and
`not_user_data` — and the ledger is enforced against the surface rather than
maintained beside it.

Coverage is derived, not curated. Every resource family
`OpenAgentsWeb.ApiRouteAuthority.families/0` publishes must appear, in both
directions, so a family reaching `/api/v3` without someone deciding whether a
user can export it fails the build, and a family the API drops leaves no stale
claim behind. Families that leave through routes outside `/api/v3` — Git
transport for repository content, the `DATA-004` exports for conversations and
memory, and `GET /data/export/account` for the forge-owned and forum-owned
records an account authors — are listed alongside them.

The ledger is deliberately pessimistic, because an unproven portability claim
is the kind of claim this repository does not make. `portable` requires a named
mechanism and a named proof, and owes no issue. `partial` means the records are
reachable and nothing here shows an account getting its own records back; it
owes an open issue. `blocked` means the account cannot read its own records at
all, and it is probed rather than asserted, so a fix that lands without
updating the ledger turns the proof red. `not_user_data` claims nothing and
states why.

The probes run against a private repository the account owns, and they check
both directions: a read that stopped returning the owner's records fails, and a
read that started working fails until the ledger says so. The `comment`,
`label`, `milestone`, `assignee`, `issue_label`, and `issue_assignee` families
were blocked until they resolved the repository through the same visibility
predicate every other repository surface composes; they are portable now, and
this ledger records the change rather than trailing it.

`GET /data/export/account` is the account-scoped export, and the probes round
trip it rather than reading its source: one `forum` post and topic, one
`thread` with a transcript entry, one `push_receipt`, one `box` lease and run,
one `computer`, one `agent` link, one `deployment` request, one
`pull_request`, one `stack` with its entry, and one `issue_dependency` are
seeded and read back through the route in an authenticated session. A family
whose record stops coming back turns this red, and so does a receipt returned
under a principal that is not the requesting account. `push_receipt` is probed
there rather than against the route inventory: what the account gets back is
its own `forge_pushes` rows, matched exactly on the `user:<account-id>`
principal a person's push records. A repository-scoped read is published beside
it — `GET /api/v3/repos/{owner}/{repo}/pushes` (#167), which serves the WAL's
own entries and the `EXIT-005` chain link `git push` printed to the pusher —
and it is proven by its own test rather than by this probe, because the
question here is what an *account* gets back.

`pull_request`, `stack`, and `issue_dependency` key on a repository rather than
on an account, so the export's `repository_work` section is the one read on
this surface that crosses repositories, and authorization rather than
enumeration is what it has to get right. Each query filters on the column
naming the authoring account *and* joins
`OpenAgents.Repositories.readable_by/2`, the predicate every per-repository
read composes, rather than restating a second rule. Both halves are proven
separately in `test/openagents/data_rights/account_export_test.exs`: a record
whose authoring column names the account, in a private repository the account
is not a member of, is withheld, and another account's records in a repository
this account can read never appear. Dropping the `readable_by` join turns the
first red while every other assertion still passes.

Ownership of a migrated forum post is decided, not guessed. Two identities
resolve to an account and no third: `user:<account-id>`, which every topic and
post written on this surface carries, and any `actor_ref` the account holds a
`linked` claim on in `forum_actor_links`. A post under an unclaimed, pending,
or rejected legacy identity is not exported, because nothing has established it
is that account's writing, and `forum_actor_links`' unique index on `actor_ref`
means two accounts cannot both resolve one legacy identity. The claims
themselves travel in the document at every status, so an account can see what
it asked for and what the operator decided.

No family is `blocked` today, which is a result rather than a default: #142
opened the private-repository metadata reads, #143 exported the forge-owned and
forum-owned families, and #165 added the cross-repository read. One family
stays `partial`, and it is not an enumeration problem. A `reputation`
attestation names a `subject_id` the issuer supplies and an `issuer_key_id`
that is the operator's; no column, and no table on this surface, resolves
either to an account, and no route creates an attestation. There is no filter
that would find an account's own attestations, so the ledger records the gap
and issue #171 carries the subject binding. The export names that omission in
its own `not_included` section rather than leaving a recipient to infer it.

Evidence: `OpenAgents.DataRights.ExportInventory`,
`OpenAgents.DataRights.AccountExport`, `OpenAgentsWeb.ApiRouteAuthority`,
`test/openagents/data_rights/export_inventory_test.exs`,
`test/openagents/data_rights/account_export_test.exs`, and
`docs/forge-operator-independence.md`.

### EXIT-002 — Served state is checkable against the WAL with no database

Status: Current

`OpenAgents.Forge.Pushes` acknowledges a push only after the WAL accepts it, so
the WAL is the record of what was pushed and each node's bare repository is a
projection of that record. Whether the projection still matches is therefore a
question with an answer, and `OpenAgents.Forge.Verification` computes it from
the WAL and the repository alone.

Independence here is structural, not a promise: a verifier that queried
PostgreSQL would be asking the operator to confirm the operator. The proof reads
the module's compiled import table and fails on a call into `OpenAgents.Repo`,
Ecto, or Postgrex, so the property cannot decay through an added convenience.

Five disagreements are distinct findings, and each is exercised by breaking it.
An entry the store cannot produce is `entry_object_missing`. An entry whose
bytes no longer hash to the key the index recorded is `entry_digest_mismatch`,
because WAL entry keys are content-addressed. Entries that are not the
contiguous run from zero are `entry_sequence_broken`, which is how a removed or
renumbered entry surfaces. A ref the repository serves that the WAL never
recorded, or records differently, is `served_refs_diverged` — checked in both
directions, so a smuggled ref is caught as well as a moved one. An object the
WAL says a push introduced that the repository cannot produce is
`object_missing`.

What this does not do is stated as plainly as what it does. Entries are not
signed and no commitment to the log is published outside the operator's own
storage, so an operator who rewrites an entry, its key, the index, and every
chain link after it produces a self-consistent log and this reports it clean.
Content addressing and `EXIT-005`'s chain make tampering evident, not
impossible. What the chain adds is that a rewrite can no longer be local, which
is what makes one externally held link enough to check a whole prefix —
`verify/2`'s `:anchor` option is that check. `EXIT-005` returns that link to
the pusher at acknowledgment, so the party who pushed can hold one; nothing is
published to a stranger yet. `docs/2026-08-23-forge-wal-anchoring.md` stages
the publication, and #151 carries it.

`REPOSITORY-003` proves that an accepted entry re-materializes onto an empty
cache. This proves that divergence between the WAL and what is served is
detectable. The first is about replay; the second is about detection, and
neither substitutes for the other.

Evidence: `OpenAgents.Forge.Verification`, `OpenAgents.Forge.WAL`,
`OpenAgents.Forge.Repos`, and `test/openagents/forge/independence_test.exs`.

### EXIT-003 — Recovery comes from the WAL, and the mirror is strictly lossy

Status: Current

GitHub is a mirror and never authority. That direction is load-bearing, and it
holds only while nothing on the recovery path can consult the mirror. The proof
reads the compiled import tables of `OpenAgents.Forge.Sync` and
`OpenAgents.Forge.Repos` and fails on a call into
`OpenAgents.Forge.MirrorWatch` or into the mirror functions of
`OpenAgents.Forge.Pushes`, so a lost forge cannot quietly promote GitHub to
source of truth through a fallback someone added in an incident.

What survives a lost forge splits cleanly. From the WAL: every ref, every
object, and the push record — `OpenAgents.Forge.Pushes.reconcile_receipts/1`
re-derives every `forge_pushes` row after the table is emptied, at the WAL's
own sequence numbers and principals, because receipts are derived from the WAL
and never a second authority. From the mirror: every commit, tree, blob, tag,
and advertised ref, and nothing else. `mirror_now/1` is a `git push --mirror`,
which carries a ref map and a pack. No sequence, no principal, and no push time
travels with it, so a forge restored from its mirror serves the same source
with no evidence of who produced it. The proof asserts both halves by losing
the WAL and the receipts and then checking what the mirror can and cannot
give back.

A receipt also carries the `EXIT-005` chain link of the entry it derives from,
and the direction holds there too: the link is copied from the entry, and
`reconcile_receipts/1` re-derives it from the entries after the table is
emptied, so PostgreSQL never becomes a second opinion about the chain. The
proof rewrites every stored link to a value the log never produced and asserts
that verification is unmoved, because `OpenAgents.Forge.Verification`
recomputes the chain from the WAL and reaches no database at all. What the
column buys is small and stated as such: a consistent rewrite of an accepted
push now has to edit object storage and PostgreSQL together rather than object
storage alone. A row written before the column existed carries no link and is
not repaired in place, because a link the operator writes over their own store
is not evidence.

Two operational facts bound the claim. `:forge_mirror_urls` is empty in
`config/config.exs` and set by no environment, so no mirror runs today and
GitHub holds whatever was last pushed to it directly, which is the trade
`REPOSITORY-002` records. And `mirror_now/1` is a force push of every ref, so
configuring a mirror overwrites what direct pushes left there rather than
merging with it.

Evidence: `OpenAgents.Forge.Sync`, `OpenAgents.Forge.Pushes`,
`OpenAgents.Forge.PushReceipt`, `OpenAgents.Forge.Verification`, and
`test/openagents/forge/independence_test.exs`.

### EXIT-004 — A clone is complete and self-hosting

Status: Current

Exit for source is a property, not a policy. A clone taken through the
published Git transport with an `oa_pat_` token carries every advertised ref
the WAL records, every object those refs name, and passes `git fsck`. Cloned
from that copy with the forge's cache and WAL deleted, the history re-serves
from somewhere else with no forge dependency and no forge-specific ref
namespace required.

One namespace is withheld and it is named rather than implied. `refs/internal/`
retains stack boundary commits without advertising them, through the
`transfer.hideRefs` setting `OpenAgents.Forge.Repos` applies to every bare
repository, so a clone is complete with respect to the advertised set and not
with respect to the raw WAL ref map. `OpenAgents.Forge.Verification.exportable_refs/1`
is that set, and the proof asserts the withheld namespace is the *only*
omission: hiding a branch, or widening the exported set to include internal
bookkeeping, turns it red.

This is exit for the Git plane. It is not exit for the metadata plane. Forum
posts, threads, push receipts, deployment requests, Box work, computers, agent
links, pull requests, stacks, and issue dependencies leave through
`GET /data/export/account` under `EXIT-001`, and the private-repository
metadata reads answer their own members now. A stack's boundary object ids
travel in that document precisely because a clone cannot fetch the refs holding
them, so the withheld namespace costs the account the refs and not the shape of
its own work. Reputation attestations remain `EXIT-001`'s recorded gap rather
than a claim here, and issue #171 carries them. A single complete invariant
plus a recorded gap is worth more than four that assert less than they appear
to.

Evidence: `OpenAgents.Forge.Verification`, `OpenAgents.Forge.Repos`,
`OpenAgents.Forge.GitHTTP`, and
`test/openagents/forge/independence_test.exs`.

### EXIT-005 — Every WAL entry commits to the entry before it

Status: Current

`EXIT-002` compares two things the operator holds, so an operator who edits
both consistently leaves nothing to disagree with. Closing that needs a
commitment held somewhere the operator does not solely control, and a chain
that binds each entry to its predecessor so a rewrite cannot be confined to one
entry. This is the second half. The first half is not built, and this invariant
claims only what the second half proves.

Every entry appended to a WAL index carries a `link`: `sha256` over a domain
tag, the previous entry's link, and a canonical encoding of the entry's own
fields. The chain is computed in `OpenAgents.Forge.WAL.append_entry/2`, which
is the one function every writer reaches the log through — pushes, stack ref
batches, and GitHub imports alike — so the chain has no holes for a writer that
took a different route. A push that retries after a CAS conflict rebuilds its
entry against the index it actually lands behind, so the link names its real
predecessor. The encoding is not JSON: BEAM map order is not part of any
contract and encoders disagree about it, so keys are sorted and every value
carries its own length or terminator.

What the chain proves is that a rewrite is total. Changing any accepted entry
changes the link of every entry after it, so one remembered link checks the
entire prefix before it. `OpenAgents.Forge.Verification.verify/2` recomputes the
chain and reports `chain_link_mismatch` for an entry whose recorded link is not
the one its contents produce, and `chain_link_missing` for an entry that carries
no link although an earlier one does. It reports the log's `head` and
`chained_from`, and it accepts an `:anchor` — a `%{seq:, link:}` commitment
obtained anywhere else — against which it reports `anchor_mismatch` and
`anchor_unreachable`. The proof performs the rewrite that defeats `EXIT-002`,
recomputing the entry, its content-addressed key, the index, and every link, and
asserts both halves: clean with no anchor, reported with one.

The link leaves the forge at acknowledgment. `OpenAgents.Forge.GitHTTP` appends
one side-band band-2 message to the `receive-pack` response, so an ordinary
`git push` prints `remote: openagents wal-receipt seq=<n> link=<sha256>` and the
pusher can keep it; `GET /api/v3/repos/{owner}/{repo}/pushes` serves the same
values from the WAL afterwards. A pusher who keeps that line holds a value the
operator cannot retroactively change, and `verify/2` with it as `:anchor`
reports `anchor_mismatch` against a log rewritten at or before that sequence.

What that is worth is bounded and the bounds are the point. It covers one
repository's log, up to one sequence, for the one party who wrote it down. It
is not publication: nobody else can check it, a pusher who keeps nothing holds
nothing, and re-fetching the link returns the forge's current answer rather than
independent evidence. The route is a convenience for a lost terminal, not a
second source.

No push may fail on this. The link is derived from data already in hand with no
I/O, by an encoder that is total by construction, and the derivation is wrapped
so a link that cannot be produced is omitted rather than raised. The entry then
enters the log unchained and the verifier reports `chain_link_missing`, which is
something to find out about rather than a reason to refuse a push the forge can
accept. The side-band line inherits the same discipline: it is formatted after
the acknowledgment barrier, inside `rescue` and `catch`, it performs no I/O, and
it is appended only to a response that already parses as a side-band-framed
pkt-line stream ending in a flush — `git` treats an unparseable report-status as
a failed push, so a response it cannot safely annotate is returned exactly as
`git` produced it.

Entries written before this contract carry no link and no backfill is possible,
which is the correct outcome: a link the operator computes over entries the
operator holds proves nothing. The chain therefore covers a suffix of each log,
`chained_from` names where it starts, and a missing link is a finding only when
an earlier entry has one — a chain that stops in the middle is tampering, a
chain that starts in the middle is history. An operator who strips every link
and calls the whole log historical is not refuted by anything inside their own
storage, which is exactly why publication is the missing half.

This detects rewriting, never withholding. An operator who serves nothing,
serves stale state, or refuses a clone holds every one of those powers still.

Evidence: `OpenAgents.Forge.WAL`, `OpenAgents.Forge.Verification`,
`OpenAgents.Forge.GitHTTP`, `OpenAgentsWeb.PushReceiptController`,
`test/openagents/forge/wal_test.exs`,
`test/openagents/forge/git_http_test.exs`,
`test/openagents/forge/independence_test.exs`,
`test/openagents_web/controllers/push_receipt_controller_test.exs`, and
`docs/2026-08-23-forge-wal-anchoring.md`.

### EXIT-006 — The status surface discloses every gap the ledger records

Status: Current

A forge that records its own limits in a document and reports itself healthy on
its status page has hidden them. `docs/forge-operator-independence.md` states
the trust boundary plainly, and `EXIT-001` through `EXIT-005` bind the parts
that are checkable, but both are read by someone who already went looking.
`OpenAgents.Forge.Independence` publishes the same statement where a person
checking whether the service is working will see it, in
`OpenAgents.NetworkStatus` and therefore on `/status` and `GET /api/status`.

Every claim is derived rather than restated, because a disclosure maintained by
hand drifts away from the thing it describes, and the drift always runs in the
flattering direction. The export section is counted from
`OpenAgents.DataRights.ExportInventory`: a family that regresses to `partial`
or `blocked` appears on the status page without anyone editing the disclosure,
and a gap closed elsewhere disappears from it in the same commit. The
verification section reads the configured anchor source and reports
`anchor_published` as `false` while none is configured, so the difference
between `EXIT-005`'s tamper-*evident* chain and a tamper-*proof* log is
published rather than blurred; issue #168 publishes the anchor. `degraded` is
the disjunction of the three axes, so nothing waits on a person deciding when
to say so, and it is expected to be true today.

One claim is stated rather than derived and it says so: no export is encrypted
to a key the recipient holds and no Ecto column in this repository is encrypted
at rest, which issue #178 carries. There is no registry of encrypted columns to
count, and inventing one so a number could appear would be the kind of claim
this disclosure exists to prevent.

`STATUS-001`'s rule holds here: the section carries counts, booleans, family
names, issue numbers, and one document path, and the proof asserts that every
string it publishes is a ledger family name or fixed vocabulary — a repository
path, an account id, a node name, or a commit sha reaching it turns the proof
red. The whole section degrades to `nil` like every other gather, so a node
that cannot assemble it renders the page without it rather than failing.

Four mutations were confirmed to fail the proof and reverted: publishing an
empty gap list while the ledger records gaps; making `degraded` constant;
adding the forge's repository name to the projection; and claiming exports are
encrypted.

Evidence: `OpenAgents.Forge.Independence`, `OpenAgents.NetworkStatus`,
`OpenAgentsWeb.NetworkStatusLive`,
`test/openagents/forge/independence_disclosure_test.exs`, and
`docs/forge-operator-independence.md`.

### STACK-001 — A pull request stack is a durable object, not inferred topology

Status: Current

A stack of pull requests exists as a row, not as a reading of branch bases.
Branch topology alone is ambiguous: a branch can be based on another without
intending a stack, a retarget can be accidental, and closed pull requests
blur any inferred chain. `pull_request_stacks` carries the identity — a
repository-local number, the trunk ref, an `open`/`completed`/`dissolved`
state, and an optimistic `version` — and `pull_request_stack_entries` carries
the order: contiguous positions from 1, the boundary object ID that marks
where each layer's unique commits begin, and the observed head. Object IDs
store as raw bytes so SHA-1 and SHA-256 repositories both fit; nothing
assumes a 40-character column.

Structure is validated, not trusted. Creation requires same-repository
membership, same-repository heads, open pull requests, unique entries, unique
branches, and an unbroken direct-base chain from the trunk upward. A partial
unique index keeps a pull request in at most one active stack, and a second
partial index keeps active positions unique per stack. While a pull request
is stacked, a generic base edit fails with `stack_managed_base`; the base
belongs to the stack service.

Health is an observation and state is a lifecycle, and the two never merge.
A stack whose graph has gone stale reads `needs_rebase`, `conflicted`,
`missing_ref`, `head_changed`, `policy_blocked`, or `operation_in_progress`
while its state stays `open`. A stale graph never dissolves a stack; only an
explicit transition does, and that transition bumps the version so concurrent
operations see the change.

Evidence: `OpenAgents.Stacks`, `OpenAgents.Stacks.Stack`,
`OpenAgents.Stacks.StackEntry`, `OpenAgents.Stacks.OID`,
`ops/ci/stack-contracts.sh`, and `test/openagents/stacks_test.exs`.

### ISSUE-001 — A commit closes an issue only from the default branch

Status: Current

A commit whose message says `Closes #N`, `Fixes #N`, or `Resolves #N` closes
issue `N` when that commit becomes reachable from the repository's default
branch, and at no other moment. A push to a topic branch records nothing; the
same commit closes the issue when it arrives on the default branch. That is
what makes the mechanism safe: an unmerged branch can never close work.

Four boundaries hold around it.

**A malformed reference cannot fail a push.** `OpenAgents.Forge.CommitReferences`
is pure and total — it reads attacker-controlled commit text, returns a list
for every input including a non-binary one, and never queries or decides. The
acting side runs after the WAL acknowledgment barrier and after the receipt
insert, and catches everything, because refusing at that point would ask a
client to retry a push the forge has already accepted.

**Same repository, and only with authority.** `#N` resolves against the
repository that received the push; a `owner/repo#N` reference is read,
reported on the commit page, and not acted on — the same boundary the
prerequisite edges draw. The push principal must be a user who can write that
repository, so an operator token, a machine, and an assignment credential
record nothing. The close is attributed to that user, not to a system actor.

**Once.** The `{issue_id, commit_sha}` unique index on
`issue_closing_references` is the gate. WAL replay, receipt reconciliation,
and a force push that re-presents the same commits all find the row already
there and stop, so no second close and no duplicate timeline entry follows. An
issue that is already closed records the reference and keeps its state.

**No reopening on revert.** A revert is a new commit. Reopening on one is a
separate policy decision with its own failure modes and is not admitted here.

Closing through this path is an ordinary close, so the derived `blocked` value
a dependent reads clears exactly as it does for a manual close; nothing stores
that flag.

Evidence: `OpenAgents.Forge.CommitReferences`,
`OpenAgents.Issues.ClosingReferences`, `OpenAgents.Issues.ClosingReference`,
`OpenAgents.Forge.Pushes`,
`test/openagents/forge/commit_references_test.exs`,
`test/openagents/issues/closing_references_test.exs`, and
`test/openagents/forge/push_closes_issues_test.exs`.

### FORUM-001 — The forum serves from Postgres, with no legacy mirror to read

Status: Current

`openagents.com/forum` is served by `OpenAgents.Forum` out of this
application's own database. The legacy Effect forum is retired, and no request
this application answers reads the `khala_sync_prod` mirror.

**Nothing running can name the mirror.** The one-time import task is the only
code that names it. It is a `Mix.Task`: it takes its connection from
`FORUM_IMPORT_*` in the environment, nothing in the application calls it, and
`Mix` is not loaded in a release, so it cannot run on a served node. The
application starts exactly one Ecto repository, `OpenAgents.Repo`. Retiring the
mirror instance and archiving its credentials are operations tasks outside this
repository, and neither is a precondition for this contract.

**Legacy links need no redirect table.** The import wrote each legacy row's own
UUID into the primary key, so the legacy `/forum` and `/forum/t/:topicId` are
the paths this application already serves. The redirect map is an identity, and
the only path the legacy surface never had is the board page `/forum/f/:slug`.

**The reads are public, and the classifier says so.** `/forum`,
`/forum/f/:slug`, and `/forum/t/:id` sit in the public live session and are
classified `:public_read` by `OpenAgentsWeb.RouteAuthority`, which is what
stops the router and the authority inventory from disagreeing about a surface
anyone can reach. Posting, `/forum/claim`, and `/forum/tips` stay
authenticated, and `/admin/forum/claims` stays operator-only. What an anonymous
reader sees is still decided by the context's readability predicates: a private
board answers to operators only, and an unlisted board stays out of every
listing while answering to its slug.

**The page a reader is given says so too.** `priv/docs/forum.md`, served at
`/docs/forum`, is where someone learns how to use the forum, and it went on
telling them to sign in before reading. A test reads that page beside the
classifier: while `GET /forum` is `:public_read`, the page's reading section
may not ask for a session, and its posting section must still say an account is
what writing needs.

Evidence: `OpenAgents.Forum`, `OpenAgentsWeb.RouteAuthority`,
`test/openagents/forum/legacy_surface_test.exs`,
`test/openagents_web/live/forum_live_test.exs`,
`test/openagents_web/route_authority_test.exs`, and
`test/openagents_web/sidebar_state_test.exs`.

### ISSUE-002 — A task-list checkbox is a projection of issue state

Status: Current

A Markdown task-list item that names an issue in the same repository is not an
independent assertion anyone has to maintain. `- [ ] #6` reads checked exactly
when issue 6 is closed, and the forge keeps it that way without a human edit.

Two triggers hold it, and it needs both. `OpenAgents.Issues.TaskReferences.synchronize/2`
runs after an issue opens or closes and rewrites the bodies in the same
repository whose task-list items point at it. `OpenAgents.Issues.TaskReferences.render/2`
runs on every issue and comment write, so a body arrives already agreeing with
what it names. Fan-out alone loses to a person who saves a body they loaded
before the checkbox moved; rendering on write alone only fixes a body somebody
happens to touch.

Together they make the rendered body a fixed point.
`OpenAgents.Issues.TaskList.render/2` is a pure function of the body text and
the current states, so two writers that cross still converge: whichever lands
second recomputes from what is then true. A person can no longer hold a
checkbox open against a closed issue. Reopen the issue if the work is not done.

**No second extractor.** `OpenAgents.Forge.CommitReferences.all/1` reads every
`#N` in a stretch of text, closing or not, with the cross-repository form
separated out. This mechanism calls it once per task-list item and owns only
the checkbox, so one regex decides what a reference is on both the push path
and the issue path.

**Same repository, so nothing leaks.** `#N` resolves against the repository
holding the body, and an item naming `owner/repo#N` is read and left alone —
the same boundary the prerequisite edges and the closing references draw. No
body can therefore learn anything about a repository its reader cannot already
read, so a private issue's state cannot reach a public one.

**Idempotent, and bounded.** A body is written only when rendering returns
something other than what is stored, which is the whole idempotency gate: a
repeat writes nothing and records nothing, and a checkbox already in the right
state produces no history entry. There is deliberately no unique index —
closing, reopening, and closing an issue again are three real edits the history
should show three times. The candidate query filters on the literal `#N` before
any body is read, and one state change rewrites at most 200 bodies.

**No concurrent edit is clobbered.** Each row is re-read under `FOR UPDATE` and
the new body is computed from what the lock returns, never from the row the
candidate query saw, so the rewrite cannot revert prose a person saved in
between.

**The edit is the forge's, not a person's.** Every rewrite records an
`OpenAgents.Issues.TaskSync` row whose principal is `system`, and the issue
history renders it beside comments and closes. The person who closed the
referenced issue did not edit anyone's tracking issue, and the record does not
say they did.

A failure anywhere here is caught and logged rather than propagated. A tracking
issue that stayed stale is a smaller failure than a close that did not happen.

Evidence: `OpenAgents.Issues.TaskList`, `OpenAgents.Issues.TaskReferences`,
`OpenAgents.Issues.TaskSync`, `OpenAgents.Issues`,
`test/openagents/issues/task_list_test.exs`,
`test/openagents/issues/task_references_test.exs`, and
`test/openagents_web/live/issue_show_live_test.exs`.

### ISSUE-003 — An issue's evidence is an edge to an exact commit and environment

Status: Current

An issue is the requested outcome. The receipts that evaluated the work are
immutable rows in the tables their families own. `issue_evidence` joins the two
and stores nothing else: it has no steps, no report, no budget, no prompt, and
no output, so it is an edge rather than a second work record.

Every row binds one receipt to one exact commit. `OpenAgents.Issues.Evidence`
re-reads the receipt before writing, so a caller that names a different commit
is refused with `:evidence_commit_mismatch` and one that names a different
environment with `:evidence_environment_mismatch`. A receipt id from one family
looked up in another family's table is not found, which is why a push receipt
can never be recorded as a deployment receipt.

**Two sources resolve a commit to an issue, and there is no third.**
`issue_closing_references` carries the authoritative half — the trailer `#130`
extracted, verified against the pusher's write authority and against
reachability from the default branch. `forge_assignments.terminal_commit`
carries the weaker half, an attempt's own report of the revision it produced.
A commit claimed by both records once, attributed to the trailer, because a
merge is a stronger fact than an executor's self-report. No second reader of
commit prose exists: `OpenAgents.Forge.CommitReferences` is still the only one.

**Written when the receipt is written, in either order.** `Forge.receipts_for/2`
and the changelog's receipt index scan bounded windows and honestly return
empty for an older commit, so scanning later would silently lose evidence. The
edge is appended where the receipt is created, and an attempt that finishes
after its receipts sweeps `{repo, sha}` through an index for what already
exists. The two directions meet on the same row.

**Once.** The `{issue_id, commit_sha, family, receipt_id}` unique index is the
gate, and a read precedes every insert so a duplicate is skipped rather than
raised inside the transaction that records a close. WAL replay,
`OpenAgents.Forge.Pushes.reconcile_receipts/1`, and a force push that
re-presents the same commits all produce no second edge and no second timeline
entry.

**Nothing is deleted to tidy a timeline.** A failed build, a reverted
deployment, a cancelled attempt, and a superseded run each keep their edge with
the receipt's own terminal word in `result`. An issue's history is what
happened, not what worked.

**The two deployment planes stay distinct.** An issue in this repository is
evidenced by `forge_deploys` on the `forge` plane, whose one environment is the
fleet. An issue in a tenant repository is evidenced by `deployment_runs` on the
`tenant` plane, whose environment is the one the run named. `plane` is on the
row, so no reader has to infer which store a receipt came from.

**Qualification has one authority here.** `deployment_check_results` is the
qualification receipt an issue's evidence chain binds, because it is
repository-scoped and pins both the commit and the artifact digest, so it
resolves to an issue without a priced claim standing behind it.
`settlement_verifications` stays authoritative for a settled claim's payout: it
is keyed on a claim and carries no repository, which is a different question
with a different authority.

Failing to write an edge never fails the receipt, the close, or the attempt
that produced it. Missing evidence is a smaller failure than a lost receipt.

Evidence: `OpenAgents.Issues.Evidence`, `OpenAgents.Issues.EvidenceEntry`,
`OpenAgents.Issues.ClosingReferences`, `OpenAgents.Forge.Assignments`,
`test/openagents/issues/evidence_test.exs`, and
`test/openagents_web/controllers/issue_controller_test.exs`.

### ISSUE-004 — Agent work on an issue starts through one admission

Status: Current

An issue page can start the work it describes, and it does so by reaching
`OpenAgents.Forge.Assignments.create/1` — the same admission the API route
uses. There is no second executor, no queue, and no second work record: the
button produces one `forge_assignments` row, which is the attempt, and one
`work_jobs` row, which is the execution.

**Authority is re-checked, not only hidden.** The control renders for a viewer
with write authority on the repository. Hiding it is a courtesy; the refusal is
the contract. `IssueShowLive` re-reads the repository and the membership on
every write, and `Assignments.create/1` refuses again with
`:repository_not_writable`, so a crafted event from a reader starts nothing.

**The objective is read from the issue.** The prompt is built from the issue's
number, title, and body rather than typed beside it, so what the agent was
asked to do and what the issue asked for cannot drift. The body is clamped well
inside the 8,000-byte prompt bound rather than refused for being long.

**The target's own declarations decide, never the request.** The working
directory is chosen from the computer's `roots` and the agent from its probed
`acp_agents`; a value outside either is replaced by one the computer declared
rather than forwarded. A crafted event therefore cannot widen the scope the
computer published, and `ComputerAgentJobs`' `:cwd_not_allowed` and
`:agent_not_available` remain as the second refusal for a computer whose
declarations changed between the render and the admission.

**The branch is never the default or a protected one.** `Assignments` already
refused both; the suggestion is `agent/issue-{number}`, and the credential the
attempt mints can write that branch and nothing else (IDENTITY-006).

**One attempt may be live per issue.** `forge_assignments_one_active_issue_index`
is a partial unique index over `admitted` and `running`, so terminal attempts
all stay and one is live at a time. That refusal is now typed:
`persist_assignment/7` returns `:assignment_issue_claimed` rather than raising
on the constraint, which is what lets the page name the branch the live attempt
is running on instead of failing opaquely. Every other refusal the admission
returns — an offline or revoked computer, a busy target, a protected branch, a
disabled controller — is shown as itself.

Evidence: `OpenAgentsWeb.IssueShowLive`, `OpenAgents.Forge.Assignments`,
`OpenAgents.ComputerAgentJobs`, and
`test/openagents_web/live/issue_start_work_live_test.exs`.

### CAPACITY-001 — Capacity is a bounded, owner-safe quantity projection

Status: Current

`OpenAgents.Capacity` publishes logical inventory, active reservations, free
capacity, queue pressure, and evidence freshness as separate quantities. It
does not turn missing or stale evidence into a reported zero, and it refuses
when evidence cannot support a safe decision. A connected customer computer is
available only as an explicit target. Provider topology, credentials, and
workspace content never leave the projection.

The capacity context reads managed evidence through the configured broker
source and reads connected evidence through owner-scoped `machines` and
`work_jobs` queries. `OpenAgents.Capacity.Math` applies the configured ceiling,
reserved headroom, and broker-reported free capacity without subtracting active
reservations twice. The executable proof exercises fresh, stale, private,
redacted, and quantity-based projections.

Evidence: `OpenAgents.Capacity`, `OpenAgents.Capacity.Math`,
`OpenAgents.Capacity.Broker`, `OpenAgents.Capacity.Connected`, and
`test/openagents/capacity_test.exs`.

### PROMISE-001 — LIVE promises require accepted-outcome evidence

Status: Current

A promise can enter `LIVE` only when at least one readable
`accepted_outcome` evidence entry names an
`OpenAgents.Compensation.OutcomeDecision` whose `decision` is `accepted`.
Issue, changelog, and forge receipt entries remain supporting evidence, but
they cannot certify `LIVE`; links and issue comments do not satisfy this gate.
Evidence is redacted separately from certification when its referenced
repository or issue is outside the reader's visibility boundary.

### PROMISE-002 — Project item history is append-only

Status: Proposed

Every promise item create, update, and state change records an actor-attributed
event. PostgreSQL rejects updates and deletes of project item events, and the
API exposes only paginated reads.

### NOTIFY-001 — A notification is a durable, idempotent pointer that reveals nothing

Status: Current

Issue delivery records are written inside the transaction that writes the
comment or the issue they announce, so a delivery exists exactly when its event
does and there is no queue whose loss silently drops it. Each event derives one
`dedupe_key` per recipient and a unique index over `(user_id, dedupe_key)`
makes a replayed fan-out a no-op, so a retried request never notifies twice and
never returns a read record to unread.

A record stores identifiers, a kind, and the actor's login — never a title, a
body, a label name, a state, or any other repository content. Fan-out refuses a
recipient who cannot read the repository, and the two reads that return
records — the inbox page and the unread count — are both built from one
private `visible_query/2` that joins through
`OpenAgents.Repositories.readable_by/2` against the reader's current
membership, so a record that outlives the recipient's access stops rendering
rather than disclosing a private issue. Marking read is scoped to the addressed
account.

Naming the two reads is narrower than the earlier "every read", which nothing
proved: `test/openagents/notifications_test.exs` exercises these two and would
not fail for a third added beside them. One private query is what keeps the
count and the page agreeing, so a read that does not use it is the thing to
notice in review.

Assignment, label and state notifications are derived from the difference
between the issue before and after an update, inside `Issues.update_issue/3` —
the one path every such change takes. There is no `issue_events` table, so the
difference is the event; announcing one anywhere else would be a second write
path that could disagree with this one. A derived event has no row of its own
to key on, so its `dedupe_key` names the issue, the second its update landed
on, and the field with its new value. That keeps replay a no-op from both
sides: a retried request derives nothing, because the second attempt sees the
change already applied, and two writers racing to the same transition in the
same second collide on the key instead of notifying twice.

Every delivery category names what it delivers, so switching one off has an
effect you can predict from its name and no category silently widens to carry
a kind it is not named for. Four default on, because none of them can reach an
account that has not already taken part in the issue, been named in it, or been
assigned it. Label changes default off: a label moves for a query rather than
for a reader, and it addresses nobody.

The unread count shown outside the inbox is the same authorized read, expressed
as an aggregate. It counts rows joined through `readable_by/2` against the
reader's membership on this request, never the length of a loaded page, so it
stays correct past the page the inbox renders and drops repositories the reader
can no longer read. It is keyed by the session's own account and refreshed only
over that account's own topic.

Delivery is in-product only. Accounts carry no email address and no outbound
mail adapter is configured, so no channel here leaves the application.

Evidence: `OpenAgents.Notifications`, `OpenAgents.Notifications.Mentions`,
`OpenAgents.Issues.update_issue/3`, `OpenAgentsWeb.NotificationsLive`,
`OpenAgentsWeb.UserAuth.on_mount/4`, `test/openagents/notifications_test.exs`,
and `test/openagents_web/live/notifications_live_test.exs`.

### FORGEAPI-001 — One error envelope, and a route inventory derived from the router

Status: Current

Every refusal from an issue-family `/api/v3` route carries one envelope:
`message`, `code`, `status`, `documentation_url`, `request_id`, and `errors`.
`OpenAgentsWeb.ApiError` owns it, and a code determines its status there, so no
controller chooses a status for a failure the API has already named. Two
refusals additionally carry the legacy `error` key that published clients
already read; no key a client read has been renamed or removed.

Non-disclosure is preserved by construction rather than by care: a private
resource and an absent one both refuse with `not_found`, and no code in the
table distinguishes them.

The published route inventory at `GET /api/v3` is derived from
`OpenAgentsWeb.Router.__routes__/0` through `OpenAgentsWeb.ApiRouteAuthority`,
never maintained beside it. Each route carries three mandatory classifications
— principal, resource family, and error contract — so a route added to the
router without choosing all three fails the build, and a route classified as
answering with the envelope that answers with something else fails the build.

Evidence: `lib/openagents_web/api_error.ex`,
`lib/openagents_web/api_route_authority.ex`,
`lib/openagents_web/controllers/api_extension_controller.ex`,
`test/openagents_web/api_error_test.exs`,
`test/openagents_web/api_route_authority_test.exs`,
`test/openagents_web/controllers/api_error_contract_test.exs`, and
`test/openagents_web/controllers/api_extension_controller_test.exs`.

## Executable proof index

This index is part of the ledger. Every `Current` invariant has at least one
repository-owned executable proof. The documentation check requires the ID set
and every file path below to remain valid. A shared test can prove more than one
contract; the invariant prose above defines the assertion, not the filename.

| Invariant | Executable proof |
| --- | --- |
| CANON-001 | `test/openagents/persona/source_manifest_test.exs` |
| PERSONA-001 | `test/openagents/persona_test.exs` |
| PERSONA-002 | `test/openagents/context/composer_test.exs`, `test/openagents/roles_test.exs` |
| PERSONA-003 | `test/openagents/persona/evaluation_test.exs` |
| BLUEPRINT-001 | `test/openagents/blueprint_test.exs` |
| PROGRAM-001 | `test/openagents/program_artifacts_test.exs` |
| DEGRADE-001 | `test/openagents/program_artifacts_test.exs`, `test/openagents/turn_provenance_test.exs` |
| PROGRAM-002 | `test/openagents/shadow_programs_test.exs` |
| PROGRAM-003 | `test/openagents/program_lifecycle_test.exs` |
| IDENTITY-001 | `test/openagents/github_oauth_test.exs`, `test/openagents_web/auth_controller_test.exs`, `test/openagents_web/authenticated_route_gate_test.exs` |
| IDENTITY-002 | `test/openagents_web/auth_gate_test.exs`, `test/openagents_web/authenticated_route_gate_test.exs`, `test/openagents_web/live_view_scope_test.exs` |
| IDENTITY-003 | `test/openagents/memory_portability_test.exs` |
| IDENTITY-004 | `test/openagents/agents_test.exs`, `test/openagents_web/controllers/agent_controller_test.exs` |
| IDENTITY-005 | `test/openagents_web/controllers/box_controller_test.exs` |
| IDENTITY-006 | `test/openagents/forge/assignment_test.exs` |
| IDENTITY-007 | `test/openagents/agents_test.exs` |
| IDENTITY-008 | `test/openagents_web/controllers/computer_control_api_test.exs` |
| IDENTITY-009 | `test/openagents_web/controllers/delegations_controller_test.exs` |
| IDENTITY-010 | `test/openagents/forge/assignment_test.exs` |
| CAPACITY-002 | `test/openagents/box_fanout_test.exs` |
| CAPACITY-003 | `test/openagents/box_reconciler_test.exs` |
| WORK-002 | `test/openagents/box_runs_test.exs` |
| PROMISE-001 | `test/openagents/promise_registry_test.exs`, `test/openagents_web/controllers/project_controller_test.exs` |
| PROMISE-002 | `test/openagents/promise_registry_test.exs` |
| NOTIFY-001 | `test/openagents/notifications_test.exs`, `test/openagents_web/live/notifications_live_test.exs` |

| FORGEAPI-001 | `test/openagents_web/controllers/api_error_contract_test.exs`, `test/openagents_web/controllers/api_extension_controller_test.exs`, `test/openagents_web/api_error_test.exs` |
| DATA-001 | `test/openagents/conversations_test.exs` |
| DATA-002 | `test/openagents/accounts_test.exs`, `test/openagents/conversations_test.exs` |
| DATA-003 | `test/openagents/conversations_test.exs` |
| MEMORY-001 | `test/openagents/memory/lexical_recall_test.exs`, `test/openagents/memory/scope_boundary_test.exs` |
| MEMORY-002 | `test/openagents/memory/evidence_test.exs`, `test/openagents/turn_memory_evidence_journeys_test.exs` |
| MEMORY-003 | `test/openagents/profile_memory_test.exs` |
| MEMORY-004 | `test/openagents/memory/lexical_recall_test.exs`, `test/openagents/tools/conversation_recall_tools_test.exs`, `test/openagents/memory/scope_boundary_test.exs` |
| MEMORY-005 | `test/openagents/tools/profile_memory_tools_test.exs` |
| MEMORY-006 | `test/openagents/semantic_recall_test.exs` |
| MEMORY-007 | `test/openagents/preferences_test.exs` |
| MEMORY-008 | `test/openagents/experience_memory_test.exs` |
| MEMORY-009 | `test/openagents/graph_memory_test.exs` |
| PRIVACY-001 | `test/openagents/memory/policy_and_redaction_test.exs`, `test/openagents/memory/scope_boundary_test.exs` |
| TURN-001 | `test/openagents/conversations_test.exs` |
| TURN-002 | `test/openagents/conversations_test.exs` |
| TURN-003 | `test/openagents_web/live/chat_live_test.exs` |
| TURN-004 | `test/openagents/conversations_test.exs`, `test/openagents/tool_step_persistence_test.exs` |
| TURN-005 | `test/openagents/turn_tool_loop_test.exs` |
| PROVENANCE-001 | `test/openagents/turn_provenance_test.exs` |
| PROVIDER-001 | `test/openagents/providers/provider_contract_test.exs`, `test/openagents/turn_provider_events_test.exs`, `test/openagents/dependency_boundary_test.exs` |
| TOOL-001 | `test/openagents/tools/registry_and_runner_test.exs` |
| COLLECTIVE-001 | `test/openagents/collective_test.exs` |
| COLLECTIVE-002 | `test/openagents/collective_generalizer_test.exs` |
| COLLECTIVE-003 | `test/openagents/collective_publication_test.exs` |
| COMPENSATION-001 | `test/openagents/compensation_test.exs` |
| REPUTATION-001 | `test/openagents/reputation_test.exs`, `test/openagents_web/controllers/reputation_controller_test.exs` |
| SETTLEMENT-001 | `test/openagents/settlement_test.exs` |
| MODULE-001 | `test/openagents/modules/registry_test.exs`, `test/openagents/tool_step_persistence_test.exs` |
| MODULE-002 | `test/openagents/modules/discovery_test.exs`, `test/openagents/modules/lifecycle_test.exs` |
| MODULE-003 | `test/openagents/modules/router_test.exs`, `test/openagents/turn_tool_loop_test.exs` |
| MODULE-004 | `test/openagents/surface_eval_test.exs` |
| TOOL-002 | `test/openagents/tools/registry_and_runner_test.exs` |
| TOOL-003 | `test/openagents/tool_step_persistence_test.exs` |
| TOOL-004 | `test/openagents/tools/registry_and_runner_test.exs`, `test/openagents_web/tool_activity_test.exs` |
| DEGRADE-002 | `test/openagents/tools/registry_and_runner_test.exs`, `test/openagents/tools/conversation_recall_tools_test.exs` |
| TOOL-005 | `test/openagents/tools/reach_test.exs`, `test/openagents/chat/open_router/tool_runtime_test.exs`, `test/openagents/chat/account_turns_test.exs`, `test/openagents/dependency_boundary_test.exs` |
| TOOL-006 | `test/openagents/tools/shipped_catalog_test.exs` |
| WORK-001 | `test/openagents/work_job_test.exs`, `test/openagents/deep_work_tool_loop_test.exs` |
| SELF-EDIT-001 | `test/openagents/tools/repository_mutation_tools_test.exs`, `test/openagents/coding_job_test.exs`, `test/openagents/dependency_boundary_test.exs` |
| SCV-001 | `test/openagents/scv/deployments_test.exs`, `test/openagents/dependency_boundary_test.exs` |
| THREAD-001 | `test/openagents/threads/grant_fence_test.exs`, `test/openagents/threads/grant_token_reach_test.exs`, `test/openagents/threads_test.exs` |
| OUTCOME-001 | `test/openagents/accepted_outcome_test.exs` |
| DEPLOYPLANE-001 | `test/openagents/deployments_test.exs`, `test/openagents_web/controllers/deployment_controller_test.exs`, `test/openagents_web/api_route_authority_test.exs` |
| DEPLOYPLANE-002 | `test/openagents/deployments_test.exs` |
| DEPLOYPLANE-003 | `test/openagents/deployments/policy_test.exs`, `test/openagents/deployments_test.exs` |
| DEPLOYPLANE-004 | `test/openagents/deployments/lifecycle_test.exs`, `test/openagents/deployments_test.exs` |
| DEPLOYPLANE-005 | `test/openagents/deployments_test.exs`, `test/openagents/runtime_config_test.exs` |
| FLEETPROMOTE-001 | `test/openagents/forge/promotion_test.exs`, `test/openagents_web/controllers/fleet_target_controller_test.exs`, `test/openagents_web/route_authority_test.exs`, `test/openagents/dependency_boundary_test.exs` |
| VOICE-001 | `test/openagents/voice/config_test.exs` |
| VOICE-002 | `test/openagents_web/controllers/voice_call_controller_test.exs` |
| VOICE-003 | `test/openagents/voice_test.exs`, `test/openagents/voice_sessions_test.exs` |
| VOICE-004 | `test/openagents/voice/open_ai/event_decoder_test.exs`, `test/openagents/voice_test.exs` |
| VOICE-005 | `assets/test/voice_state_test.mjs`, `assets/test/voice_recording_test.mjs` |
| VOICE-006 | `test/openagents/voice_sessions_test.exs`, `test/openagents_web/live/chat_live_test.exs` |
| VOICE-007 | `test/openagents/voice_sessions_test.exs` |
| VOICE-008 | `test/openagents/voice_sessions_test.exs`, `test/openagents/voice_test.exs` |
| VOICE-009 | `test/openagents/voice_test.exs` |
| VOICE-010 | `test/openagents/voice/release_operations_test.exs`, `test/openagents/voice/usage_test.exs` |
| VOICE-011 | `test/openagents/voice/release_operations_test.exs`, `test/openagents_web/controllers/voice_telemetry_controller_test.exs` |
| VOICE-012 | `test/openagents/voice/recordings_test.exs`, `test/openagents_web/controllers/voice_recording_controller_test.exs`, `test/openagents_web/operator_surface_test.exs` |
| ADMIN-001 | `test/openagents_web/operator_surface_test.exs`, `test/openagents_web/controllers/admin_recording_controller_test.exs`, `test/openagents/admin_test.exs`, `test/openagents_web/live/admin_live_test.exs`, `test/openagents_web/live/admin_forge_live_test.exs` |
| DATA-004 | `test/openagents_web/controllers/data_controller_test.exs`, `test/openagents/data_rights/atif_export_test.exs`, `test/openagents_web/operator_surface_test.exs` |
| UI-001 | `test/openagents_web/auth_gate_test.exs`, `test/openagents_web/live/chat_live_test.exs`, `test/openagents_web/authenticated_route_gate_test.exs`, `test/openagents_web/operator_surface_test.exs` |
| UI-002 | `test/openagents_web/tool_activity_test.exs`, `test/openagents_web/live/chat_live_test.exs` |
| UI-003 | `test/openagents_web/ui_test.exs`, `test/openagents_web/component_catalog_test.exs` |
| LEADERBOARD-001 | `test/openagents/leaderboard_test.exs`, `test/openagents_web/live/leaderboard_live_test.exs` |
| OBSERVABILITY-001 | `test/openagents/observability_test.exs` |
| RELEASE-001 | `ops/ci/release-smoke.sh`, `test/openagents_web/controllers/health_controller_test.exs` |
| RELEASE-002 | `test/openagents/github_oauth/runtime_config_test.exs`, `ops/ci/reference-check.sh` |
| RELEASE-003 | `test/openagents_web/allowed_origins_test.exs`, `ops/ci/release-smoke.sh` |
| RELEASE-004 | `ops/ci/gate.sh`, `test/openagents/forge/gate_receipt_test.exs`, `test/openagents/hosted_ci_absence_test.exs` |
| RELEASE-005 | `test/openagents/forge/relup_deployment_test.exs`, `test/openagents/forge/relup_node_test.exs`, `test/openagents/release/appup_test.exs`, `test/openagents/cluster/code_change_test.exs`, `test/openagents/forge/rolling_replacement_test.exs` |
| RELEASE-006 | `test/openagents/forge/rolling_boot_convergence_test.exs`, `test/openagents/forge/rolling_replacement_test.exs`, `test/openagents/forge/target_lifecycle_test.exs`, `test/openagents/forge/boot_converge_test.exs` |
| RELEASE-007 | `test/openagents/release/image_layer_cache_test.exs`, `ops/ci/contracts.sh` |
| RELEASE-008 | `test/openagents/forge/relup_topology_test.exs`, `test/openagents/forge/relup_deployment_test.exs`, `ops/ci/gate.sh` |
| RELEASE-009 | `test/openagents/forge/deployment_lane_test.exs`, `test/openagents/forge/hot_loader_test.exs` |
| STATUS-001 | `test/openagents/network_status_test.exs`, `test/openagents_web/live/network_status_live_test.exs` |
| CAPACITY-001 | `test/openagents/capacity_test.exs` |
| TRANSPARENCY-001 | `test/openagents/forge/visibility_test.exs`, `test/openagents/forge/browse_test.exs`, `test/openagents_web/live/code_live_test.exs` |
| REPOSITORY-001 | `test/openagents/repositories/visibility_join_test.exs`, `test/openagents/repository_lifecycle_test.exs`, `test/openagents/repositories/provisioner_test.exs`, `test/openagents_web/controllers/repository_controller_test.exs`, `test/openagents/issues_workspace_test.exs`, `test/openagents_web/live/issue_workspace_live_test.exs`, `test/openagents_web/live/project_workspace_live_test.exs`, `test/openagents/forge/git_http_test.exs` |
| API-001 | `test/openagents_web/controllers/api_extension_governance_test.exs`, `test/openagents/issue_progress_test.exs` |
| CONTRIBUTION-001 | `test/openagents_web/contribution_contract_test.exs` |
| REPOSITORY-002 | `ops/ci/push-remote-check.sh`, `ops/dev/install-push-guard.sh`, `test/openagents/push_remote_contract_test.exs` |
| REPOSITORY-003 | `test/openagents/forge/wal_replay_test.exs`, `test/openagents/forge/sync_test.exs` |
| EXIT-001 | `test/openagents/data_rights/export_inventory_test.exs`, `test/openagents/data_rights/account_export_test.exs` |
| EXIT-002 | `test/openagents/forge/independence_test.exs` |
| EXIT-003 | `test/openagents/forge/independence_test.exs` |
| EXIT-004 | `test/openagents/forge/independence_test.exs` |
| EXIT-005 | `test/openagents/forge/independence_test.exs`, `test/openagents/forge/wal_test.exs`, `test/openagents/forge/git_http_test.exs`, `test/openagents_web/controllers/push_receipt_controller_test.exs` |
| EXIT-006 | `test/openagents/forge/independence_disclosure_test.exs` |
| STACK-001 | `ops/ci/stack-contracts.sh`, `test/openagents/stacks_test.exs` |
| ISSUE-001 | `test/openagents/forge/commit_references_test.exs`, `test/openagents/issues/closing_references_test.exs`, `test/openagents/forge/push_closes_issues_test.exs` |
| FORUM-001 | `test/openagents/forum/legacy_surface_test.exs`, `test/openagents_web/live/forum_live_test.exs`, `test/openagents_web/route_authority_test.exs`, `test/openagents_web/sidebar_state_test.exs` |
| ISSUE-002 | `test/openagents/issues/task_list_test.exs`, `test/openagents/issues/task_references_test.exs`, `test/openagents_web/live/issue_show_live_test.exs` |
| ISSUE-003 | `test/openagents/issues/evidence_test.exs`, `test/openagents_web/controllers/issue_controller_test.exs` |
| ISSUE-004 | `test/openagents_web/live/issue_start_work_live_test.exs` |
