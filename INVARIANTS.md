# OpenAgents invariant ledger

These contracts define the current Simply OpenAgents release. A change to a listed
contract must update this ledger and its named test or model in the same
commit.

## OpenAgents identity and canon

### CANON-001 — Persona sources are immutable and status-labeled

Every historical source admitted to author OpenAgents's persona is pinned by
repository revision, path, content SHA-256, source status, admitted uses, and
explicit exclusions. The complete manifest has a canonical digest admitted by
the application and is validated before the supervision tree starts. Founder
direction, retired product material, unscheduled drafts, and scoped
performances cannot silently become runtime authority or ordinary voice.

Episode numbers are not source identity. The conflicting Episode 263 file is
quarantined, and the final Omega Alpha transcript is pinned by its actual path.

Evidence: `OpenAgents.Persona.SourceManifest`,
`priv/openagents/persona/openagents.v1.sources.json`, and
`OpenAgents.Persona.SourceManifestTest`.

### PERSONA-001 — Each inference uses one immutable persona artifact

OpenAgents's core identity, voice, and first-conversation greeting come from one
versioned artifact admitted by its exact content SHA-256. The artifact and its
source-manifest identity are validated and installed before the supervision
tree starts. Every provider request receives instructions composed from that
installed artifact; provider adapters contain no independent OpenAgents persona.

Evidence: `OpenAgents.Persona`, `priv/openagents/persona/openagents.v1.md`,
`OpenAgents.Context.Composer`, `OpenAgents.Turns.TurnServer`, and `OpenAgents.PersonaTest`.

### PERSONA-002 — One core OpenAgents identity composes with an admitted role

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
`OpenAgents.Roles.GeneralCollaborator`, `docs/ROLE_PROGRAMS.md`,
`OpenAgents.Context.ComposerTest`, and `OpenAgents.RolesTest`.

### PERSONA-003 — Persona promotion requires revision-bound regression evidence

Every persona candidate is evaluated against the committed, source-labeled
behavior corpus. Promotion requires a complete passing report bound to the
exact persona, source manifest, corpus, and model revisions. All cases must
pass, so military, founder-voice, sales, false-recognition, or generic-assistant
containment failures cannot be averaged away.

Evidence: `OpenAgents.Persona.Evaluation`,
`priv/openagents/evals/persona/corpus.v1.json`,
`OpenAgents.Persona.EvaluationTest`, and `mix openagents.persona.verify_promotion`.

### BLUEPRINT-001 — Platform facts are source-linked immutable revisions

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
`docs/SARAH_BLUEPRINT.md`, and `OpenAgents.BlueprintTest`.

### PROGRAM-001 — Model programs are immutable typed data, never effect authority

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
`priv/openagents/programs/`, `docs/PROGRAM_ARTIFACTS.md`,
`OpenAgents.Conversations.begin_inference/5`, and `OpenAgents.ProgramArtifactsTest`.

### DEGRADE-001 — Missing program artifacts degrade explicitly to a baseline

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
`priv/openagents/evals/shadow/corpus.v1.json`, `docs/SHADOW_PROGRAMS.md`, and
`OpenAgents.ShadowProgramsTest`.

### PROGRAM-003 — Promotion is offline, human-approved, and rollback-capable

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
database guards, `docs/PROGRAM_LIFECYCLE.md`, the synthetic sample promotion
report, and `OpenAgents.ProgramLifecycleTest`.

## Identity and authorization

### IDENTITY-001 — GitHub-authenticated account identity

Every OpenAgents interaction requires an active local user established through the
GitHub OAuth authorization-code flow. The immutable external key is GitHub's
numeric user ID; login and avatar URL are refreshable projections and never
authority. OAuth start uses high-entropy state plus PKCE S256. A short-lived
PostgreSQL attempt receipt makes state one-time even if an old encrypted cookie
is replayed. Phoenix exchanges the code and rereads `/user` server-side, then
discards the access token. The browser session contains only OpenAgents's local user
ID and is encrypted, signed, HTTP-only, same-site, and secure in production.

Evidence: `OpenAgents.GitHubOAuth`, `OpenAgents.Accounts`, `OpenAgentsWeb.AuthController`,
`OpenAgentsWeb.Endpoint.session_options/0`, `OpenAgents.GitHubOAuthTest`,
`OpenAgents.AccountsTest`, and `OpenAgentsWeb.AuthControllerTest`.

