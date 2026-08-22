# Issues and projects work system assessment

Date: 2026-08-21

Status: Active program. The three projects and initial tracking issues exist in
production. Private issue reads and repository-scoped Projects V2 routes have
shipped; the remaining tracks stay open.

## Decision summary

Use OpenAgents Issues as the canonical record for work and Projects as views
that organize those issues across repositories. Keep milestones as release or
deadline commitments. Do not copy an issue into a second task system when an
agent starts work; link the issue to the durable agent job, conversation,
commits, tests, and deployment receipts instead.

Organize the near-term work around three projects:

1. **OpenAgents public roadmap** shows product outcomes that users and
   contributors can follow.
2. **Issues and Projects delivery** contains the detailed server, web, API, and
   CLI work required to make this system reliable.
3. **Agent work and provenance** contains the work that connects issues to
   chat and coding agents, work jobs, changes, and release evidence.

Use tracking issues for each outcome and child issues for independently
shippable changes. Until native sub-issues ship, use a checklist in the
tracking issue and keep every checklist entry linked to a real issue.

Finish the server contract before building rich clients on top of it. The
private issue-read asymmetry and initial-repository Projects V2 pin are fixed.
Issue lists remain unbounded, ancillary issue-resource reads remain
public-repository only, and the Projects model still lacks lifecycle and
cross-repository operations.

The generic `openagents api` command landed in the `openagents` monorepo at
`eaa2aa1006` and ships in `@openagentsinc/cli@0.2.1`, so every current route is
reachable from a terminal. The published CLI does not include named `issue` or
`project` commands. Coordinate with any active CLI task before you start D1
through D5, and do not make the server plan depend on an unmerged CLI branch.

## Scope and evidence

This assessment combines these sources:

- The implemented API inventory and known gaps in
  [GitHub-shaped Issues and Projects API assessment](github-api-issues-projects-assessment.md).
- The current web surface in
  [Issues and Projects UI roadmap](issues-projects-ui-roadmap.md).
- The API-to-CLI gap analysis in
  [CLI and API parity](2026-08-21-cli-api-parity-audit.md).
- The current authority and operating model in
  [Issue and project triage assessment and runbook](2026-08-21-issue-project-triage-runbook.md).
- The contract and design boundary in
  [Linear's design language over GitHub's shape](2026-08-20-linear-design-github-shape.md).
- Episodes 269 through 274 in the `openagents` monorepo. They establish the
  product direction: a compatible forge that works without agents, a single
  OpenAgents interface over repositories and agents, public development on
  the forge itself, and auditable links from plans and conversations to code
  and deployments.
- The current schemas, contexts, controllers, LiveViews, tests, and the public
  roadmap board.

The transcripts provide product background, not implementation instructions.
The repository's code, tests, authority ledger, and current operator decisions
remain the executable constraints.

## Current work records

Production now uses the structure recommended by this assessment:

- Project 1, **openagents.com roadmap**, holds the public product outcomes.
- Project 2, **Issues and Projects delivery**, holds the server and CLI
  delivery work.
- Project 3, **Agent work and provenance**, holds issue-to-agent and
  issue-to-release work.
- Issue 9, **Deliver the Issues and Projects work system**, tracks the delivery
  program.
- Issue 10, **Connect issues to agent work and release receipts**, tracks the
  provenance program.
- Issues 4 and 8 closed after private issue reads and repository-scoped
  Projects V2 routes deployed.
- Issues 5, 6, and 7 remain open for pagination and filters, request-origin
  URLs, and route-authority reconciliation.
- `OpenAgentsInc/openagents` issue 1 tracks the published CLI's stale embedded
  version value without duplicating the named-command work.

The project item statuses reflect deployed work, not branch state. Update them
only after the target environment has a release receipt.

## What exists now

### Issues

The issue system already supports more than the current project board shows:

- Repository-scoped list, read, create, update, close, reopen, and comments.
- Labels, assignees, milestones, authorship, locking fields, state reasons,
  and repository-local issue numbers.
- Public reading for public repositories and a tested browser participation
  model for reporters, authors, viewers, contributors, maintainers, and
  owners.
- Search, label, assignee, and milestone filters; 25-row pages; live updates;
  and a workspace-wide **Issues** page that shows every issue the signed-in
  person can read.
