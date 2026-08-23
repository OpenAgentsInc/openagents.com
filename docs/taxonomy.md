# OpenAgents taxonomy and glossary

What each word means here, and which layer it belongs to.

This exists because the words collide. The forge and GitHub are both "the
remote", a push looks like a deployment, and `machines.ex` sits beside a
product that says "computers". Each confusion costs time or, worse, sends code
to the wrong authority. A term is in this document when getting it wrong has
already cost something, or clearly will.

Read the layer diagram first. Most collisions are two layers using one word.

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
receipts. *Checkpoint receipts are proposed; they record a session save
point and its link to a forge commit.* Always say which one when it
matters. Session context is not stored by pushing a metadata branch to
GitHub. The forge already hosts the Git; PostgreSQL already hosts the
evidence. A trace is a projection of that evidence, not a receipt.

### Traces

**ATIF** — Agent Trajectory Interchange Format, pinned at `ATIF-v1.7`. The
JSON interchange schema for logging an agent interaction as a sequence of
steps (user, agent, system), tool calls, observations, and metrics. The
canonical in-repo schema lives in `@openagentsinc/atif`. Harbor's RFC names
the root object a trajectory; OpenAgents product copy says trace.

**Trace** — the product object: a public-safe ATIF document of an agent
interaction, visibility-gated (`public`, `unlisted`, or `owner_only`),
exportable and, when published, dereferenceable. Sarah's
`GET /data/export/atif` builds one ATIF document from the owner's
conversation (messages, tool steps, turn receipts). The shareable store and
`/trace/{uuid}` viewer live on the Node web app (`GET /api/traces/{uuid}`,
ingest `POST /api/traces`). A trace is not authority: PostgreSQL turns, tool
steps, and receipts remain the source. A conversation is not a trace until
it is exported or ingested. Changelog rows may carry `trace_ref` /
`trace_digest` pointers. *Issue-linked traces (work-system E6) are
proposed.*

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

**Sarah** — a persona and behavior package inside OpenAgents, not a separate
service. Persona artifacts are pinned by SHA under `priv/sarah/persona/`.
Architecture forbids treating Sarah as a service boundary.

**Blueprint** — an immutable revisioned snapshot of typed platform facts that
inform Sarah's expression. It informs; it never grants capability or
authority.

**Memory planes** — account-scoped, consent-gated projections: conversation
recall (hybrid lexical + semantic), profile memory, learned preferences,
experience memory, graph memory. All disposable except the authoritative
messages and tool steps underneath them. *Search over coding-agent session
history (checkpoints, trailers, and receipts) is proposed as a use of these
planes, not a second index.*

### Coding-agent sessions

These terms describe *why* a forge commit changed. Evidence lives in
PostgreSQL receipts. The portable, redacted projection of that evidence is a
trace. The forge already hosts Git, so there is no separate metadata remote
and no metadata branch to export to GitHub.

**Coding-agent session** — *a complete interaction with a coding agent from
start to finish: prompts, responses, tool steps, code changes, checkpoints,
token usage, and line attribution. Distinct from a Phoenix or LiveView
session. Spans one or more turns. Proposed as a named product unit; today
the durable pieces are turns, work jobs, and SCV runs.*

**Session context** — the prompts, responses, tool activity, code changes,
and metadata that explain what happened during a coding-agent session.
Authoritative copies live in PostgreSQL (messages, tool steps, receipts),
not on a Git branch.

**Nested session** — *a child session created when an agent spawns another
agent or subagent during the same body of work. Proposed as a first-class
roster and transcript link on the forge; do not flatten it into the parent
turn.*

**Checkpoint** — *a save point in a coding-agent session, linked to a forge
commit when the work is committed. Persistent checkpoints are receipts in
PostgreSQL, not objects on a Git branch. Compact SCV checkpoints are
structured state (facts, evidence refs, decisions, remaining work), not a
transcript dump. Proposed as a named receipt family.*

**Checkpoint linking** — *the join from a forge commit to the checkpoint
and session context behind it. Proposed. A commit trailer or an explicit
API write records the join; free-form commit messages are not the
authority.*

**Rewind** — *restoring the worktree to an earlier checkpoint during an
active session. Proposed. Rewind is a local worktree operation; it is not
a forge reset and not a GitHub force-push.*

**Shadow branch** — *a temporary local Git branch that holds intra-session
snapshots so rewind does not commit onto the working branch. Named with a
worktree identifier so concurrent worktrees do not collide. Never pushed
to the forge or to GitHub. Proposed.*

**Commit trailer** — structured metadata appended to a Git commit message.
Forge commit pages already display trailers, including an agent-session
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
session history, explain a change from receipts, review a branch with
intent context, or hand off a session. Proposed as a product surface.
Operator skill files under `.agents/skills/` are local tooling, not this
term.*

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

**Work job (`work_jobs`)** — a durable, budgeted delegated job row started by
`deep_work.v1`. Delegation, not execution.

**Computers** — paired machine credentials used for agent jobs. This is the
current product vocabulary. `/machines` is a permanent legacy redirect, and
the `machines.ex` context still carries the old name in code. Say
"computer" in product copy; expect `machine` in module names.

### Issues and projects

**Issues work system** — first-party issues, labels, milestones, assignees,
and projects shaped like GitHub's Projects V2, backed by `OpenAgents.Issues`
and sibling contexts, served at `/api/v3`. Tests are the contract; the
assessment document `docs/github-api-issues-projects-assessment.md` is the
source of truth for paths and JSON shape.

**Effect CLI** — the TypeScript CLI (`@openagentsinc/cli`) that calls this
surface via `openagents api`.

### Forum

**Forum** — the first-party discussion surface at `/forum`: boards, topics,
and posts backed by `OpenAgents.Forum`, ported from the legacy Effect forum
by a one-time import (`mix openagents.forum.import`). Browser reads and writes happen
signed in; the `/api/v3/forum` reads are public. `docs/forum-port.md`
describes the port; `docs/evidence/forum-port-migration.md` records the
import.

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

**`OpenAgentsWeb.UI`** — the ~22 HEEx primitives (`button/1`, `card/1`, …).
Variants are data attributes (`data-variant="primary"`), not classes. There
is exactly one component system; adding a second is forbidden.

## Naming rules

1. **Say which remote.** Forge = authority, GitHub = mirror. Never bare "the
   repo" where both could apply.
2. **A push is not a deploy.** Promotion requires an operator-authorized
   target; no Git event promotes anything.
3. **GitHub-shaped is not GitHub.** Say "the `/api/v3` surface" or "GitHub"
   depending on which server answers.
4. **Computer, not machine**, in product copy — even though the code still
   says `machine`.
5. **Name the receipt.** Turn, push, build, deployment, consent, outcome.
   When checkpoints exist, they are a receipt family, not a Git branch.
6. **Module means two things.** Elixir module or module artifact — say which.
7. **An invariant is not true until its proof runs green.**
8. **Say which session.** A coding-agent session is not a Phoenix session.
   Session transcripts belong in PostgreSQL, not on a ref the GitHub mirror
   would export.
9. **Say which trace.** An agent trace is an ATIF document. A Decision Trace
   is ProductSpec history. A Chrome trace is a profile artifact. A trace is
   not a receipt and not a coding-agent session.
