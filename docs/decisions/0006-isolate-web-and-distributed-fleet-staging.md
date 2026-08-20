# ADR 0006: Isolate web and distributed fleet staging

Date: 2026-08-20

Status: Accepted; implementation pending

## Context

Application regressions and distributed deployment failures need different
proof environments. Failure injection, database migration rehearsal, and
rolling replacement are unsafe when staging shares production data,
credentials, infrastructure, or a failure domain.

## Decision

Provision two staging lanes:

- A web lane for Phoenix, LiveView, authentication, chat, voice, data rights,
  PostgreSQL, and provider integration.
- A three-node distributed lane for Ra quorum, Git, builds, direct BEAM load,
  relup, rolling replacement, rollback, and boot convergence.

Give both lanes staging-only hosts, secrets, service accounts, buckets,
repositories, and a PostgreSQL instance that is separate from production.
Disable production promotion until both lanes pass the complete matrix,
failure injection, and a 48-hour soak on one exact candidate.

## Consequences

- Web regressions do not require a distributed deployment experiment.
- Fleet tests can terminate nodes and corrupt disposable artifacts without
  risking production.
- Staging costs more than sharing production infrastructure.
- Gate receipts must name the lane, exact source SHA, artifact and image
  digests, migration version, and staging revision without recording secrets.