- GitHub-shaped REST routes for issue, comment, label, assignee, and milestone
  operations.
- Repository foreign keys and query boundaries that prevent cross-repository
  data leaks.

Important missing issue capabilities include:

- Optional-bearer private reads for comments, labels, assignees, and
  milestones. Issue list and issue detail private reads have shipped.
- A documented, bounded API pagination contract and the web filters on the
  API list route.
- Cross-repository and organization issue API views.
- Native issue types, sub-issues, dependencies, duplicates, and related-issue
  links.
- Timeline events, reactions, subscriptions, mentions, notifications, and
  saved views.
- Links from issues to work jobs, agent conversations, commits, releases, and
  deployments.

### Projects

The project system currently supports:

- Repository-owned projects with a number, title, owner, and open or closed
  state.
- Issue-backed project items with a free-form `values` map.
- Project fields with a name, data type, options, and project relationship.
- Project list, read, create, item add, item update, field list, and field
  create routes.
- A workspace-wide **Projects** page that lists every visible project.
- A repository board with fixed **To Do**, **In Progress**, and **Done**
  columns and a form that adds an issue to one of those columns.

The project layer remains an early implementation, not a complete work
system:

- Repository-scoped Projects V2 routes now resolve the repository in the path,
  apply public or member visibility, and use one consistent route family.
- The board cannot remove, reorder, or move an item directly. It does not
  render an item activity trail or show why an item changed status.
- The web board ignores the project's stored field definitions and always
  renders three hard-coded columns.
- Field types, option values, uniqueness, and item values are weakly
  validated.
- Projects have no update, delete, archive, view, ordering, iteration,
  template, or organization-owned surface.
- Project items can only point at issues in the project's repository. That is
  safer than leaking data, but it prevents a Projects V2-style cross-repository
  roadmap.

### CLI

The released CLI originally covered authentication and repository operations
only. The generic `openagents api` command now provides an authenticated,
origin-bounded passthrough for `GET`, `POST`, `PATCH`, `PUT`, and `DELETE`.
That gives scripts immediate access to the existing Issues and Projects API.

The generic command is not the end-user issue experience. Named commands need
repository inference, concise tables, issue-number arguments, editor support,
confirmation for destructive actions, and stable machine output. They are not
part of the published CLI. The server must keep providing correct, testable
routes while a coordinated CLI task owns the named command experience.

### Agent and receipt infrastructure

OpenAgents already has durable `work_jobs`, coding delegations, ATIF exports,
incidents, changelog entries, and deployment receipts. The missing feature is
the relationship between those records and an issue. Today, a conversation
can produce work and code, but the issue tracker cannot answer these questions
without manual reconstruction:

- Which conversation or request started this work?
- Which agent job is working on it now?
- Which commit or pull request implemented it?
- Which tests qualified it?
- Which release deployed it, and where?
- Did the deployed outcome satisfy the issue's acceptance criteria?

Answering those questions is the agent-native advantage. It should extend the
compatible forge rather than replace its normal issue workflow.

## Product rules

### Keep one canonical work record

An issue is the canonical work record. A project item references the issue; it
does not copy its title, state, owner, or acceptance criteria into an
independent task. An agent job also references the issue; it does not become a
second issue tracker.

This rule prevents four statuses from disagreeing: issue state, project
status, agent job status, and deployment status. Each status has a distinct
meaning:

- Issue state answers whether the requested outcome remains open.
- Project status answers where the issue is in one planning workflow.
- Agent job status answers what one execution attempt is doing.
- Deployment status answers where one code revision is running.

### Keep GitHub's contract and improve the operation

Use GitHub-shaped resource names, paths, fields, and state values where the
compatibility plan commits to them. Use the denser, faster interaction model
described in the Linear/Circle design plan without changing payloads.

Do not add a custom issue priority field or encode priority in label names.
The current decision rejects both. Sequence work through project ordering,
project status, milestones, and explicit dependencies. Add native GitHub issue
types, sub-issues, and dependencies only when the local schema and API support
their GitHub-shaped representations.

Project fields are part of Projects V2 and may organize a view. Do not mirror
their values into invented issue fields. For the first complete board, store
only **Status** and derive the rest from standard issue fields:

- Repository from the issue relationship.
- Owner from assignees.
- Kind from labels until native issue types exist.
- Target date from the milestone.
- Open or closed from issue state and state reason.

### Keep the forge useful without agents

A person must be able to create, discuss, organize, and finish work through
the web and API without a chat or coding agent. Agents use the same API,
events, and authority checks as people. They must not receive privileged
database access.

### Make agent work legible

When an agent works on an issue, show a bounded activity record on the issue:

- The actor and requesting person.
- The durable job and conversation identifiers.
- The repository, branch, and requested working directory.
- The current state, start time, elapsed time, and terminal outcome.
- Links to the commits, test receipts, release, and deployment.
- A short report and a link to the fuller ATIF trace when policy allows it.

Apply the existing transparency level to every linked artifact. A public issue
must not make a private conversation, repository, log, or deployment receipt
public.

### Use the forge to build the forge

OpenAgents should track this program in OpenAgents, not in a private parallel
backlog. Public product outcomes belong on the public roadmap. Security,
embargoed, customer-specific, and private-repository work stays private but
uses the same model.

## Recommended projects

### OpenAgents public roadmap

Purpose: show users and contributors what outcomes OpenAgents intends to
deliver across the product.

Put one tracking issue on this board for each product outcome. Do not add every
implementation issue. The current cards about pull requests, notifications,
and PostHog are the right level, but each card needs an owner, target
milestone, acceptance criteria, and links to its implementation issues.

After C6 makes the board render its stored field, use these status options:

- **Backlog**: accepted, but not ready to start.
- **Ready**: scoped, unblocked, and eligible for assignment.
- **In progress**: someone or an agent is actively working on it.
- **In review**: implementation exists and needs review or qualification.
- **Blocked**: a named dependency prevents progress.
- **Done**: the outcome shipped and the tracking issue closed.

These values belong to the project's **Status** field. They do not replace the
issue's open or closed state.

Recommended views:

- **Roadmap**: board by **Status**, ordered by the desired sequence.
- **Now**: **Ready**, **In progress**, **In review**, and **Blocked**.
- **By repository**: grouped by the issue's repository.
- **Milestones**: grouped by milestone and due date.
- **Recently shipped**: closed as completed during the latest release window.

### Issues and Projects delivery

Purpose: manage the detailed implementation described in this assessment.

Add all server, web, API, migration, contract, test, and named CLI issues for
the Issues and Projects product. Group the work by tracking issue, not by
creating separate projects for each endpoint family.

Keep the CLI issues in this project so you can see the end-to-end outcome, but
assign them to the `openagents` monorepo. Assign server and web issues to
`OpenAgentsInc/openagents.com`. A project should span repositories even when
each issue stays owned by one repository.

### Agent work and provenance

Purpose: connect the tracker to chat and coding agents, changes, and releases.

This project owns issue-to-job linking, issue execution, agent activity,
trace policy, commit association, release receipts, and automation. Keep it
separate from the compatibility project because it can advance after the core
issue workflow works and because the core must remain useful when agents are
disabled.

## Recommended milestones

Use milestones for bounded delivery promises, not permanent categories.
Create these initial milestones after confirming deployment dates:

1. **Issues API correctness** closes the private-read, pagination, filter,
   error, origin, and contract defects.
2. **Projects foundation** makes project scope, visibility, fields, items, and
   board operations correct across repositories.
3. **CLI issue workflow** delivers the named commands already in flight and
   qualifies them against a deployed server.
4. **Public work system** makes the roadmap, notifications, mentions, saved
   views, and contribution flow usable by the public.
5. **Agent work receipts** links issues to jobs, conversations, commits,
   tests, releases, and deployments.

Do not create date-free milestones such as “Backlog.” The project status
already represents backlog position.

## Delivery tracks and candidate issues

The following identifiers are planning labels for this document, not issue
numbers. Create each item as an issue in the repository named in the
**Repository** column.

### Track A: Correct the API before adding clients

