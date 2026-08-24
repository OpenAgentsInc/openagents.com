# From local-first coder to an account-shaped one

**Date:** 2026-08-24
**Commit measured:** `a9a251e` on `openagents/main` (the forge), with the CLI at
`94e4cad8e7` on `OpenAgentsInc/openagents`
**Status:** audit and initial direction; nothing here is built yet
**Question:** `openagents coder` works with no account at all. We want the
opposite posture — sign in on open, work inside the account, and have the work
count. What already exists on the server to hang that on, what exists but is
not connected, and what does not exist?

## What the coder is today

Deliberately local-first, and it goes further than "works offline":

- With no `--model`, it answers from a local Ollama server if one is running.
- With no credential, it answers from a built-in stand-in and says so.
- `shell` runs commands on this machine. `skill` reads files from this machine.
- Children run on the harness's own free models, which need no credential from
  us at all.

Only two things reach the account: `openagents` CLI calls, and a thread-backed
turn. Everything else in a session can happen with nobody signed in.

That was the right default for a terminal tool nobody had signed into. It is the
wrong default for a tool whose point is the account.

## What exists on the server

**A leaderboard.** `OpenAgents.Leaderboard` publishes rank, the GitHub display
fields, and one integer: `total_tokens`. It is a real, bounded, public
projection with an invariant behind it (`LEADERBOARD-001`).

**Three memory planes**, all authoritative and all already governed:

- `OpenAgents.ExperienceMemory` — private, source-linked work outcomes and
  frozen advisory pattern banks.
- `OpenAgents.GraphMemory` — a derived, generation-pinned relationship index
  over that private experience.
- `OpenAgents.ProfileMemory` — durable profile claims, confined to one
  authenticated owner, which conversation history cannot enter without an
  explicit candidate call.

**A work graph.** Issues, projects, project fields and items, repositories, and
the receipt linkage designed in `2026-08-23-issue-work-receipt-linkage-design.md`
against issue `#10` — issues connected to jobs, conversations, commits, tests,
releases and deployments without a second work record.

**Metered inference.** A thread mints a fenced grant
(`sarah.inference_grant.v1`) that is budgeted in tokens and metered against the
owner's account, and the provider key never leaves the server.

## The three gaps, in the order they matter

### 1. Coder work does not reach the leaderboard

This is the sharp one, and it is small.

`Leaderboard.account_totals/0` unions two sources: `TurnReceipt` joined through
`Turn` → `Conversation` → `Visitor`, and `Voice.Session` joined the same way.
Both are the chat surface. A coder session runs on a **thread**, and a thread's
spend is recorded on `Inference.Grant.usage` — a map on the grant row, which the
leaderboard does not read.

So today a person can run the coder all day against their own account, spend
real tokens through the proxy, and appear nowhere. "Sign in and you are on the
board" is not true yet, and forcing the login without closing this would be
asking for a credential in exchange for nothing.

The fix is a third arm on the union, not a new counter. Grant usage is already
per-account and already authoritative; the question is only whether it is summed
in the same projection and whether that double-counts anything the chat arms
already claim. It should not — a thread is not a conversation — but that is the
thing to prove before shipping, and `DATA-002` is the rule to prove it against.

### 2. Memory is scoped to conversations, not to threads

All three planes hang off `Conversation` and `Visitor`. The coder does not have
either: it has a thread, a repository, a branch, and a working directory.

That is not a missing feature so much as a missing join. A coder session already
produces exactly the material the experience plane wants — a task, the tools
called, what came back, whether it worked — and throws it away when the process
exits. The ATIF export the CLI writes is that material, in a format the rest of
the system already reads.

The interesting question is not "how do we store memories" but **what a coder
session's unit of experience is**. A turn is too small and a session is too
coarse. The candidate that fits the work graph is the issue: one issue worked,
one outcome, linked to the commits and receipts `#10` already connects.

### 3. There is no experience, only tokens

`total_tokens` is a measure of spend, not of contribution. It rewards a long
session over a good one, and it will reward a fan-out of thirty children over a
person who thought for a minute and fixed the bug.

If the leaderboard is going to be the reason to sign in, it should count
something worth competing on. The pieces to compute that already exist —
issues closed, receipts anchored, tests passing, releases promoted — and none
of them are currently expressed as a score.

I would not design the score in this document. I would note that tokens are a
placeholder that has become load-bearing, and that adding coder tokens to it
(gap 1) makes it more load-bearing, not less.

## On forcing the login

Worth doing, with two conditions.

**It should buy something on the first run.** A person who signs in should get
the board, their history, and their memory — not a gate followed by the same
session they could have had anonymously. Gap 1 is the minimum for that to be
honest.

**It should not break the local lane.** The strongest thing about the coder
today is that it runs on a local model against a local repository with no
network. That is worth keeping as a deliberate, named mode rather than losing as
a side effect: `--offline` should stay, and it should stay the thing you reach
for on a plane rather than the thing you accidentally get when the login fails.

The device flow is already there and already mints both scopes, so the mechanism
costs nothing. What costs something is deciding what happens when the login is
declined: refuse to start, start in a named local mode, or start and nag. My
view is the second, and that the nag is the leaderboard being visible and empty.

## What I would do first

1. **Put thread spend on the leaderboard.** One arm on an existing union, with
   the double-count question answered against `DATA-002`. Nothing else on this
   list is honest until this is done.
2. **Write a coder session's outcome into experience memory, keyed by issue.**
   The ATIF export already holds it; the join is the work.
3. **Then** force the login, because by then it buys the board and the memory.
4. **Then** ask what a score should measure, with the data from 1 and 2 to
   answer it rather than guess.

## What this document does not claim

None of this is built. The gaps are read from the code as it stands at the
commit above, and the ordering is a view rather than a decision. The leaderboard
arm is the only part I would call obvious.
