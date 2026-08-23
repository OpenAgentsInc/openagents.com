# ADR 0001: Integrate the complete product in the public application

Date: 2026-08-20

Status: Accepted

## Context

Earlier plans divided a public web shell from private Sarah-specific chat,
voice, persona, and provider behavior. The repository now contains and operates
those product capabilities. Maintaining a fictional service split obscures
data ownership, weakens contributor understanding, and leaves public contracts
dependent on undocumented code.

## Decision

Keep the complete OpenAgents product in this AGPL-3.0 repository. The
`openagents.com` application owns the web interface, Sarah behavior,
conversation lifecycle, providers, tools, memory, delegated work, voice,
computers, issues, projects, forge, data rights, and operator surfaces.

Use external services only through explicit infrastructure or provider
adapters. Do not move product policy or Sarah behavior behind an undocumented
private API.

## Consequences

- Contributors can inspect, test, and modify every product contract.
- One application owns data-rights behavior and durable lifecycle recovery.
- Runtime secrets remain private even though orchestration code is public.
- Earlier public-shell and private-Sarah plans are superseded.
