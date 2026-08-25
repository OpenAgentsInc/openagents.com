# OpenAgents taxonomy and glossary

What each word means here, and which layer it belongs to.

This exists because the words collide. The forge and GitHub are both "the
remote", a push looks like a deployment, `machines.ex` sits beside a product
that says "computers", and a Box and a Computer both answer "which computer is
running this?" with different consequences. Each confusion costs time or,
worse, sends code to the wrong authority. A term is in this document when
getting it wrong has already cost something, or clearly will.

Read the layer diagram first. Most collisions are two layers using one word,
or two repositories using one name.

## The layers

```text
  browser
    │
    ▼
  Phoenix app ─────────── one public application: LiveViews, JSON APIs,
    │                     git plane, deployment plane
    ▼
  domain contexts ─────── accounts, turns, memory, issues/projects,
    │                     scv, work, repositories, forge…
    ▼
  PostgreSQL ──────────── the sole durable authority
```

Beside that stack, and often confused with it:

```text
  forge ───────── the canonical git remote at openagents.com
  github ──────── a read-only mirror, never authority
  box ─────────── a sandbox VM this application provisions, caps, and reclaims
  computer ────── someone's own machine, connected or absent, never provisioned
  receipt ─────── append-only durable evidence of something that happened
  trace ───────── public-safe ATIF projection of an agent session, not authority
  invariant ───── a contract in INVARIANTS.md with an executable proof
```

## Terms

### Forge and source control

**Forge** — the self-hosted Git remote at `openagents.com`, canonical source
control. Inside `OpenAgents.Forge` it has two separate planes:

- **Git plane** — authenticated Git traffic, repositories, push receipts,
  mirroring.
- **Deployment plane** — promote an exact SHA, build, deploy, record receipts.

The planes are deliberately separate. **A push never promotes itself.**

**WAL (durable push record)** — every accepted push is recorded durably in the
write-ahead log, and the site is served from that record. The WAL is object
storage, not PostgreSQL: `OpenAgents.Forge.WAL` holds one index document and a
set of content-addressed, chained entry objects per repository, and it is the
only ref authority. PostgreSQL holds projections of it — push receipts — never
refs. A push is a receipt, not a deployment.

**Repository name and storage key** — two strings for one repository, and never
interchangeable. The **name** is what a person has: `openagents.com`, or the
`owner/name` path they clone, which is what `OpenAgents.Forge.Repos.allowed_repos/0`
lists and what a build or deploy receipt records. It is unique only inside a
namespace. The **storage key** is `Repository.storage_key`: opaque, unique
across the forge, and the single path segment the WAL keeps a log under and a
node keeps a bare repository under. Say which one you mean, and resolve a name
with `OpenAgents.Forge.RepoRef` before it reaches a path — a name is a legal
path segment, so using one as a key silently builds a directory that projects
nothing, which is what issue #190 found on the live node.

**MirrorWatch** — the component that exports accepted `main` commits from the
forge to GitHub. GitHub is a mirror only; nothing on GitHub can affect what
the forge serves.

**Anchor** — the periodic published commitment to the WAL
(`OpenAgents.Forge.Anchor`, ADR 0008): one document per interval at
`/.well-known/openagents-forge-anchor.json` naming each public repository's
head chain link, chained to the anchor before it. An anchor is **not a
receipt** — it is evidence held by whoever kept a copy, never a record of what
happened to one party, and never ref authority. Say *published* when the
operator served it and *witnessed* when somebody outside the operator attests
to it; today the anchor is published and unwitnessed, and the two words are not
interchangeable.

**Push to the forge, never to GitHub:**

```sh
git push openagents HEAD:main
```

The `origin` remote is the GitHub mirror. Pushing there directly leaves the
forge behind a mirror it does not know about.
`ops/ci/push-remote-check.sh` refuses a non-forge push.

### GitHub-shaped API

**`/api/v1`** — a bounded, GitHub-shaped REST subset served by this
application: issues, comments, labels, assignees, milestones, and Projects V2
(`projectsV2`). It mimics GitHub REST shapes as a compatibility aid and
implements only a subset of the real API. Authorization here comes from API
tokens with scopes such as `forge:write`; path similarity to GitHub proves
nothing about authorization. **GitHub-shaped** is not **GitHub-compatible**:
the shape carries a client you configure with a base URL, and it does not
carry GitHub's `gh`, which is unsupported. `/api/v3` is a dated alias for
clients released before the rename, not a version this API claims. See
`docs/decisions/0009-serve-a-github-shaped-api-not-a-gh-compatible-one.md`.

**GitHub contexts (`OpenAgents.GitHub`, `github_oauth`)** — code that talks
*to* GitHub: OAuth identity, delegated repository access. Tokens are
encrypted server-side and never reach the browser. Do not confuse these with
the issue and project controllers, which serve the local forge.

### Receipts

**Receipt** — append-only durable evidence that something happened. The word
spans several families, each tied to its own invariants: turn receipts,
push receipts, build and deployment receipts, qualification receipts, consent
receipts, outcome receipts. *Checkpoint receipts are proposed and unclaimed; they would record
a thread's save point and its link to a forge commit.* Always say which one
when it matters. A thread transcript is not stored by pushing a metadata branch
to GitHub. The forge already hosts the Git; PostgreSQL already hosts the
evidence. A trace is a projection of that evidence, not a receipt.

