# Historical Sarah integration record

Date: 2026-08-19

Status: Migration complete; this is a historical record, not an implementation
plan

Superseded by: [docs/architecture.md](architecture.md) and the
[integration hardening plan](2026-08-20-integration-hardening-and-staging-readiness-recommendations.md)

## Outcome

The complete conversational product was integrated into the public
`openagents.com` Phoenix application. The application now owns:

- Accounts, OAuth, durable conversations, messages, turns, and provenance.
- Persona, role, Blueprint, provider, tool, and program-artifact contracts.
- Profile, lexical, semantic, experience, graph, and portability memory paths.
- Delegated work, connected computers, machines, and incidents.
- Voice sessions, transcripts, usage, recordings, and release controls.
- Operator, status, leaderboard, changelog, data-rights, issues, projects, and
  forge surfaces.
- The corresponding migrations, browser assets, configuration, and tests.

The migration retained persona-specific Sarah artifact names and stable data
contracts where identity or historical compatibility required them. Generic
supervision, web helpers, runtime paths, styles, tests, and forge infrastructure
now use OpenAgents names. [ADR 0002](decisions/0002-model-sarah-as-an-openagents-persona.md)
defines that boundary.

## Migration sequence

The work landed in these broad stages:

1. Application dependencies, supervision, accounts, and authentication.
2. Conversation, turn, receipt, memory, work, machine, and voice schemas.
3. Persona, context, provider, module, tool, collective, and observability
   domains.
4. Chat, voice, operator, computer, status, changelog, and forge web surfaces.
5. Browser assets, the shared interface system, and runtime configuration.
6. Re-namespaced tests and support code, followed by removal of temporary test
   skips and local runtime stubs.
7. Horde/Ra clustering, forge build/deploy primitives, and owned local gates.

The original phase notes and intermediate pass/failure counts described a
temporary migration state and are intentionally not repeated as current facts.
The dated [coverage audit](2026-08-20-test-coverage-audit.md) preserves the
measurement history.

## Data lineage

The integration extended the existing `users` authority and added visitors,
conversations, messages, turns, memory, voice, work, machines, and forge
records. Historical migration filenames that contain Sarah names remain
immutable migration lineage; renaming an already-applied migration would make
schema history less trustworthy.

Persona and evaluation material remains under `priv/sarah/` because its stable
artifact IDs, digests, and wire schemas are compatibility and provenance
contracts, not generic application naming.

Before any nonempty staging database is upgraded, the complete migration chain
and visitor backfill must be rehearsed against a disposable restored copy. That
work belongs to Gates 13–16 of the current hardening plan.

## Remaining work

The source migration being complete does not make the application production
ready. Documentation reconciliation, dependency and component consolidation,
route authority, token lifecycle, tenant scoping, recovery, build isolation,
transactional fleet deployment, staging isolation, failure injection, and the
15-minute pinned-candidate soak remain governed by the current hardening plan.
