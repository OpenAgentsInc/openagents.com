# ADR 0007: Cut over to forge-canonical source control after proof

Date: 2026-08-20

Status: Accepted; cutover completed on 2026-08-22

## Context

The product hosts its canonical Git repositories on the OpenAgents Forge and
keeps GitHub as a discoverable read-only mirror. Before the cutover, this
repository used GitHub as its configured canonical remote during staging
hardening. A documentation-only cutover would have split contributor and
deployment state.

## Decision

The self-hosted Git plane passed its authentication, authorization, durability,
mirror, restore, and operational recovery gates. The 2026-08-22 cutover updated
contributor instructions, operator automation, build source, deployment
promotion, and mirror monitoring as one controlled change.

After cutover, accept pushes only through the forge for normal operation. Push
a one-way read-only mirror to GitHub, monitor mirror lag, and treat a direct
GitHub push as an incident. Do not let a mirror push promote a deployment.

## Consequences

- Contributors use one canonical Forge remote.
- The completed cutover retains explicit prerequisites and rollback evidence.
- GitHub remains available for discovery without becoming a second writable
  authority.
- The application must report canonical-source and mirror state separately.