**Outcome receipt** — the `module-outcome:v1:<digest>` reference a tool step
carries and `OpenAgents.Compensation` attributes against. It is one receipt
family among several. Do not read it as an accepted outcome.

**Qualification receipt** — a published check result bound to the exact commit
and artifact digest it examined, in `deployment_check_results`. It is the
qualification family an issue's evidence chain binds (`INVARIANTS.md`,
ISSUE-003), because it is repository-scoped and needs no priced claim behind
it. A settlement verification is a different record with a different authority:
it grades one claim at one commit and belongs to payout, not to an issue.

**Accepted outcome** — a graded verdict, not a receipt.
`OpenAgents.AcceptedOutcome` evaluates an agent's completion claim against
`priv/api-contracts/accepted-outcome-v1.json`: a scoped issue, a bound
attempt, an exact revision, an admitted verifier with a recorded falsifier,
and per-criterion evidence. It returns `:accepted`, `:incomplete`,
`:unauthorized`, `:failed`, or `:not_applicable`. The issue stays the
canonical work record; the contract only grades a claim about it.

**Completion claim** — the durable record of one graded verdict, stored in
`issue_completion_claims` by `OpenAgents.Issues.CompletionClaims`, keyed on
`{issue, attempt, revision}`. The accepted outcome is the grading; the claim is
what was graded and what happened next. Say "claim" for the record and
"accepted outcome" for the verdict.

**Verified close** — an issue closed from an accepted claim, attributed to
`system:accepted-outcome`. It is not a trailer close: a trailer close is a
person's assertion recorded in `issue_closing_references` with a
`closed_by_user_id` (`ISSUE-001`, `#130`). Both close an issue; only one names
a person, and only a verified close can be contradicted by a later receipt.

### Exports

Two account exports exist and they are not the same document. Say which one.

**Conversation export** — `sarah.account_data_export.v1`, served by
`GET /data/export` and built by `OpenAgents.DataRights.export/3`. Scoped to one
conversation: messages, profile memory, voice summaries, tool steps, and the
account chat backend's runs and events. `GET /data/export/atif` is the same
graph projected as one ATIF trajectory. Both are `DATA-004`.

**Account export** — `openagents.account_export.v1`, served by
`GET /data/export/account` and built by
`OpenAgents.DataRights.AccountExport.build/1`. Scoped to the account rather
than to a conversation: forum topics and posts, threads and their transcripts,
push receipts, deployment requests and approvals, Box leases and runs, paired
computers, and agent links. It is `EXIT-001`, and it names its own omissions in
a `not_included` section.

**Export ledger** — `OpenAgents.DataRights.ExportInventory`, the family-by-family
record of what leaves and what does not. A family is `portable` only with a
named mechanism and a named proof; `partial` and `blocked` each owe an open
issue. `EXIT-001` enforces it against the surface in both directions, so a
ledger entry is a claim under test rather than documentation.

### Traces

**ATIF** — Agent Trajectory Interchange Format, pinned at `ATIF-v1.7`. The
JSON interchange schema for logging an agent interaction as a sequence of
steps (user, agent, system), tool calls, observations, and metrics. The
canonical in-repo schema lives in `@openagentsinc/atif`. Harbor's RFC names
the root object a trajectory; OpenAgents product copy says trace.

**Trace** — the product object: a public-safe ATIF document of an agent
interaction, exportable and, when published, dereferenceable. This
application serves exactly one trace route: `GET /data/export/atif` builds
one ATIF document from the owner's conversation (messages, tool steps, turn
receipts).

The shareable trace store is an external surface, not part of this
application. The `/trace/{uuid}` viewer, `GET /api/traces/{uuid}`, and ingest
`POST /api/traces` belong to the TypeScript Cloudflare Worker in the
`OpenAgentsInc/openagents` monorepo, which no longer answers for this domain.
Both paths return `404` at `openagents.com`. Cite them as history or as
another repository's surface, never as a live route here. Their
`public` / `unlisted` / `owner_only` visibility vocabulary is not this
application's either: repository-side disclosure uses the four levels in
`OpenAgents.Transparency` and `OpenAgents.Forge.Visibility` — `dark`,
`pulse`, `ledger`, `glass`.

