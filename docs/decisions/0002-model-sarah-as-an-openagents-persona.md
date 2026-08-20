# ADR 0002: Model Sarah as an OpenAgents persona

Date: 2026-08-20

Status: Accepted

## Context

Sarah has a distinct identity, voice, behavior contract, persona artifacts,
and evaluation material. Generic runtime infrastructure also inherited Sarah
names during integration. Treating Sarah as either a separate application or a
name for all infrastructure makes ownership unclear.

## Decision

Model Sarah as a persona and behavior package inside the `OpenAgents`
application. Keep Sarah names when identity is part of the contract, including
persona artifact IDs, behavior revisions, evaluations, visible identity, and
voice copy.

Use OpenAgents names for generic supervisors, web helpers, style packs,
runtime paths, build services, test cases, and configuration. Gate 2 performs
that semantic rename and adds an allowlist for intentional references.

## Consequences

- The product can add other personas without duplicating application
  infrastructure.
- Persona-specific history and provenance remain accurate.
- Generic code no longer implies that all OpenAgents behavior belongs to one
  persona.
