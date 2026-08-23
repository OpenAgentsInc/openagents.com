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
receipts. Always say which one when it matters.

### Turns and conversation

**Turn** — one user-to-assistant exchange: paired durable messages, tool
steps, provider steps, and an immutable provenance receipt
(`INVARIANTS.md`, TURN-001..005).

**Sarah** — a persona and behavior package inside OpenAgents, not a separate
service. Persona artifacts are pinned by SHA under `priv/sarah/persona/`.
Architecture forbids treating Sarah as a service boundary.

**Blueprint** — an immutable revisioned snapshot of typed platform facts that
inform Sarah's expression. It informs; it never grants capability or
authority.

**Memory planes** — account-scoped, consent-gated projections: conversation
recall (hybrid lexical + semantic), profile memory, learned preferences,
experience memory, graph memory. All disposable except the authoritative
messages and tool steps underneath them.

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
by a one-time import (`mix forum.import`). Browser reads and writes happen
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
6. **Module means two things.** Elixir module or module artifact — say which.
7. **An invariant is not true until its proof runs green.**