A trace is not authority: PostgreSQL turns, tool steps, and receipts remain
the source. A conversation is not a trace until it is exported. Changelog
rows may carry `trace_ref` and `trace_digest` pointers. Trace visibility
tiers shipped with issue #70. `ArtifactLink.artifact_types/0` gained a
`trace` member with issue #149, and nothing writes one: binding a trace to an
issue timeline (work-system E6, issue #10) is still unbuilt, and the
vocabulary admitting the word is not the same as a surface producing it.

**Disclosure schedule** — the field-by-field decision in
`OpenAgents.Transparency.WorkDisclosure` about which tier first exposes each
field of an attempt, a work job, or an evidence edge, and which columns no
tier exposes at all. It is not the *disclosure level*: a level
(`OpenAgents.Forge.Visibility`, `:l0`-`:l3`) is operator-owned per-repository
configuration that governs source and history, while a schedule is a
per-field rule about work in progress that the issue tracker's own
repository-readability gate does not settle. Say "level" for the dial and
"schedule" for the field rules. Both use the same four tier words.

**Thread visibility** — the third user of those four words, and the only one an
account sets for itself: `threads.visibility` is the tier that governs who may
read one thread's transcript (THREAD-002). Say "visibility" for the column and
"tier" for the value, the way an `ArtifactLink` carries a `tier`. It admits
`dark` (the default — the account that opened the thread and nobody else) and
`ledger` (any signed-in reader holding the thread id), and refuses `pulse` and
`glass`, which no thread read path implements. It is not a *level*: a level is
operator-owned per-repository configuration, while a thread's visibility is the
opener's own decision, recorded in the transcript as `thread.visibility_set`
when it widens.

**Trajectory** — the ATIF schema name for the document (`AtifTrajectory`,
`trajectory.json`, `trajectory_id`). Use it in schema and code. Product copy
says trace.

Do not confuse an agent trace with:

- **Decision Trace** — ProductSpec history of intent changes caused by
  evidence. Always say Decision Trace.
- **Chrome or SCV trace artifacts** — browser profiles and diagnostics, not
  agent trajectories.
- **qa-runner `session-trace.json`** — an internal Khala beat log that maps
  *into* ATIF. Not the product object.
- **Experience-memory `trace:v1:<digest>`** — a digest ref on a memory
  record, not `/trace/{uuid}`.

### Turns and conversation

**Turn** — one user-to-assistant exchange: paired durable messages, tool
steps, provider steps, and an immutable provenance receipt
(`INVARIANTS.md`, TURN-001..005). One execution of a coding agent inside a
session is a turn, not a separate "run" object.

**Token usage** — counts of input tokens, output tokens, cache-creation
tokens, cache reads, and API calls recorded on a turn or inference. Usage
is evidence on the receipt, not a substitute for the receipt.

**Visitor, not account** — two identifier spaces, and they are not
interchangeable. An **account** is a `users` row: the signed-in identity, a
GitHub id behind it, operator standing attached to it. A **visitor** is a
`visitors` row: who owns a conversation, and what every conversation-scoped
record points at. A signed-in account has exactly one visitor
(`unique_index(:visitors, [:user_id])`); an anonymous browser has a visitor and
no account. `OpenAgents.Tools.ExecutionContext` carries both, as
`owner_visitor_id` and `owner_user_id`, and neither is ever substituted for the
other. Passing an account id where a visitor id belongs produces a value that
looks right and resolves to nothing, so the failure surfaces far from its
cause: `OpenAgents.Tools.OwnerContext` reads back no row and reports
`owner_not_signed_in` to someone who is signed in (`INVARIANTS.md`, TOOL-005).
Resolve one from the other explicitly —
`OpenAgents.Conversations.get_conversation_owner!/1` — and never with a
fallback.

**Reach** — what a caller must already hold before a tool can succeed for
them, declared per tool as `reach:` on its specification and evaluated by
`OpenAgents.Tools.Reach`. Reach decides what the model is *offered*; scope,
authority, and surface admission decide what the host will *run*. A tool
outside the caller's reach is left out of the catalog rather than refused
after the model has already spent a turn on it. Reach is never authority: the
tool re-checks its own gate at execution.

**Sarah** — a persona and behavior package inside OpenAgents, not a separate
service. Persona artifacts are pinned by SHA under `priv/sarah/persona/`.
Architecture forbids treating Sarah as a service boundary.

**Blueprint** — an immutable revisioned snapshot of typed platform facts that
inform Sarah's expression. It informs; it never grants capability or
authority.

**Memory planes** — account-scoped, consent-gated projections: conversation
recall (hybrid lexical + semantic), profile memory, learned preferences,
experience memory, graph memory. All disposable except the authoritative
messages and tool steps underneath them. *Search over thread history
(checkpoints, trailers, and receipts) is proposed and unclaimed as a use of
these planes, not a second index.*

### Threads

A **thread** is the unit of agent work. Everything in this section describes a
thread, or the evidence a thread leaves behind.

The italicized terms are proposed and unclaimed: no issue on the tracker claims
them, so none has an owner, a date, or a plan. Treat them as reserved
vocabulary that stops two people inventing two words for the same thing, not as
a roadmap. Before building one, file the issue; when it ships, drop the italics
and cite the code.

**Thread** — a bounded body of agent work: one objective, its turns, its
transcript, and its budget. A thread is plural and disposable, and a user has
as many as they have pieces of work.

Say thread, and mean this one. Four other things in and around this product
have worn the word or its synonyms:

- A **conversation** is Sarah's, and there is exactly one per user (DATA-002),
  running as long as the account does. A thread is not a conversation and must
  not be stored in one.
- A **Phoenix session** and a **LiveView session** are transport. So is
  `terminal-session.ts` in the CLI, and so is a **voice session**.
- A forum **topic** is a series of posts. Prose sometimes calls one a thread;
  the schema, the routes, and the API all say topic, and so should you.
- `driver_thread_id` on an SCV run holds the *driver's* thread id — an opaque
  foreign identifier — not this record's.

The word follows Codex, whose app-server protocol is thread-first and is the
contract `OpenAgents.SCV.Executor.CodexAppServer` already speaks: `thread/start`,
`thread/turns/list`, `thread/status/changed`, and dozens more under `thread`.
Codex does use `session`, and for the other sense: its seven `session/*` methods
open, execute in, and terminate a shell. One protocol, both words, each for what
this glossary means by it. It also matches the containment this codebase already
has, because a thread holds turns exactly as a conversation does. ACP
calls the same concept a session on the wire, so `session/new` opens a thread's
ACP-side runtime; that is a mapping at one boundary, not a second name for the
record. Two executors already disagree about the word, so some mapping is
unavoidable, and the record takes the name that matches its shape.

The durable `threads` table exists. A thread is an account-scoped row owned by
the account's visitor root, carrying its objective, its admitted execution
shape, its status, its generation fence, its metered usage, and its terminal
report, with an append-only transcript in `thread_events`. Model authority
binds to it: an inference grant names a thread or a conversation, never both
and never neither (THREAD-001). The context is `OpenAgents.Threads`, the record
is `OpenAgents.Threads.Thread`, and the transcript entry is
`OpenAgents.Threads.Event`. A caller opens one with `POST /api/v1/threads`,
reads what it has spent with `GET /api/v1/threads/{thread_id}`, and revokes it
with `DELETE /api/v1/threads/{thread_id}`, all behind the `chat:account` scope
and served by `OpenAgentsWeb.ThreadController`. A thread opened with
`"lane": "local"` is transcript-only: its model is the vendor string a local
runtime serves, and it is never granted authority — the server records the run
without paying for it (THREAD-001, issue #243). The CLI that stops writing to
the conversation is still to come; see the audit in
`docs/2026-08-23-thread-primitive-audit.md`.

**Pricing basis** — one word saying whether a reported cost can be trusted, on
every catalog entry and every metered usage record (METER-001). `declared`
means the operator entered the provider's published rates and the figure is
billable. `provisional` means the deployment carries rates that were written to
make the system run, or rates whose table it can no longer dereference; the
figure is a working number and nothing bills from it. `unpriced` means there
are no rates at all. The authority is `OpenAgents.Inference.Pricing`, and every
record names its rate table in `pricing_id`.

**Unpriced** — the deployment does not know what a call cost. It is not the
same word as free, and it is never rendered as `$0.00`: an unpriced record
carries no `estimated_cost_microusd`, `OpenAgents.Threads.spend/1` reports a
null total and names the lanes that made it null, and the thread page shows the
word. `gpt-5.6-luna` is unpriced today, which is why the distinction is load
bearing rather than pedantic — it is the lane the coder runs on. Giving a lane
rates is an owner action, never an inference.

**Thread transcript** — the prompts, responses, tool activity, code changes,
and metadata that explain what happened in a thread. Authoritative copies live
in PostgreSQL (messages, tool steps, receipts), not on a Git branch. The
portable, redacted projection of that evidence is a trace.

**Nested thread** — *a child thread created when an agent spawns another agent
or subagent during the same body of work. Proposed as a first-class roster and
transcript link on the forge; do not flatten it into the parent turn.*

The remaining terms describe *why* a forge commit changed. The forge already
hosts Git, so there is no separate metadata remote and no metadata branch to
export to GitHub.

**Checkpoint** — *a save point in a thread, linked to a forge
commit when the work is committed. Persistent checkpoints are receipts in
PostgreSQL, not objects on a Git branch. Compact SCV checkpoints are
structured state (facts, evidence refs, decisions, remaining work), not a
transcript dump. Proposed as a named receipt family.*

**Checkpoint linking** — *the join from a forge commit to the checkpoint
and thread transcript behind it. Proposed. A commit trailer or an explicit
API write records the join; free-form commit messages are not the
authority.*

**Rewind** — *restoring the worktree to an earlier checkpoint during an
active thread. Proposed. Rewind is a local worktree operation; it is not
a forge reset and not a GitHub force-push.*

**Shadow branch** — *a temporary local Git branch that holds intra-thread
snapshots so rewind does not commit onto the working branch. Named with a
worktree identifier so concurrent worktrees do not collide. Never pushed
to the forge or to GitHub. Proposed.*

**Commit trailer** — structured metadata appended to a Git commit message.
Forge commit pages already display trailers, including an agent-thread
trailer when one produced the commit, and changelog entries can be sourced
from a trailer. *Trailers that carry a checkpoint identifier and line
attribution are proposed.*

**Line attribution** — *an inferred count of how many changed lines in a
commit were written by the agent and how many were written by a human,
recorded as a commit trailer. Proposed. The percentage is inferred from
diffs and hook timing, not from keystrokes, and is not proof of
authorship.*

**Dispatch** — *a markdown summary of recent agent work across one or more
repositories, branches, and time windows. Proposed. A dispatch is a
projection, not a receipt.*

**Skill** — *a reusable workflow that teaches a coding agent to search
thread history, explain a change from receipts, review a branch with
intent context, or hand off a thread. Proposed as a product surface.
Operator skill files under `.agents/skills/` are local tooling, not this
term.*

### Agents

**Agent** — three things wear this word, and only one of them is a principal.

- **Agent account** — a self-registered account with a handle, backed by
  `OpenAgents.Agents`. Its credentials are deliberately narrower than a human
  API token: it can join public conversations, but it never inherits human
  membership or operator authority. An owner grants it box or computer control
  per kind, and can revoke either.
- **Coding agent** — the program that edits code, such as the OpenCode harness
  a Box boots with. It runs inside a delegation target; it holds no account
  here.
- **ACP agent** — the `agent_id` a Computer's probe reports under `acp_agents`,
  naming which local agent a delegation should start. It identifies a program
  on someone's machine, not a principal.

`agent_version` on a computer record is the version of the paired controller,
not of any of these.

### Execution

**SCV** — the durable coding-execution and supervision contract: a driver
(OpenCode or a native Elixir loop), an environment, and a runner. The SCV owns
policy, lifecycle, budgets, and receipts. It is not a container and not a
model.

**Deployment control plane** — the tenant-facing plane where a repository
deploys its own commits to its own environments: environments, requests, runs,
checks, approvals, workflow grants, and append-only deployment events, backed by
`OpenAgents.Deployments` and served at `/api/v1` under `deployments:write`. It
is not the forge deployment plane. Promoting the OpenAgents release itself stays
operator-only behind `deployments:promote`, and no tenant route reaches it.
`docs/deployment-control-plane.md` describes the contract.

**Deployment request and deployment run** — a request is the recorded intent
(exact commit SHA, exact artifact digest, provenance, creator principal); a run
is the execution of one admitted request. A request that policy never admits has
no run.

**Deployment class** — how a promoted commit reaches the running fleet,
decided by a classifier rather than by operator preference. There are three: a
direct hot load of allowlisted BEAM-only changes, a relup for compatible
application-level changes, and a full image build with rolling replacement for
runtime or infrastructure changes. The classifier judges the
whole candidate and never hot-loads the eligible part of a mixed change; one
structural path refuses the entire direct transaction. `docs/deploymodes.md`
holds the allowlist and the conditions.

**Boot convergence** — `OpenAgents.Forge.BootConverge`: a restarted node
reconciles itself to the current promotion target before readiness admits it.
It is a guard, not a deployment class. It stops a restarted node from serving
an older target, and it promotes nothing.

**Work job (`work_jobs`)** — a durable, budgeted delegated job row backed by
`OpenAgents.Work`. Delegation, not execution. One table serves several kinds —
`deep_work`, `delegation`, `coding`, `scv`, and `continual_learning` — so a
work job is not automatically a `deep_work.v1` job. A Computer delegation is a
`work_jobs` row of kind `delegation`.

**Effect (`effects`)** — one thing a committed intent asked the system to do
outside its own transaction, recorded by `OpenAgents.Effects` in the same
transaction as the intent and delivered later under a lease. It is the durable
outbox, not a message and not a broadcast: a broadcast that nobody receives is
gone, while an effect that nobody ran is still owed. An effect's `claimed`
status means a worker said it would try; only `done` means it ran (EFFECT-002).

### Delegation targets

**Delegation** — one unit of work this application hands to a substrate it
does not run inline. `OpenAgents.Delegations` serves all of them at
`/api/v1/conversations/{conversation_id}/delegations`: one request shape, one
status read, one cancel, across every target kind. The facade stores no
delegation state. The Box run ledger and the `work_jobs` ledger stay
authoritative, and every projection is derived from them.

**Delegation target kind** — `box` or `computer`. The kind travels in the
identifier and is never inferred: a target is `box:{uuid}` or
`computer:{uuid}`, and a delegation is `box-run:{uuid}` or
`computer-job:{uuid}`. Authority is scoped per kind — the `box:control` and
`computer:control` token scopes for a signed-in owner, and a per-kind grant to
a named agent handle at `/api/v1/agents/{handle}/box-control` and
`/api/v1/agents/{handle}/computer-control`.

**Box** — a sandbox virtual machine this application rents from the Box Public
API v1 at `ascii.dev` and bootstraps with the OpenCode harness. A Box is
provisioned, disposable, and reclaimable: it belongs to exactly one
conversation, carries a TTL, and is admitted against a per-conversation active
cap, a per-owner cap, and a global cap before any provider call leaves the
host. A request for several Boxes becomes a fan-out admission plan whose items
are `admitted`, `queued`, or `refused`; a queued item is a logical Box that has
cost nothing and called nothing. Reconciliation can move a Box toward a
terminal state, but it never recreates one. `OpenAgents.Box` provisions and
reclaims; `OpenAgents.BoxRuns` owns the detach-and-poll runs. Ledgers:
`conversation_boxes`, `box_runs`, `box_fanout_requests`, `box_fanout_items`. A
Box is not a container image, not an SCV environment, and not a Computer.

**Computer** — someone's own machine, paired once through the CLI device flow
and reachable only while its controller holds the WebSocket. A Computer is
present or absent, never provisioned: it has no TTL, no admission plan, and
nothing can create one on demand. `online?` is a live reachability read, not a
state you can request. A delegation to a Computer becomes a `work_jobs` row of
kind `delegation` naming an ACP agent, a prompt, and a working directory the
owner already scoped.

The distinction decides what a failure means. A Box that is gone was reclaimed,
and you can provision another. A Computer that is gone is somebody's laptop,
and waiting is the only recovery.

**Computer, not machine** — "computer" is both the product word and the
current code word. `OpenAgents.Computer` owns live control,
`OpenAgents.ComputerAgentJobs` owns durable ACP delegations,
`OpenAgents.ComputerActivity` owns the streamed live projection, and
`OpenAgents.ComputerProjection` owns the safe read. `OpenAgents.Machines` still
owns what it always owned: the pairing flow and the credential record behind a
computer. Write new code as `computer`.

**Where `machine` stays, and why** — issue #134 settled this, and the answer
is a split with one rule:

> A `machine` name stays where something outside this release can observe or
> replay it. Everywhere else it becomes `computer`.

"Outside this release" has four concrete forms, and every retained `machine`
name is one of them:

1. **Rows an earlier release wrote.** Table, column, constraint, and index
   names; stored enum values; stored JSONB keys; stored receipt refs, incident
   codes, and policy ids. Renaming one is a migration and a backfill, and a
   partial backfill fails the constraint that reads it.
2. **A client this repository does not ship.** The controller CLI reads the
   protocol `openagents.computer.v1`; stored tool steps replay against the
   `.v1` tool schemas; anonymous callers read `/api/status`; deployment secrets
   carry `OPENAGENTS_MACHINE_TOKEN_TTL_SECONDS`.
3. **Another node during a hot upgrade.** PubSub topics, Horde registry keys,
   and cluster messages cross a version boundary mid-release, so a rename needs
   a dual-publish release before it needs an edit.
4. **A sealed ciphertext.** The AAD is bound into bytes already at rest.

A name that is none of those exists only in this release's source and process
memory. It moves. `GET /controller/status` declared the scope
`machine:status` while its siblings declared `computer:pairing:create`; no
token carries it and no published contract names it, so it is now
`computer:status`. The same reasoning removed the retired
`sarah.machine_token.v1` AAD: it looked like form 4, but nothing seals a
version-1 blob and a sealed pairing token lives at most ten minutes, so its
population was empty and a compatibility branch with no population is a claim
nothing tests.

The durable half of the exemption is a ledger, not a paragraph.
`OpenAgents.Vocabulary` enumerates every `machine`-named table, column,
constraint, and index, and `OpenAgents.VocabularyTest` derives the live set
from `information_schema` and `pg_catalog`. A migration cannot add a
`machine`-named durable surface without someone recording it and saying why.
`INVARIANTS.md`, CANON-002.

The wire half has no query to enumerate it, so it is listed here and held by
its own contracts:

- `/machines`, a permanent redirect to `/computers`.
- The `machine:{id}` PubSub topic, the `{:machine, id}` Horde registry key,
  the `{:machine_updated, …}` / `{:machine_revoked, …}` /
  `{:machine_token_expired, …}` cluster messages, and the
  `controller_socket:{machine_id}` socket id.
- The `machine:{id}` receipt ref that tool steps carry and
  `OpenAgents.Compensation` attributes against.
- The channel refusals `machine_unavailable`, `machine_mismatch`, and
  `machine_reconnecting`, and the reply key `machine` in the controller
  protocol `openagents.computer.v1`, which a separately released CLI reads.
- The `machine_id` and `machine_name` properties of the `.v1` tool schemas
  (`computer_run.v1`, `computer_agent.v1`, and their siblings), because stored
  tool steps still replay against them, and the `machines` array key of
  `computer_list.v1`.
- The response keys `machine_id` and `machine_name` on
  `GET /api/v1/computer-agent-jobs/{id}`, the assignment projection, and
  `GET /controller/pairings/{id}`; and `counts.machines_connected` in
  `GET /api/status`, which `STATUS-001` pins as an exact published key.
- The `work_jobs` JSONB keys `delegation->>'machine_id'`,
  `delegation->>'machine_name'`, `authority_snapshot->>'machine_tier'`, and
  `authority_snapshot->>'machine_name'`, which the check constraint
  `work_jobs_delegation_identity` and the trigger function
  `enforce_work_job_scope` cross-check against each other and the `machines`
  row.
- The persisted incident codes `machine_offline`, `machine_not_found`,
  `ambiguous_machine`, `machine_disconnected`, `machine_timeout`, and
  `machine_revoked`, which `OpenAgents.Incidents.Triage` classifies from stored
  rows: a rename would reclassify every historical row as `anomalous`.
- The stored `staging_disposable_resources.kind` value `machine`, and the
  audit action `repository.machine_grant.updated` with subject
  `machine_grant`.
- The `audit_events.actor_type` value `machine`. A paired computer that
  authenticates to the Git plane with its `smct_` token pushes and fetches
  under `{:machine, id}`, so the value is written, not vestigial.
  `OpenAgents.Forge.GitHTTP.audit_actor_kinds/0` names the principal kinds that
  can reach it, and `OpenAgents.AuditTest` asserts every one of them is an
  actor kind `OpenAgents.Audit` accepts — a containment a reading of the call
  sites cannot establish, because the actor there is a variable.
- The module residency `operator_machine` and the routing-policy id
  `sarah.routing.policy.paired-machine.v1`. The residency reaches
  `artifact.facets` and so the `artifact_digest` and `registry_digest` a route
  receipt stores; the policy id and the `allowed_residencies` that admit it are
  both inside `policy_digest`. Renaming either makes a stored
  `module_route_receipts` row fail to reproduce. The neighbouring
  `policy_facets` consent, by contrast, is shape-checked and never digested,
  which is why it is now `computer_pairing`.
- The `Machines.TokenVault` AAD `openagents.machine_token.v2`, bound into
  ciphertext at rest.
- `OPENAGENTS_MACHINE_TOKEN_TTL_SECONDS` and the setting key
  `:machine_token_ttl_seconds`, which live in staging and production secrets.

**`machine` also means machine-readable** — and that sense is correct, not
residue. `GET /api/v1` publishes `contribution.machine`, and `/agents.json`
publishes `representations.machine`, each paired with `human` and each naming a
format rather than a device. Do not sweep these into a computer rename; they
are not about computers at all.

The channel topic is already `computer:{machine_id}` and the wire protocol is
already `openagents.computer.v1`. Check which side of the rule a `machine`
string is on before you rename it.

### Issues and projects

**Issues work system** — first-party issues, labels, milestones, assignees,
and projects shaped like GitHub's Projects V2, backed by `OpenAgents.Issues`
and sibling contexts, served at `/api/v1`. Tests are the contract; the
assessment document `docs/github-api-issues-projects-assessment.md` is the
source of truth for paths and JSON shape.

**Effect CLI** — the TypeScript CLI (`@openagentsinc/cli`) that calls this
surface via `openagents api`.

### Notifications

**Category** — what an account hears about: `mentions`, `issue_comments`,
`assignments`, `issue_activity`, `label_changes`. Each names what it delivers,
so switching one off has an effect you can predict from its name.

**Channel** — where it hears about it. Two: the in-product inbox, which has no
switch because it is the surface itself, and email, which has `email_enabled`
and defaults off. Say category for what and channel for where; a list that
mixes them lets a rename move an account from one answer to the other.
`OpenAgents.Notifications.Preference` keeps the two apart and `switches/0` is
the union.

**Confirmed address** — an address an account typed into its notification
settings and proved by returning a code mailed to it.
`OpenAgents.Notifications.EmailChannel.verified_address/1` is the only read a
send resolves a recipient through, so an address that is merely recorded
reaches nothing. Say confirmed, not verified, of the address; `verified_at` is
the column and confirming is what a person does.

**Delivery** — one queued outbound message,
`OpenAgents.Notifications.Delivery`, carried as an `email.delivery` effect in
the durable outbox. It is not the notification record, which is written in the
transaction and needs no queue, and it is not the message, which is
`OpenAgents.Notifications.Email`.

### Pull requests and stacks

**Pull request** — a repository-scoped proposal to merge one hosted branch
into another, backed by an issue. The issue supplies the number, title, body,
author, comments, and open or closed state; `OpenAgents.PullRequests` adds the
head repository, the head and base refs, and the SHAs they resolved to. A pull
request and an issue therefore share one number space, which is why the issue
surfaces still list both — issue #120 is open against exactly that. New
repositories allow pull requests; `OpenAgentsInc/openagents.com` starts with
them disabled.

**Stack** — a first-class server-side object, not a branch shape. A stack is an
ordered list of pull request entries with stored commit boundaries: the bottom
entry targets the trunk, and each later entry targets the head branch of the
entry below it. Branch topology alone stays ambiguous, so the stack row is the
identity. `OpenAgents.Stacks` caps a stack at 100 active entries, and
`docs/stacked-prs.md` is the design.

**Stack state and stack health** — two words for two different things. State is
the stack's own lifecycle: `open`, `completed`, `dissolved`. Health describes
the current Git graph: `healthy`, `needs_rebase`, `conflicted`, `missing_ref`,
`head_changed`, `policy_blocked`, `operation_in_progress`. A stale graph
records unhealthy; it never dissolves a stack.

**Stack operations** — `append` adds a layer, `unstack` releases one entry,
`dissolve` releases every entry at once (and an emptied stack dissolves on its
own), `rebase` restacks the chain, and `merge` merges. Merging is asynchronous:
a submit returns a durable operation id you poll, a repeated idempotency key
answers `409` rather than merging twice, and policy is evaluated at execution
rather than at submission.

**Contiguous-prefix merge** — selecting one pull request merges it and every
open layer below it in a single durable operation, then restacks the layers
above onto the result. The merge result and every restack build as unreachable
candidates and land through one batch compare-and-swap, so the trunk and the
restacked branches move together. `partially_succeeded` is what a worker
records when it reclaims a crashed operation and finds the refs diverged from
the plan; it is not a routine outcome and not a request you can make.

### Forum

**Forum** — the first-party discussion surface at `/forum`: boards, topics,
and posts backed by `OpenAgents.Forum`, ported from the legacy Effect forum
by a one-time import (`mix openagents.forum.import`). Browser reads are public,
as are the `/api/v1/forum` reads; writing a topic or a post, and claiming a
legacy identity, need an account. Legacy post permalinks at
`/forum/post/:postId` and a legacy `/forum/topic/:topicId` alias redirect to
the canonical topic through `OpenAgentsWeb.LegacyForumController`.
`docs/forum-port.md` describes the port; `docs/evidence/forum-port-migration.md`
records the import.

**Legacy identity (`actor_ref`)** — the actor reference a migrated forum post
was written under, such as `agent:user_0123abcd-…`. Migrated posts keep their
legacy references and display names; posts written on this surface use
`user:<account-id>`.

**Identity claim (actor link)** — a `forum_actor_links` row binding an
account to a legacy identity. A claim starts `pending` at `/forum/claim`; an
operator moves it to `linked` or `rejected` at `/admin/forum/claims`. Only a
`linked` claim resolves a legacy post to an account.

### Programs and modules

**Program artifact** — a model program stored as immutable digest-pinned data,
promoted offline with human approval. Shadow runs have no live effect.

**Module artifact** — an admitted, digest-pinned capability module
(`openagents.module_artifact.v1`). Not an Elixir module. Both words appear in
the codebase; say which one you mean.

### Outside systems

**Ox Alpha** — a third-party stealth model. It is not an OpenAgents release, a
milestone, or a subsystem. Providers publish it under different slugs:
`stealth/ox-alpha` on OpenRouter and Nous Portal, `stealth-ox-alpha` on Venice,
`x-preview-f-free` on OpenCode Zen. It is the default backend a chat turn uses
and the only one a Box boots OpenCode against (`openrouter/stealth/ox-alpha`).
A turn fails rather than silently answering as another model: naming a backend
is explicit, and an unsupported name is refused. Ox Alpha is the model,
OpenRouter is the gateway, and a Box is the machine it runs on. The "Ox
Alpha stress fleet" is the work program that burns the free capacity, not the
model. `docs/2026-08-23-ox-alpha-provider-limits.md` records the measured
limits and the date of measurement; provider quotas move without notice.

**Backend** — one model and the adapter that reaches it, named by a stable id
a client sends and a label a person reads. `OpenAgents.Chat.Backends` is the
single list; `GET /api/v1` publishes the ids so a client discovers the set
instead of hardcoding it. Say backend for the choice and model for the thing
chosen: Ox Alpha and Gemini 3.7 Flash are models, and each is reached through
one backend. A backend is not a provider — OpenRouter and Google are
providers, and a provider can serve more than one backend.

**Khala** — OpenAgents' OpenAI-compatible collective-intelligence endpoint,
built in the separate `OpenAgentsInc/openagents` monorepo. Nothing here
implements it, serves it, or depends on it. Bare "Khala" always means that
endpoint. Three near-names are not it:

- **Khala Sync** — the replication engine, always two words. Its
  `khala_sync_prod` database is what `mix openagents.forum.import` read once
  during the forum port. Nothing reads it now.
- **Khala Code** — folded into OpenAgents Desktop; not a current product.
- **Khala CLI** — retired.

**The `OpenAgentsInc/openagents` monorepo** — a different repository from this
one, and the source of most path confusion in these docs. It holds Khala, Khala
Sync, Pylon, `qa-runner`, and the TypeScript Cloudflare Worker that used to
answer for this domain. It also contains a directory named `apps/openagents.com`
that is not this application. Before calling a cited path stale, check whether
it lives there.

### Invariants and decisions

**Invariant** — a contract recorded in `INVARIANTS.md` with an ID (for
example `DATA-001`) and a named executable proof, verified by
`ops/ci/docs-check.exs`. Unlike omega's deltas, these are not forks from
upstream; they are first-party contracts. An invariant without a passing
proof is a wish.

**ADR** — a decision record in `docs/decisions/` (`0001` through `0007`).

### UI system

**Basecoat** — vendored component CSS in `assets/vendor/basecoat/components/`.
Import components individually; never import a bundle.

**OpenAgents style pack** — `assets/css/openagents.css`: identity tokens,
motion, radius, color. Must be the last import so its declarations win.

**`OpenAgentsWeb.UI`** — the 31 HEEx primitives (`button/1`, `card/1`, …).
Variants are data attributes (`data-variant="primary"`), not classes. There
is exactly one component system; adding a second is forbidden.

## Naming rules

1. **Say which remote.** Forge = authority, GitHub = mirror. Never bare "the
   repo" where both could apply.
2. **A push is not a deploy.** Promotion requires an operator-authorized
   target; no Git event promotes anything.
3. **GitHub-shaped is not GitHub.** Say "the `/api/v1` surface" or "GitHub"
   depending on which server answers.
4. **Computer, not machine.** Product copy and new code both say `computer`.
   A `machine` name stays only where something outside this release can observe
   or replay it — a stored row, a client this repository does not ship, another
   node mid-upgrade, or a sealed ciphertext. The durable half is enumerated in
   `OpenAgents.Vocabulary` (CANON-002); the wire half is listed under
   **Where `machine` stays, and why**. `machine` in `contribution.machine`
   means machine-readable and is a different word.
5. **Name the receipt.** Turn, push, build, deployment, consent, outcome.
   When checkpoints exist, they are a receipt family, not a Git branch. An
   anchor is not a receipt.
6. **Module means two things.** Elixir module or module artifact — say which.
7. **An invariant is not true until its proof runs green.**
8. **Agent work is a thread.** A thread is not Sarah's one conversation
   (DATA-002), not a Phoenix or voice session, and not a forum topic. Thread
   transcripts belong in PostgreSQL, not on a ref the GitHub mirror would
   export. ACP says session on the wire; the record is still a thread.
9. **Say which trace.** An agent trace is an ATIF document. A Decision Trace
   is ProductSpec history. A Chrome trace is a profile artifact. A trace is
   not a receipt and not a thread.
10. **Say which delegation target.** A Box is provisioned, capped, and
    reclaimed. A Computer is someone's machine, present or absent. The kind
    travels in the identifier, so never write a bare target id.
11. **A stack is an object, not a branch shape.** State is its lifecycle;
    health is the current Git graph. They disagree on purpose.
12. **Ox Alpha is a model; Khala is another repository's endpoint.** Neither
    one names anything this application owns.
13. **Say which repository.** This one, or the `OpenAgentsInc/openagents`
    monorepo that shares the product name and a directory called
    `apps/openagents.com`.
14. **Proposed means unclaimed.** An italic term in this document has no owner
    and no issue. Do not cite one as a plan.
15. **Published is not witnessed.** A surface the operator serves is published.
    Witnessed means a party outside the operator attests to it. Never write
    "anchored" where only the first holds.

## Proof

`ops/ci/docs-check.exs` resolves every module name and repository path this
document sets in code font against the checkout, and `mix precommit` runs it.
A term whose code moved fails the check instead of quietly becoming a wrong
answer. The check proves that those names still exist, not that the
definitions around them are still right. Rule 7 still needs a reader.