### IDENTITY-002 — Conversation lookup never accepts a client database ID

The browser supplies only its encrypted OpenAgents session. Server code loads the
active local user and resolves that user's internal storage owner and canonical
conversation. A route parameter, form value, mutable GitHub login, or LiveView
event must not select another user, owner, or conversation. All typed, memory,
data, voice, and telemetry routes fail before mutation without an active user;
health endpoints remain public and create no identity state.

Evidence: `OpenAgentsWeb.UserAuth`, `OpenAgentsWeb.Router`,
`OpenAgentsWeb.ChatLive.mount/3`, `OpenAgents.Conversations.get_conversation_for_user/1`,
and `OpenAgentsWeb.AuthGateTest`.

### IDENTITY-003 — Account continuity supersedes browser portability

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
`docs/MEMORY_PORTABILITY_THREAT_MODEL.md`, and `OpenAgents.MemoryPortabilityTest`.

## Data authority and synchronization

### DATA-001 — PostgreSQL is authoritative

Visitors, conversations, messages, and turns are persisted before their state
is presented as accepted. PubSub and LiveView streams are projections; losing
either must not lose accepted data.

Evidence: `OpenAgents.Conversations.create_turn/2` and
`OpenAgentsWeb.ChatLiveTest` durable-turn test.

### DATA-002 — One canonical conversation per authenticated user

Database uniqueness enforces one internal storage owner per local user and one
conversation per owner. Initial greeting creation is coupled to first
conversation creation. Distinct users remain isolated; multiple sessions for
one user converge on the same conversation and therefore the same text and
voice limits. Pre-authentication browser rows remain inaccessible legacy data
and are never silently claimed during login.

Evidence: unique indexes and identity-source constraint in
`create_github_users`, `OpenAgents.Conversations.ensure_conversation/1`, and
account continuity/isolation/rate tests in `OpenAgents.AccountsTest`.

### DATA-003 — History is bounded and stable

The newest page and every older page contain at most the configured page size.
Ordering uses persisted timestamp plus UUID, and rendered rows use stable
message IDs.

Evidence: `OpenAgents.Conversations.list_messages/2` and bounded-history test.

## Memory and recall

### MEMORY-001 — Recall is confined to the current account conversation

Every recall snapshot and search is bound to one canonical conversation
resolved from the authenticated local user. A snapshot from another
conversation or user is refused, and no API offers a cross-conversation or
unscoped fallback. GitHub identity establishes account continuity but does not
turn conversation evidence into verified facts about a person.

Evidence: `OpenAgents.Memory.RecallSnapshot`, `OpenAgents.Memory.LexicalRecall`, and
cross-scope tests in `OpenAgents.Memory.LexicalRecallTest`.

### MEMORY-002 — Recalled history is classified evidence, not current profile truth

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
`docs/MEMORY_CONTROLS.md`, `docs/PROFILE_MEMORY.md`, `OpenAgents.ProfileMemoryTest`,
and memory-control journeys in `OpenAgentsWeb.ChatLiveTest`.

### MEMORY-004 — Scope and snapshot boundaries are database predicates

Recall scope is enforced by `messages.conversation_id` in every PostgreSQL
query, never by prompt instructions. Each inference immutably records a
`message:<uuid>` high-water ref for the last eligible message before the current
user turn. Searches apply its ordered timestamp/UUID cursor and admit only
complete user/assistant rows, so streaming or failed assistant text and normal
later inserts cannot enter the turn's recall view.

Evidence: `OpenAgents.Conversations.begin_inference/5`, the generated `search_vector`
and partial GIN migration, `OpenAgents.Memory.LexicalRecall`, immutable turn receipt
triggers, and snapshot/status/index tests in `OpenAgents.Memory.LexicalRecallTest`.

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
`turn_receipts.profile_memory_snapshot_ref`, `docs/MEMORY_TOOLS.md`, and
`OpenAgents.Tools.ProfileMemoryToolsTest`.

### MEMORY-006 — Semantic recall is scoped, disposable, and lexically degradable

