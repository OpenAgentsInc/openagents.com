# Historical integration gap plan

Date: 2026-08-19

Status: Closed on 2026-08-20

Current tracker: [integration hardening and staging readiness](2026-08-20-integration-hardening-and-staging-readiness-recommendations.md)

## Purpose of this record

This plan was opened immediately after the source integration to restore an
honest test signal and commission the imported runtime. Its intermediate test
counts, stubs, missing routes, and phase labels no longer describe the tree.
They are not release evidence.

## Completed outcomes

- Removed the temporary skipped-test scaffold and restored the full local test
  suite.
- Completed runtime configuration for providers, tools, memory, voice, and
  clustering.
- Restored the application supervision tree, Horde/Ra integration, and boot
  catalog validation.
- Reconciled schema gaps for voice, provenance, work, forge builds, and forge
  deploys.
- Mounted the chat, computer, controller, data-rights, status, changelog,
  leaderboard, operator, code, issue, and project surfaces.
- Added the Git HTTP route, forge build/deploy records, and local release proof
  harnesses.
- Ported and enabled the integrated test suite, then added broad issue/project
  controller, domain, and LiveView coverage.
- Added an exact-SHA owned baseline gate, merged local/cluster coverage, and a
  disposable production-release smoke test.

## Unresolved work moved forward

Nothing remains owned by this plan. Its unresolved topics moved to explicit
gates in the current hardening plan:

- Documentation and invariant reconciliation: Gate 3.
- Dependency, Markdown, asset, icon, and component consolidation: Gate 4.
- Runtime configuration and startup validation: Gate 5.
- Identity, route authority, token lifecycle, and secret handling: Gate 6.
- Repository and tenant scoping for issues/projects: Gate 7.
- Chat, recovery, memory, work, machine, and voice hardening: Gate 8.
- Build isolation, artifact durability, transactional deployment, relup, and
  rolling replacement: Gates 9–11.
- Owned gates, isolated staging, regression evidence, failure injection, and
  soak: Gates 12–16.

Do not reopen this file as a parallel tracker. Add new findings to the current
hardening plan so readiness has one ordered source of truth.