| ID | Repository | Issue | Completion signal |
| --- | --- | --- | --- |
| A1 | `openagents.com` | Let authenticated API readers see repositories they can read | The optional bearer pipeline widens private issue, comment, label, assignee, and milestone reads without changing anonymous public reads. |
| A2 | `openagents.com` | Add bounded issue API pagination and filters | The list route supports the web query's state, label, assignee, milestone, search, and page behavior with documented response metadata. |
| A3 | `openagents.com` | Resolve API URLs from the request origin | Staging responses never advertise production URLs, and proxy handling has tests. |
| A4 | `openagents.com` | Unify issue-family error envelopes | Validation and not-found responses preserve field detail and stable error codes without breaking measured clients. |
| A5 | `openagents.com` | Reconcile route authority with enforced pipelines | Every `/api/v3` route's principal and scope classification matches the plug that enforces it, and new routes cannot fall through a broad default. |
| A6 | `openagents.com` | Publish a complete derived API route inventory | CI derives the route list from the router and fails when the published contract omits a route. Response schemas may remain incremental and explicit. |
| A7 | `openagents` | Compare the CLI contract with the configured server | CLI verification fetches the published contract from staging and fails on divergence instead of hashing only its vendored copy. |

A1 is partially complete: optional-bearer issue reads shipped, while ancillary
comment, label, assignee, and milestone reads remain. A2 through A5 still
precede a stable named CLI release. A6 and A7 can follow after the routes stop
moving, but the route-coverage failure should land early.

### Track B: Complete the issue work record

| ID | Repository | Issue | Completion signal |
| --- | --- | --- | --- |
| B1 | `openagents.com` | Add native issue types | The schema, API, forms, filters, and projections support GitHub-shaped task, bug, and feature types without label conventions. |
| B2 | `openagents.com` | Add sub-issues and progress summaries | A tracking issue can order child issues and report total, completed, and percent complete without parsing Markdown checklists. |
| B3 | `openagents.com` | Add issue dependencies and related links | Issues can block, be blocked by, duplicate, or relate to another visible issue, with cycle and authorization checks. |
| B4 | `openagents.com` | Add an issue event timeline | State, title, labels, assignees, milestones, project membership, agent work, and releases produce actor-attributed events. |
| B5 | `openagents.com` | Add subscriptions, mentions, and notifications | A person can follow an issue, receive an in-product notification, mark it read, and control delivery preferences. |
| B6 | `openagents.com` | Add saved workspace issue views | A person can save filters over issues they can read without creating a second issue collection. |
| B7 | `openagents.com` | Add bulk triage | Authorized maintainers can change labels, assignees, milestones, and state across selected issues with one audited operation. |

B2 and B3 should use the GitHub-shaped fields already identified in the design
assessment. B5 should land before a public backlog grows beyond the current
manual triage loop.

### Track C: Turn Projects into an actual planning system

| ID | Repository | Issue | Completion signal |
| --- | --- | --- | --- |
| C1 | `openagents.com` | Replace the initial-repository project pin | User and organization project routes resolve the requested namespace and apply repository visibility to every item. |
| C2 | `openagents.com` | Define project ownership and cross-repository membership | A project can include visible issues from several repositories without weakening any repository's authority boundary. |
| C3 | `openagents.com` | Complete project lifecycle routes | Update, close, reopen, archive, and delete operations have explicit authority, API routes, tests, and audit events. |
| C4 | `openagents.com` | Validate project fields and values | Supported data types, option identifiers, unique names, and item values have database and application constraints. |
| C5 | `openagents.com` | Complete project item operations | Users can add, remove, move, and reorder items, and duplicate membership has a defined result. |
| C6 | `openagents.com` | Render boards from stored fields | The board uses the project's **Status** options instead of three hard-coded columns and supports keyboard and responsive operation. |
| C7 | `openagents.com` | Add table, board, and roadmap views | Each view is a projection over the same project items and fields, with saved sorting, grouping, and filtering. |
| C8 | `openagents.com` | Add project templates | A repository or organization can create a project with the standard **Status** field and recommended views without manual API calls. |
| C9 | `openagents.com` | Add public project reading | Anonymous users can read a project only when every exposed item and field is safe under the project's visibility policy. |
| C10 | `openagents.com` | Add project activity and live updates | Item and field changes update connected clients and record who changed what. |

C1 shipped through repository-scoped routes without reinterpreting existing
repository-local project numbers. C2 still requires a written ownership and
cross-repository membership decision.

### Track D: Finish the named CLI experience

The published `openagents` monorepo does not contain these named commands. Use
this list to coordinate with any active CLI task and avoid duplicate work.