Authoritative durable conversation rows — messages, and for lexical
tool-activity recall the terminal tool steps — remain the sole recall
authority; semantic embeddings exist only for messages. Embeddings are
asynchronous derivatives bound to the source message, exact conversation,
content digest, model/version manifest, and active generation. Hybrid queries
repeat the conversation and frozen snapshot predicates in PostgreSQL and admit
only ready rows whose digest still matches the authoritative complete message.
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
derivative tables and triggers, `docs/HYBRID_RECALL.md`,
`priv/openagents/evals/recall/hybrid-comparison.v1.json`, and
`OpenAgents.SemanticRecallTest`.

### MEMORY-007 — Learned preferences require confirmation and never confer authority

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
`docs/GOVERNED_PREFERENCES.md`, the committed preference comparison, and
`OpenAgents.PreferencesTest`.

### MEMORY-008 — Experience is private, terminal, evidenced, and advisory

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
`docs/PRIVATE_EXPERIENCE_MEMORY.md`, the committed benefit comparison, and
`OpenAgents.ExperienceMemoryTest`.

### MEMORY-009 — Graph memory is a disposable, generation-atomic projection

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
database guards, `docs/DERIVED_GRAPH_MEMORY.md`, the committed graph comparison,
and `OpenAgents.GraphMemoryTest`.

### PRIVACY-001 — Secret-bearing profile memory is rejected, never scrub-stored

Before candidate storage, the host applies the pinned
`openagents.memory.policy.v1` policy to the claim, provenance/artifact metadata, and
same-owner source content. Credential, API/auth token, wallet/seed/payment,
encoded-secret, and local-path material rejects the whole candidate. The
rejected value, a hash of it, or a partially scrubbed shell is never persisted.
Only owner scope, fixed policy version, bounded reason/category, size bucket,
and time enter the rejection audit.

Every export or future model/UI projection re-applies
`openagents.memory.redaction.v1`. A value that fails revalidation is withheld as a
whole field. Stored policy identities are immutable, so later policy changes
cannot silently relabel old records or rejection evidence.

Evidence: `OpenAgents.Memory.Policy`, `OpenAgents.Memory.Redaction`,
`profile_memory_policy_events`, immutable policy-version trigger,
`docs/MEMORY_PRIVACY_POLICY.md`, and `OpenAgents.Memory.PolicyAndRedactionTest`.

## Turn and provider lifecycle

### TURN-001 — At most one active turn per conversation

An active turn is `queued` or `streaming`. A partial unique PostgreSQL index is
the final arbiter; the UI's disabled composer is only feedback.

Evidence: `turns_one_active_per_conversation_index` and active-turn test.

### TURN-002 — Every accepted turn has durable paired messages

The user message, empty streaming assistant message, and turn record are
inserted in one transaction. Completion, failure, and cancellation update both
assistant-message and turn terminal state.

Evidence: `OpenAgents.Conversations.create_turn/2`, `finish_turn/5`, and turn tests.

### TURN-003 — Provider work never blocks the LiveView

Each response executes in a temporary `TurnServer` under a dynamic supervisor;
the outbound provider call executes in a supervised task. Text deltas cross a
typed provider callback and are persisted before broadcast.

Evidence: `OpenAgents.Turns.TurnServer`, `OpenAgents.ProviderTaskSupervisor`, and
`OpenAgentsWeb.ChatLiveTest` streaming test.

### TURN-004 — Interrupted work becomes explicit failure

Active records left by a runtime restart are marked failed during application
startup. A response is never left permanently presented as in progress without
an executing turn process.

Evidence: `OpenAgents.Conversations.recover_interrupted_turns/0`, the
`OpenAgents.TurnRecovery` application child, and startup-recovery test.

### TURN-005 — Tool continuations are serial, bounded, and commit-first

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

Before provider work starts, OpenAgents durably captures the exact model, persona,
role, instruction digest, canonical input digest, optional runtime artifact
identities, and first provider step. Identity fields never change; terminal
receipts and provider steps cannot be rewritten. Failures, cancellation, and
restart recovery preserve the captured chain. Turns created before this
contract remain explicitly legacy rather than receiving invented provenance.

Evidence: `OpenAgents.Conversations.begin_inference/4`, PostgreSQL provenance
triggers, `OpenAgents.Provenance.Canonical`, and `OpenAgents.TurnProvenanceTest`.

### PROVIDER-001 — Model providers are replaceable

