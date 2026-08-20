# OpenAgents architecture

Date: 2026-08-20

Status: Current product architecture and accepted hardening target

## Purpose

This document is the source of truth for the integrated `openagents.com`
application. Use it to understand product ownership, durable authority, trust
boundaries, and deployment strategies. Dated migration and implementation plans
remain useful as historical records, but they do not override this document.

OpenAgents is one public AGPL-3.0 application. It includes the source-code
forge, issues and projects, the Sarah conversational agent, provider
orchestration, memory, voice, delegated work, connected computers, and operator
surfaces. The application does not divide these features between a public shell
and a private product service.

## System map

```text
browser
  |
  | HTTPS, LiveView, WebSocket, or authenticated JSON
  v
OpenAgents Phoenix application
  |-- public and authenticated web surfaces
  |-- Sarah conversation, voice, memory, and work orchestration
  |-- issues, projects, machines, and data rights
  |-- Git HTTP and forge deployment control
  |-- server-side provider adapters
  |
  +--> PostgreSQL: durable product and deployment authority
  +--> object/artifact storage: immutable build artifacts
  +--> provider APIs: replaceable server-side dependencies
  +--> GitHub: identity and user-authorized repository access
  `--> BEAM cluster: ephemeral execution and fleet coordination
```

The `OpenAgents` namespace owns generic application infrastructure. Sarah is a
persona and behavior package within that application, not a second application
or service boundary.

## Product ownership

The repository owns these capabilities:

- Browser presentation and Phoenix LiveView state.
- Sarah persona artifacts, behavior, voice, and evaluation material.
- Conversation, message, turn, provider-step, and tool-step lifecycles.
- Provider selection, request construction, response handling, and usage
  accounting.
- Tools, memory systems, delegated work, and connected-computer orchestration.
- Accounts, data export, deletion, administrative policy, and incidents.
- Repositories, Git HTTP, issues, labels, milestones, projects, and public code
  browsing.
- Build, promotion, deployment, rollback, convergence, and deployment receipts.

Do not add a private Sarah service as an architectural dependency. A separate
provider or infrastructure service can exist behind a documented adapter, but
the public application remains responsible for its product contracts and data
rights.

## Durable authority

PostgreSQL is the durable authority for product state, authorization state,
repository metadata, work state, fleet targets, and receipts. A transaction
that does not commit cannot become product truth.

Treat these systems as projections or execution aids:

- LiveView socket assigns and browser state.
- Phoenix PubSub messages.
- BEAM registries, supervisors, tasks, and process mailboxes.
- In-memory caches and `:persistent_term` values.
- Network and deployment status pages.
- Local build and artifact caches.

Immutable artifacts can live in durable object storage, but PostgreSQL records
their identity, digest, lifecycle, and authorized target. Reconcile an
ephemeral projection from durable state after restarts or missed events.

## Trust boundaries

Every route belongs to one authority class. Gate 6 of the hardening plan owns
the exhaustive route ledger and enforcement tests.

| Class | Principal | Examples | Required enforcement |
| --- | --- | --- | --- |
| Public | Anonymous visitor | Home, docs, status, changelog, allowed public code | Read-only behavior, bounded output, and visibility policy |
| Authenticated | Active OpenAgents user | Chat, data rights, computers, issues, projects | Signed session, CSRF protection for browser mutations, and owner or repository scope |
| Operator | Configured active administrator | Administration, promotion, deployment, recording review | Authenticated session plus server-side operator authorization on every action |
| Machine | Paired machine credential | Controller socket, presence, and agent jobs | Hashed or encrypted scoped token, explicit machine ownership, rotation, and revocation |
| Internal service | Configured service identity or signed grant | Inference proxy and build/deployment adapters | Narrow audience and scope, expiry, replay defense, and no browser-held service secret |
| Git | Machine or operator Git credential | `/git` fetch and push | HTTP Basic transport with server-side token verification and repository authorization |

Route placement does not prove authorization. A controller, LiveView mount, or
socket must enforce the class and resource scope at the server boundary. Until
the Gate 6 route audit passes, treat the current router as implementation
evidence rather than a complete authorization policy.

## Provider boundary

Provider adapters implement replaceable server-side behavior. Direct OpenAI
integration is the current default adapter choice for text, embeddings, shadow
programs, and voice. It is not an application-wide contract.

The browser can receive bounded provider-derived events and media negotiation
results, but it must never receive an OpenAI API key, GitHub access token,
forge operator token, machine token, recording key, or internal-service signing
key. Adapters own transport details, timeouts, bounded retries, response
validation, error normalization, and secret redaction. Product contexts own
durable lifecycle and policy.

Tests replace network providers with explicit fakes. A provider outage must
produce a bounded durable failure outcome instead of abandoning an in-flight
turn, work item, or voice session.

## Untrusted Markdown boundary

Assistant and repository Markdown enters HTML through
`OpenAgents.Markdown.to_html/2` only. MDEx parses CommonMark with dangerous
rendering disabled, Ammonia applies exact tag, attribute, and URL-scheme
allowlists, and the application normalizes links before Phoenix marks the
result safe. Independent input, syntax-tree nesting, and output limits produce
a bounded escaped fallback instead of partial markup. The same function handles
streaming completion and persisted text, so a completed message does not change
when its durable projection replaces the stream.

## Forge planes

The forge contains two separate planes within the `OpenAgents.Forge`
application namespace:

- The Git plane accepts authenticated Git traffic, stores repositories and
  push receipts, controls visibility, serves public browsing, and mirrors refs.
- The deployment plane promotes an exact pushed SHA, builds immutable
  artifacts, selects a deployment strategy, changes fleet state, rolls back,
  converges restarted nodes, and records receipts.

A push never promotes itself. Git repository availability does not imply that
a build is safe, and a successful build does not imply that a candidate is
live. PostgreSQL transitions connect the planes through an operator-authorized
target.

## Deployment strategies

Direct BEAM load, relup, and rolling replacement solve different problems. The
classifier must select one strategy for the complete candidate and fail closed
when it cannot prove eligibility.

| Strategy | Eligible changes | Required safety proof |
| --- | --- | --- |
| Direct BEAM load | Allowlisted module additions or changes without structural effects | Immutable manifest and digest, fleet prepare/apply/verify transaction, exact binary rollback, and readiness verification |
| Relup | Compatible versioned application changes and explicit process-state migrations | Forward and reverse appup/relup chain, state migration tests, staged install, permanent-release verification, and rollback drill |
| Rolling replacement | ERTS, OTP, NIF, dependency graph, assets, configuration, migrations, module deletion, or unclassified changes | Immutable image digest, node drain, readiness-gated replacement, capacity limits, and last-known-good rollback |

Development code reloading is not a production deployment strategy. Keep every
deployment capability disabled by default until its local proof and isolated
staging drill pass.

## SCV boundary

An SCV is the durable coding-execution and supervision contract. It is not a
container, model, OpenCode session, or tool catalog. The internal agent runtime
deploys SCV runs and each run binds these parts:

- A driver adapts one coding implementation, such as OpenCode or a native
  Elixir tool loop.
- An environment supplies a digest-addressed image or owned host with declared
  language and system capabilities.
- A runner starts and supervises the driver in that environment.
- The SCV owns policy, lifecycle, budgets, events, cancellation, artifacts,
  receipts, and the handoff to Forge.

This boundary lets the runtime deploy several SCVs with different drivers and
environments. Native coding tools belong to a native driver. OpenCode keeps its
own protocol behind the same SCV policy and event boundary; OpenCode does not
become the SCV or the environment.

The first qualification image combines the Elixir SCV worker release with the
OpenCode driver and the `opencode-core` polyglot environment. Its staging
process role accepts only read-only runs and starts no Phoenix endpoint, Repo,
Forge service, or deployment coordinator. Forge remains the only deployment
authority.

## Runtime and staging topology

The accepted target has two isolated staging lanes:

- A web lane proves Phoenix, LiveView, PostgreSQL, authentication, chat, voice,
  data rights, and provider behavior without distributed deployment enabled.
- A three-node distributed lane proves Ra quorum, Git, immutable builds, direct
  loading, relups, rolling replacement, rollback, and boot convergence.

Both lanes use staging-only hosts, credentials, buckets, repositories, service
accounts, and a PostgreSQL instance that does not share a production failure
domain. Production is out of scope until all hardening gates, the complete
staging matrix, failure injection, and the 15-minute pinned-candidate soak pass.

`OpenAgents.RuntimeConfig` validates the complete behavior-changing settings
boundary before migrations or traffic. The
[runtime configuration contract](runtime-configuration.md) defines the safe
feature profile, durable storage requirements, staging-gate admission, and
content-free readiness report.

## Source control transition

GitHub remains the repository's temporary canonical remote during staging
hardening. The self-hosted forge becomes canonical only through an explicit
cutover after its Git, mirror, artifact, rollback, and recovery gates pass. The
cutover changes contributor instructions and push automation in the same
candidate. After cutover, the forge pushes a read-only GitHub mirror and direct
GitHub pushes become invalid.

Do not describe the cutover as complete while contributor clones and automated
pushes still target GitHub.

## Decision records

- [ADR 0001: Integrate the complete product in the public application](decisions/0001-integrate-the-complete-public-application.md)
- [ADR 0002: Model Sarah as an OpenAgents persona](decisions/0002-model-sarah-as-an-openagents-persona.md)
- [ADR 0003: Keep provider credentials behind server adapters](decisions/0003-keep-provider-credentials-behind-server-adapters.md)
- [ADR 0004: Retain scoped GitHub access tokens in the server vault](decisions/0004-retain-scoped-github-access-tokens.md)
- [ADR 0005: Use Basecoat and one OpenAgents component system](decisions/0005-use-basecoat-and-one-component-system.md)
- [ADR 0006: Isolate web and distributed fleet staging](decisions/0006-isolate-web-and-distributed-fleet-staging.md)
- [ADR 0007: Cut over to forge-canonical source control only after proof](decisions/0007-cut-over-to-forge-canonical-source-control-after-proof.md)

## Superseded narratives

The following documents record earlier plans and measurements. They do not
define the current architecture:

- `docs/chat-inference-plan.md` proposed a private Sarah service boundary that
  the integrated application does not use.
- `docs/sarah-integration-plan.md` records the migration into this repository.
- `docs/2026-08-19-gap-implementation-plan.md` records earlier gap work.
- `docs/beam-hot-deployment-plan.md` contains detailed deployment design, but
  its phase status does not authorize production use.

The [integration hardening and staging readiness plan](2026-08-20-integration-hardening-and-staging-readiness-recommendations.md)
tracks the work required to make this architecture safe and verifiable.