| ID | Repository | Issue | Completion signal |
| --- | --- | --- | --- |
| D1 | `openagents` | Add `issue list` and `issue view` | Commands infer the repository, support JSON, and work for authorized private repositories after A1 and A2 deploy. |
| D2 | `openagents` | Add `issue create`, `edit`, `close`, and `reopen` | Commands support noninteractive use and editor-based bodies, and preserve state reasons. |
| D3 | `openagents` | Add issue comments, labels, assignees, and milestones | The common triage loop no longer requires raw API calls. |
| D4 | `openagents` | Add project list, view, item add, item move, and item remove | Commands target the corrected project model after C1 through C5 deploy. |
| D5 | `openagents` | Publish CLI end-to-end qualification | Tests run the packaged CLI against the exact staging server revision and cover public and private repositories. |

The generic `openagents api` command remains supported beside the named
commands. Do not generate the public command tree from OpenAPI. Generate a
typed client later if a derived, verified schema becomes accurate enough.

### Track E: Connect issues to agents and releases

| ID | Repository | Issue | Completion signal |
| --- | --- | --- | --- |
| E1 | `openagents.com` | Link issues and durable work jobs | One issue can reference several execution attempts, and each job records the issue and repository it was authorized to change. |
| E2 | `openagents.com` | Start agent work from an issue | An authorized person can request work with a bounded objective, repository, branch policy, budget, and executor. |
| E3 | `openagents.com` | Show live and completed agent activity on an issue | The issue page shows state, elapsed time, report, cancellation, and failure without exposing private logs. |
| E4 | `openagents.com` | Link work to commits and changes | A commit trailer or explicit API call associates a change with the issue and originating job without trusting free-form messages alone. |
| E5 | `openagents.com` | Link tests, releases, and deployments | The issue timeline shows qualification and environment receipts for the exact commit. |
| E6 | `openagents.com` | Add policy-controlled ATIF links | Public, member-only, and private traces follow one visibility decision and remain independently revocable. |
| E7 | `openagents.com` | Close work from verified outcomes | Automation may propose or perform closure only when policy allows it and the issue records the evidence used. |

E1 is the foundation. E2 through E7 must reuse the existing work-job,
conversation, authority, changelog, and receipt systems rather than adding a
new executor.

### Track F: Operate and measure the work system

| ID | Repository | Issue | Completion signal |
| --- | --- | --- | --- |
| F1 | `openagents.com` | Add work-system health metrics | You can measure time to first response, time in project status, blocked age, close rate, reopen rate, and agent success without storing issue content in analytics. |
| F2 | `openagents.com` | Add migration and rollback rehearsals | Project-scope, relation, and job-link migrations run against restored production data and preserve repository isolation. |
| F3 | `openagents.com` | Add staging browser qualification | Public, member, maintainer, CLI, board, notification, and agent-link flows pass against the exact candidate revision. |
| F4 | `openagents.com` | Add abuse and rate controls | Filing, commenting, mentions, notifications, and agent starts have bounded rates and auditable refusal reasons. |
| F5 | `openagents.com` | Publish the contribution workflow | The repository docs point contributors to the public roadmap, issue templates, local setup, acceptance criteria, and verification expectations. |

## Recommended sequence

### Phase 0: Coordinate work already in flight

1. Record the branch or task that owns the named CLI commands.
2. Keep `openagents api` as the immediate terminal path.
3. Keep the existing public roadmap, and create the two delivery projects and
   five milestones from this assessment.
4. Create one tracking issue for each delivery track, then create the first
   unblocked child issues.

### Phase 1: Make the current contract safe to build on

Complete the remaining A1 work and A2 through A5. C1 has shipped. This phase
finishes authorization, pagination, origins, errors, and route authority.
Deploy it before named CLI reads claim complete private-resource support.

### Phase 2: Complete core project operations

Complete C2 through C6. At the end of this phase, the public roadmap can use
stored project fields, move and remove items, and span the repositories that
build one OpenAgents outcome.

### Phase 3: Ship the daily issue workflow

Finish D1 through D3, B4, B5, and B7. A maintainer should be able to receive,
triage, discuss, assign, organize, and close work through the web or CLI and
receive notifications when attention is required.

### Phase 4: Add issue structure and project views

Complete B1 through B3, B6, and C7 through C10. Replace Markdown checklists
with native sub-issues as they become available. Add table and roadmap views
without creating new task records.