Conversation and web code depend on `OpenAgents.Providers.Provider`, not OpenAI
event shapes. Adapters emit typed OpenAgents-domain lifecycle, text, tool-call,
usage, completion, failure, and cancellation events. A response ID is persisted
when announced, and matching explicit completion is required; stream closure
alone cannot produce a completed turn. Provider-specific events, credentials,
and raw errors never reach the receipt or browser.

Evidence: `OpenAgents.Providers.ProviderEvent`, `OpenAgents.Providers.OpenAI`,
`OpenAgents.Providers.OpenAI.StreamDecoderTest`, `OpenAgents.Providers.Test`, and
`OpenAgents.TurnProviderEventsTest`.

## Tool authority and execution

### TOOL-001 — A turn uses one immutable tool catalog

The registry validates configured tool specifications at boot. Before provider
work, each turn captures one catalog snapshot and writes its canonical digest
to the immutable receipt. Every call must match the exact tool name and version
in that snapshot; later registry builds or deployments affect only later turns.

Evidence: `OpenAgents.Tools.Registry`, `OpenAgents.Tools.Snapshot`,
`OpenAgents.Turns.TurnServer`, and `OpenAgents.Tools.RegistryAndRunnerTest`.

### COLLECTIVE-001 — Private material crosses scope only through exact consent

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
constraints, `docs/COMPENSATION_ACCOUNTING.md`, and duplicate, revocation,
allocation, adjustment, reconciliation, privacy, and no-payout cases in
`OpenAgents.CompensationTest`.

### MODULE-001 — Every invocation pins one immutable admitted module

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
`OpenAgents.Tools.Runner`, `docs/MODULE_SURFACES.md`, and the surface, catalog,
approval, receipt, voice-interruption, and degradation tests.

### TOOL-002 — Model requests never widen host authority

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

