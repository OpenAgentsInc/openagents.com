# Historical issues and projects API work plan

Date: 2026-08-19

Status: Core implementation complete; superseded by Gates 6 and 7 of the
[integration hardening plan](2026-08-20-integration-hardening-and-staging-readiness-recommendations.md)

## Completed scope

The original epics delivered Ecto contexts, schemas, migrations, controllers,
JSON projections, and tests for:

- Issue list, read, create, update, close, and reopen.
- Issue comments.
- Repository labels and issue-label relationships.
- Assignee listing/checking and issue-assignee relationships.
- Milestone list, read, create, update, and delete.
- Projects V2 list/read, project creation, items, item updates, and fields.

Controller and domain tests now cover the implemented success and error paths;
the paired LiveViews are covered separately. The dated
[coverage audit](2026-08-20-test-coverage-audit.md) records that work.

## Why this plan is closed

The implementation tasks are no longer the readiness bottleneck. The resource
model must now be hardened rather than expanded from this checklist:

- `/api/v1` now has a deliberate CLI model: public reads are separate and every
  write requires an expiring first-party bearer with `forge:write` scope.
- Owner/repository URL parameters do not yet map to a canonical repository row
  enforced throughout PostgreSQL.
- Some project actions ignore the username in the route.
- The assignee read surface and write behavior do not share one authorization
  rule.
- Several GitHub-compatibility edge cases are documented in the
  [API assessment](github-api-issues-projects-assessment.md).

Gate 6 owns API principals and route authority. Gate 7 owns repository
entities, tenant-scoped queries and constraints, backfill, and isolation tests.
New issue/project work should be added there until those gates pass rather than
reopening the original endpoint epics.