### Phase 5: Make agent work first class

Complete E1 through E7. Start with read-only linkage and activity. Add agent
starts and verified closure only after authority, visibility, cancellation,
and receipt behavior pass staging qualification.

### Phase 6: Harden and publish

Complete F1 through F5 and A6 through A7. Publish the contribution path, run
the exact-candidate staging flow, and promote only the server and CLI versions
that qualified together.

## Issue template for this program

Every implementation issue should contain these sections:

```md
## Outcome

Describe what a person or agent can do after this ships.

## Current behavior

Describe the measured behavior and link to code, tests, screenshots, or logs.

## Contract

List the affected web routes, API routes, schemas, events, and authority rules.

## Acceptance criteria

- State observable outcomes.
- Include public and private repository behavior where relevant.
- Include unauthorized behavior and error results.

## Verification

List focused tests, `mix precommit`, CLI checks, browser checks, migration
rehearsals, and staging evidence required for this issue.

## Dependencies

Link blocking and blocked issues. Do not encode dependencies in prose only.
```

Keep one issue owned by one repository. If an outcome needs changes in both
`openagents.com` and `openagents`, use a tracking issue with one server child
and one CLI child. Merge and deploy the additive server change first, then
release the CLI that consumes it.

## Definition of done

An issue is done only when all applicable conditions hold:

- The outcome and authority behavior have focused tests.
- Database constraints protect repository and owner boundaries.
- Public and private repository behavior is explicit.
- API responses have bounded pagination and stable error behavior.
- Web controls have keyboard, responsive, empty, loading, and error states.
- Agent-triggered work records the actor, authority, budget, and durable
  outcome.
- Documentation and the published contract match the deployed behavior.
- `mix precommit` passes in `openagents.com`; the relevant package checks pass
  in `openagents`.
- The exact candidate passes staging verification.
- The issue links to its commits, tests, release, and production deployment.

Closing an implementation issue when a branch exists is too early. Close it
when the agreed outcome is available in its target environment, or state in
the issue that merge rather than deployment defines completion.

## Decisions to preserve

- Keep GitHub-shaped contracts and a Linear/Circle-inspired interaction
  design.
- Do not add issue priority or priority-label conventions.
- Keep pull requests lower than a smooth issue workflow and allow a future
  per-repository pull-request switch.
- Keep repository authority at every API, query, event, and database boundary.
- Keep the base forge useful when agents are disabled.
- Let agents use explicit APIs, events, and jobs, never direct privileged
  database access.
- Keep `openagents api` beside named commands.
- Do not generate the public CLI command tree.
- Keep public development transparent while preserving private and embargoed
  data through the existing visibility policy.

## Questions to settle before implementation

1. Should Projects V2 become user- and organization-owned, with repository
   project URLs acting as filtered entry points, or should OpenAgents preserve
   repository-owned projects as a permanent extension?
2. Which existing project URLs and repository-local numbers must remain stable
   during that change?
3. Should issue list pagination use the repository API's cursor convention or
   expose the web query's bounded page convention?
4. Can list responses move toward GitHub's bare arrays, or do current clients
   depend on named envelopes?
5. Does OpenAgents add a read-only token scope before notifications and agent
   starts, or does `forge:write` remain the only API scope?
6. Which transparency level applies by default to issue-linked ATIF traces,
   work reports, logs, test receipts, and deployment receipts?
7. May a verified agent close an issue, or may it only propose closure for a
   person to confirm?

Answer these questions in decision records before migrations or public API
changes make the answers expensive to revise.

## Next actions

1. Finish issue 5 for bounded issue API pagination and filters.
2. Finish issue 6 for request-origin URLs and issue 7 for route-authority
   reconciliation.
3. Create a decision record for project ownership and cross-repository items
   before C2 changes the repository-local model.
4. Coordinate D1 through D5 with the active CLI owner, if one exists. Keep
   `openagents api` documented and supported until named commands qualify.
5. Add owners, milestones, acceptance criteria, and linked implementation
   issues to the current roadmap cards. Move them to the six-status workflow
   after C6 lands.
6. Add the issue-to-work-job relationship as a read-only link under issue 10.
7. Use these Issues and Projects records to track every later change in this
   plan.
