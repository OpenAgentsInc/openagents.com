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

**WAL (durable push record)** — every accepted push is recorded durably in
PostgreSQL, and the site is served from that record. A push is a receipt, not
a deployment.

**MirrorWatch** — the component that exports accepted `main` commits from the
forge to GitHub. GitHub is a mirror only; nothing on GitHub can affect what
the forge serves.

**Push to the forge, never to GitHub:**

```sh
git push openagents HEAD:main
```

The `origin` remote is the GitHub mirror. Pushing there directly leaves the
forge behind a mirror it does not know about.
`ops/ci/push-remote-check.sh` refuses a non-forge push.

### GitHub-shaped API

**`/api/v3`** — a bounded, GitHub-shaped REST subset served by this
application: issues, comments, labels, assignees, milestones, and Projects V2
(`projectsV2`). It mimics GitHub REST shapes as a compatibility aid and
implements only a subset of the real API. Authorization here comes from API
tokens with scopes such as `forge:write`; path similarity to GitHub proves
nothing about authorization.

**GitHub contexts (`OpenAgents.GitHub`, `github_oauth`)** — code that talks
*to* GitHub: OAuth identity, delegated repository access. Tokens are
encrypted server-side and never reach the browser. Do not confuse these with
the issue and project controllers, which serve the local forge.

### Receipts

**Receipt** — append-only durable evidence that something happened. The word
spans several families, each tied to its own invariants: turn receipts,
push receipts, build and deployment receipts, consent receipts, outcome
receipts. *Checkpoint receipts are proposed and unclaimed; they would record
a thread's save point and its link to a forge commit.* Always say which one
when it matters. A thread transcript is not stored by pushing a metadata branch
to GitHub. The forge already hosts the Git; PostgreSQL already hosts the
evidence. A trace is a projection of that evidence, not a receipt.

**Outcome receipt** — the `module-outcome:v1:<digest>` reference a tool step
carries and `OpenAgents.Compensation` attributes against. It is one receipt
family among several. Do not read it as an accepted outcome.

**Accepted outcome** — a graded verdict, not a receipt.
`OpenAgents.AcceptedOutcome` evaluates an agent's completion claim against
`priv/api-contracts/accepted-outcome-v1.json`: a scoped issue, a bound
attempt, an exact revision, an admitted verifier with a recorded falsifier,
and per-criterion evidence. It returns `:accepted`, `:incomplete`,
`:unauthorized`, `:failed`, or `:not_applicable`. The issue stays the
canonical work record; the contract only grades a claim about it.

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
tiers shipped with issue #70; binding a trace to an issue timeline
(work-system E6, issue #10) has not.

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
`OpenAgents.Threads.Event`. The route that opens a thread for a caller, and the
CLI that stops writing to the conversation, are still to come; see the audit in
`docs/2026-08-23-thread-primitive-audit.md`.

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
`OpenAgents.Deployments` and served at `/api/v3` under `deployments:write`. It
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

### Delegation targets

**Delegation** — one unit of work this application hands to a substrate it
does not run inline. `OpenAgents.Delegations` serves all of them at
`/api/v3/conversations/{conversation_id}/delegations`: one request shape, one
status read, one cancel, across every target kind. The facade stores no
delegation state. The Box run ledger and the `work_jobs` ledger stay
authoritative, and every projection is derived from them.

**Delegation target kind** — `box` or `computer`. The kind travels in the
identifier and is never inferred: a target is `box:{uuid}` or
`computer:{uuid}`, and a delegation is `box-run:{uuid}` or
`computer-job:{uuid}`. Authority is scoped per kind — the `box:control` and
`computer:control` token scopes for a signed-in owner, and a per-kind grant to
a named agent handle at `/api/v3/agents/{handle}/box-control` and
`/api/v3/agents/{handle}/computer-control`.

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
computer. A rename pass is closing the remaining gap, so write new code as
`computer`.

These `machine` surfaces stay, because renaming one breaks a client or a
database rather than a name:

- `/machines`, a permanent redirect to `/computers`.
- The `machines` and `machine_pairings` tables.
- The `machine:{id}` PubSub topic and the matching `machine:{id}` receipt ref.
- The `controller_socket:{machine_id}` socket id.
- The channel refusals `machine_unavailable`, `machine_mismatch`, and
  `machine_reconnecting`, and the reply key `machine` in the controller
  protocol `openagents.computer.v1`, which a separately released CLI reads.
- The `machine_id` and `machine_name` properties of the `.v1` tool schemas
  (`computer_run.v1`, `computer_agent.v1`, and their siblings), because stored
  tool steps still replay against them.
- The `work_jobs` JSONB keys `delegation->>'machine_id'` and
  `authority_snapshot->>'machine_tier'`, which a check constraint and two
  triggers cross-check against the `machines` row.
- The `Machines.TokenVault` AAD `openagents.machine_token.v2`. Changing it
  makes every sealed pending pairing token undecryptable, so it can only gain
  a legacy entry, never a new name.

That list is the current partial answer, not a policy. #134 settles whether
the persistence and wire surfaces are renamed, kept, or split, and this entry
follows whatever it decides.

The channel topic is already `computer:{machine_id}` and the wire protocol is
already `openagents.computer.v1`. Check which list a `machine` string is on
before you rename it.

### Issues and projects

**Issues work system** — first-party issues, labels, milestones, assignees,
and projects shaped like GitHub's Projects V2, backed by `OpenAgents.Issues`
and sibling contexts, served at `/api/v3`. Tests are the contract; the
assessment document `docs/github-api-issues-projects-assessment.md` is the
source of truth for paths and JSON shape.

**Effect CLI** — the TypeScript CLI (`@openagentsinc/cli`) that calls this
surface via `openagents api`.

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
as are the `/api/v3/forum` reads; writing a topic or a post, and claiming a
legacy identity, need an account. `docs/forum-port.md` describes the port;
`docs/evidence/forum-port-migration.md` records the import.

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
single list; `GET /api/v3` publishes the ids so a client discovers the set
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
3. **GitHub-shaped is not GitHub.** Say "the `/api/v3` surface" or "GitHub"
   depending on which server answers.
4. **Computer, not machine.** Product copy and new code both say `computer`.
   The `machine` names that remain are wire, table, and route identity, and
   renaming one breaks a client.
5. **Name the receipt.** Turn, push, build, deployment, consent, outcome.
   When checkpoints exist, they are a receipt family, not a Git branch.
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

## Proof

`ops/ci/docs-check.exs` resolves every module name and repository path this
document sets in code font against the checkout, and `mix precommit` runs it.
A term whose code moved fails the check instead of quietly becoming a wrong
answer. The check proves that those names still exist, not that the
definitions around them are still right. Rule 7 still needs a reader.
