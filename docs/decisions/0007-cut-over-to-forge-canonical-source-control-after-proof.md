# ADR 0007: Cut over to forge-canonical source control after proof

Date: 2026-08-20

Status: Accepted; cutover pending

## Context

The product intends to host its canonical Git repositories on the OpenAgents
forge and keep GitHub as a discoverable read-only mirror. This repository still
uses GitHub as its configured canonical remote during staging hardening. A
documentation-only cutover would split contributor and deployment state.

## Decision

Keep GitHub canonical until the self-hosted Git plane passes authentication,
authorization, durability, mirror, restore, and operational recovery gates.
Perform the cutover as one controlled change that updates contributor
instructions, operator automation, build source, deployment promotion, and
mirror monitoring.

After cutover, accept pushes only through the forge for normal operation. Push
a one-way read-only mirror to GitHub, monitor mirror lag, and treat a direct
GitHub push as an incident. Do not let a mirror push promote a deployment.

## Consequences

- Current contributors keep one accurate remote during hardening.
- The future cutover has explicit prerequisites and rollback evidence.
- GitHub remains available for discovery without becoming a second writable
  authority.
- The application must report canonical-source and mirror state separately.