### DEGRADE-001 — Tool degradation is explicit and deterministic

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
steps immutable. Startup recovery RESUMES orphaned active jobs (#97): it
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
`create_work_jobs` migration triggers, `OpenAgents.WorkJobTest`, and
`OpenAgents.DeepWorkToolLoopTest`.

### SELF-EDIT-001 — Every behavior change is anchored to a pushed commit (2026-08-19)

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
  Promote click (ADMIN-001 as amended) is the human approval receipt, and
  the allowlist of hot-loadable modules remains operator-owned data.
- **Receipts reconstruct what ran.** Tool outcome receipts carry the commit
  SHA of every push; push, build, and deploy receipts chain from that SHA;
  together they let an operator reconstruct exactly which code was live
  when, with no step inferred.

Evidence: `OpenAgents.Tools.Repository` (clone confinement, branch discipline,
typed refusals), `OpenAgents.Work.Coding`, `OpenAgents.Forge.Pushes` /
`OpenAgents.Forge.Targets` / `OpenAgents.Forge.HotLoader` receipts, ADMIN-001, and
`OpenAgents.Tools.RepositoryTest` / `OpenAgents.CodingJobTest`.

## Interface and release

### VOICE-001 — Spoken identity is admitted before media

Standalone OpenAgents's first voice artifact is `openagents.voice.openai.marin.v1` using
native OpenAI Realtime `gpt-realtime-2.1` at low reasoning effort. It is a
deliberate repository-local revision of the earlier Leda direction, not a
silent fallback or a change to One. Boot refuses unadmitted architecture,
provider, model, voice, reasoning, or duration values. Any future custom voice,
Leda cascade, or built-in replacement requires a reviewed artifact revision
and regression evidence.

Evidence: `OpenAgents.Voice.Config`,
`docs/voice/OPENAI_REALTIME_DECISION.md`, and `OpenAgents.Voice.ConfigTest`.

### VOICE-002 — Browser media admission cannot acquire server authority

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
`docs/voice/VOICE_RUNTIME.md`, `OpenAgents.VoiceTest`, and
`OpenAgents.VoiceSessionsTest`.

### VOICE-004 — Only bounded provider-neutral voice evidence becomes durable

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
`docs/voice/BROWSER_TRANSPORT.md`.

### VOICE-006 — Voice controls project server truth and preserve typed OpenAgents

Browser peer events cannot claim a durable listening, responding,
interrupted, ended, or failed state. The visible lifecycle is derived from the
browser-scoped, generation-fenced PostgreSQL session projected by LiveView.
Explicit interruption commits before provider cancellation. Voice admission is
refused during a text turn; sending typed input while voice is active ends the
voice generation first, so two OpenAgents responses cannot run in parallel. Voice
failure leaves the typed conversation intact and available.

Evidence: `OpenAgentsWeb.ChatLive`, `OpenAgentsWeb.VoiceCallController`,
`OpenAgents.VoiceSessions`, their tests, and `docs/voice/BROWSER_TRANSPORT.md`.

### VOICE-007 — Every live response freezes one governed OpenAgents context

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
`priv/openagents/evals/voice/corpus.v1.json`.

### VOICE-010 — New voice admission is live-governed, globally bounded, and attributable

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
`docs/voice/RELEASE_OPERATIONS.md`.

### VOICE-011 — Voice operations are measurable without becoming a content sink

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
`docs/voice/RELEASE_OPERATIONS.md`.

### VOICE-012 — Call audio is bounded, sealed, fenced evidence — never authority

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
choice, and typed chat remains available and is never recorded. The account
cannot play back its own audio either — the operator surface is the only place a
recording is audible, and the account's export carries the recording's metadata
rather than its sound.

Evidence: `OpenAgents.Voice.Recordings`, `OpenAgents.Voice.Recording`,
`OpenAgents.Voice.RecordingChunk`, `OpenAgents.Voice.RecordingVault`, the
`create_voice_recordings` migration, `OpenAgentsWeb.VoiceRecordingController`,
`assets/js/voice_recording.mjs`, `OpenAgents.Voice.RecordingsTest`,
`OpenAgentsWeb.VoiceRecordingControllerTest`, `assets/test/voice_recording_test.mjs`,
and `docs/voice/RECORDINGS.md`.

### ADMIN-001 — One operator reads across accounts, and only reads

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

The operator path is read-only. It exposes no ban, no message, no deletion, and
no configuration change, so a mistake in that surface cannot alter anyone's
conversation.

Amended 2026-08-18 (forge deploy lane, issue #119): the forge panel at
`/admin/forge` is the one deliberate exception, and it is a narrow one. Its
only write is promoting an already-pushed commit as the fleet deploy target
(`OpenAgents.Forge.Targets.promote/3`), receipted with the promoting operator's
identity in the append-only `forge_fleet_targets` ledger. Only SHAs present
in the WAL-backed repository are promotable, so the surface cannot introduce
code — it can only approve code that already survived the push path. It
still cannot touch any account, conversation, message, ban, or product
configuration; ADMIN-001's read-only rule continues to bind everything else
on the operator surface, including the original `/admin` panel unchanged. What it may show is the fields of `OpenAgents.Admin.Call` and the
audio itself: account display identity, call lifecycle, model, token total, and
recording completeness. Transcript *content*, composed instructions, tool
catalogs, provider call identity, and recall material stay out — cross-account
listening was the decision, and cross-account reading of what was said is a
separate one. Calls with no audio are listed with the reason rather than
hidden, so the panel cannot present an incomplete history as a complete one.

Evidence: `OpenAgents.Accounts.admin?/1`, `OpenAgentsWeb.UserAuth.require_admin_user/2`,
the `:ensure_admin` mount hook, `OpenAgents.Admin`, `OpenAgents.Admin.Call`,
`OpenAgentsWeb.AdminLive`, `OpenAgentsWeb.AdminRecordingController`, `OpenAgents.AdminTest`,
`OpenAgentsWeb.AdminLiveTest`, and `OpenAgentsWeb.AdminRecordingControllerTest`.

### DATA-004 — The authenticated user can export and delete OpenAgents product data

The server resolves export and deletion only from the active local user in the
encrypted session and verifies that user owns the internal storage root.
Export provides canonical messages, profile memory, voice summaries, and
tool-step evidence (raw arguments plus digests) with explicit bounds. Exact confirmation deletes the visitor root only while text
and voice are inactive; database cascades remove
conversation, memory, receipt, module, collective, and voice records — call
audio included, through `voice_recordings`' cascade to the session. The export
names each call's recording — status, container, size, duration claim, digest,
and that it is encrypted at rest — without embedding the audio, because a JSON
export is the wrong container for Opus and base64 in a text field would be
worse. The account cannot play back its own audio: the operator surface is the
only place a recording is audible. That is a decision rather than an omission —
what exists is disclosed and exported as metadata, and deletion removes it.
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
access status, and authentication timestamps) is retained so deletion cannot
erase a ban or bypass authorization. No GitHub access token is retained or
exported. A later account-erasure contract must separately define moderation
retention and re-enrollment behavior.

Evidence: `OpenAgents.DataRights`, `OpenAgentsWeb.DataController`,
`OpenAgents.Voice.Retention`, database foreign keys and purge trigger,
`OpenAgentsWeb.DataControllerTest`, and `OpenAgents.Voice.ReleaseOperationsTest`.

### UI-001 — Authentication gates the one-conversation interface

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
only by the allowlisted operator under ADMIN-001, is read only, cannot mount or
invoke OpenAgents, and holds no conversation. It adds nothing to the conversation
interface: no link, no affordance, and no chrome, for operators and
non-operators alike. Being an operator tool is not license for product
chrome — the anti-references in `PRODUCT.md` still describe what the product
does not become.

Evidence: `OpenAgentsWeb.HomeControllerTest`, the `OpenAgentsWeb.ChatLiveTest` surface
test, `OpenAgentsWeb.LeaderboardLiveTest`, `OpenAgentsWeb.AdminLiveTest`,
`OpenAgentsWeb.Router` browser policy, `PRODUCT.md`, and `DESIGN.md`.

### UI-002 — Tool activity is a bounded projection of PostgreSQL truth

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
durable step outcome remains the record. Machine tokens, argv, env, prompts,
and paths never enter a live event, and the topic is owner-scoped by
construction, so only the owner's conversation ever receives it.)

Evidence: `OpenAgents.Conversations.list_tool_step_activity/1`,
`OpenAgents.Voice.list_tool_step_activity/1`, `OpenAgentsWeb.ToolActivity`,
`OpenAgents.ComputerActivity`, `OpenAgentsWeb.ChatLive`, and tool activity tests in
`OpenAgentsWeb.ChatLiveTest`, `OpenAgentsWeb.ToolActivityTest`,
`OpenAgents.ComputerActivityTest`, and `OpenAgentsWeb.ChatDelegationRailTest`.

### UI-003 — Product surfaces render only through the sanctioned component library

OpenAgents's interface is built from `OpenAgentsWeb.UI` components over Basecoat
primitives vendored at a pinned tag and styled by the OpenAgents pack. Product
surfaces do not author component-level CSS classes; hand-authored CSS is
confined to app-shell layout and the one sanctioned brand animation. No
component accepts provider identifiers or private recall content as an
attribute; tool activity reaches `event_header` only as the bounded projection
UI-002 sanctions, so UI-002 cannot be violated through a primitive.
Basecoat's JavaScript is never loaded and the account menu uses the native
popover API, so the identity control works without custom client-side script.
Where Basecoat has no equivalent, the primitive wraps the browser's own control
rather than reimplementing it: `audio_player/1` is a native `<audio controls>`
in a OpenAgents-styled box, keyboard operable and announced by the user agent, and it
requires an accessible name because a page of recordings is otherwise a page of
identically announced players.
The shared corner radius, the self-hosted Geist faces, the single dark theme,
and the reserved semantic color meanings hold across every component. Depth is
limited to the sanctioned lift, halo, and state-ring tokens.
Adopting an additional Basecoat component requires a `DESIGN.md` change and an
explicit per-component import.

Evidence: `assets/vendor/basecoat/README.md`, `assets/css/style-openagents.css`,
`priv/static/fonts`, `OpenAgentsWeb.UI`, `OpenAgentsWeb.UITest`,
`OpenAgentsWeb.UIGalleryLiveTest`, and `priv/scripts/check_css_contract.exs`.

### LEADERBOARD-001 — The public board publishes one bounded projection

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
`OpenAgents.Leaderboard.Server`, `docs/LEADERBOARD.md`, `OpenAgents.LeaderboardTest`,
and `OpenAgentsWeb.LeaderboardLiveTest`.

### OBSERVABILITY-001 — Telemetry is bounded, content-free, and never authoritative

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
`docs/OBSERVABILITY.md`, and `OpenAgents.ObservabilityTest`.

### RELEASE-001 — Schema precedes traffic

The production image runs all pending Ecto migrations before starting the HTTP
server. Health is successful only when PostgreSQL answers.

Evidence: Docker `CMD`, `OpenAgents.Release`, the `/status` route, and
`HealthControllerTest`.

### RELEASE-002 — Secrets remain runtime-only

Session, database, provider, and GitHub OAuth credentials enter through ignored
local runtime configuration or Secret Manager and are absent from source, the
Docker build context, and image build arguments. Staging mounts only staging
GitHub secret names through a dedicated runtime identity; production values and
its prepared identity are distinct and remain unmounted until production
cutover. Missing or environment-mismatched GitHub configuration fails startup
without printing any credential value. Reserved GitHub token-encryption keys
are not mounted while the runtime discards tokens after identity projection. The Cloud Logging
default sink excludes only OpenAgents OAuth callback request entries so the platform
cannot persist authorization-code or state query values; application and audit
logging remain enabled.

Evidence: `OpenAgents.GitHubOAuth.RuntimeConfig`,
`OpenAgents.GitHubOAuth.RuntimeConfigTest`, `config/runtime.exs`, `.gitignore`,
`.dockerignore`, the `openagents-oauth-callback-requests` logging exclusion, and
`docs/DEPLOY.md`.

### RELEASE-003 — Every published hostname can establish LiveView

Production accepts the primary `PHX_HOST` plus explicitly configured HTTPS
aliases for Phoenix origin checks. Invalid, insecure, or path-bearing origins
fail startup rather than silently weakening socket validation.

Evidence: `OpenAgentsWeb.AllowedOrigins`, `OpenAgentsWeb.AllowedOriginsTest`, and the
production WebSocket read-back.

### RELEASE-004 — CI runs on owned infrastructure only, and gates every release

No hosted CI, ever: no GitHub Actions workflows (`.github/workflows/`), no
GitHub-hosted or third-party runners, no repo automation, secrets, or
scheduling handed to external CI compute (owner restatement 2026-07-25; same
invariant as `openagents/INVARIANTS.md` "No GitHub-Hosted CI / Cloud Actions"
and `AGENTS.md` "No hosted CI"). All checks run on owned machines: manually
(`mix precommit`, `ops/ci/gate.sh`), through standard git hooks
(`.githooks/pre-push`), or inside owned deploy tooling. The full matrix — unit
suite, distributed cluster-chaos suite, relup drill, version-chain drill — must
PASS for the exact commit being shipped before a fleet release;
`ops/fleet/rolling-deploy.sh` refuses to roll without that receipt.

Evidence: `ops/ci/gate.sh`, `.githooks/pre-push`, the receipt check in
`ops/fleet/rolling-deploy.sh`, and the absence of `.github/workflows/`.

### STATUS-001 — The status page publishes one bounded, content-free projection

The public `/status` page and `/api/status` publish exactly one projection
(`OpenAgents.NetworkStatus`, schema-versioned): cluster membership and quorum,
Raft membership, per-node release/hot-load versions, uptimes, and counts.
Counts only, never content — no machine names, job goals or ids,
conversation data, provider identifiers, or internal node names/addresses
(nodes render as stable positional labels). It shares the leaderboard's
UI-001 posture (read-only, cannot mount or invoke OpenAgents) and renders through
the sanctioned component library (UI-003).

The page must render DURING incidents: nothing in the projection may require
quorum, the database, or a full fleet — every gathered field degrades
independently (an unreachable node reports as unreachable; a failed count is
absent), and the per-node fan-out is time-bounded and briefly cached so page
traffic cannot become an rpc storm. Legacy JSON pollers of `/status` keep the
old health payload via content negotiation until they migrate to `/healthz`
or `/api/status`.

Evidence: `OpenAgents.NetworkStatus`, `OpenAgentsWeb.NetworkStatusLive`,
`OpenAgentsWeb.Plugs.StatusProbeCompat`, `OpenAgents.NetworkStatusTest`, and
`OpenAgentsWeb.NetworkStatusLiveTest`.

### TRANSPARENCY-001 — Public transparency surfaces publish per-repo leveled projections

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
operator identifiers) stays off it — `docs/OPERATIONS.md` is never
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
