# From local-first coder to an account-shaped one

**Date:** 2026-08-24
**Commit measured:** `a9a251e` on `openagents/main` (the forge), with the CLI at
`94e4cad8e7` on `OpenAgentsInc/openagents`
**Status:** audit and direction. The transcript routes and the event cursor are
built and shipped; the client that writes to them is not.
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

## Persistence: what the store can actually hold

The coder keeps nothing. A session ends and its history goes with it, and the
audit that preceded this one proposed a local JSON Lines file keyed on a thread
id. That is the wrong shape now: `thread_events` already exists, and a local
file beside it is a second copy that can disagree with the first. The server's
copy should be the only copy.

Three routes now open it — `GET /api/v3/threads`,
`GET /api/v3/threads/{id}/events`, and `POST /api/v3/threads/{id}/events` — all
wrapping context functions that were already there. What remains is deciding
what a client writes into them, and that is a question about limits rather than
about taste.

### The two limits

**A payload had a 16,384 byte ceiling**, enforced by
`thread_events_payload_bound_check`. It was inherited from tables that carry no
content and has been removed; the section below says why.

**A listing returns at most 50 events**, `@maximum_listed` in
`OpenAgents.Threads`. This one is a pagination bound rather than a storage
bound, and the cursor added alongside it is the answer.

Measured against four real coder sessions from the same afternoon:

| Session | Turns | Tool calls | Events at turn level | Events at tool level | Largest tool result |
| --- | --- | --- | --- | --- | --- |
| `16-58-34` | 13 | 42 | 13 | 55 | 6,511 B |
| `17-04-23` | 16 | 45 | 16 | 61 | 6,511 B |
| `17-08-32` | 4 | 5 | 4 | 9 | 8,418 B |
| `17-24-37` | 6 | 0 | 6 | 6 | 0 B |

The payload ceiling turned out to be inherited rather than reasoned, and is
gone; see below. What remains true of the measurements is that tool results are
small — the largest observed was 8.4 KB — and that reasoning is not: a single
block reached 38,791 characters, which is what exposed the ceiling as the wrong
rule for this table.

**The listing cap was the binding constraint.** Turn-level persistence fits
inside fifty with room to spare; tool-level passes it on an ordinary working
session. So `list_events/2` now takes an `:after` cursor and the route publishes
each event's id, because a history that cannot be read back is not persistence.
That is the one server change this section required, and it is done.

### What to record

Everything a full ATIF export needs, because that is the bar: a thread's
transcript should be able to reproduce the session, and an export that has to
reach outside the server for part of it is not a record of anything.

Recorded, in the order they happen:

- `turn.user` — what the reader asked.
- `turn.reasoning` — what the model thought, in order, before it answered.
- `tool.ran` — one event per call, carrying the tool, its arguments, and its
  bounded result. Call and result are one event rather than two: they are one
  fact, and splitting them doubles the count against the cap for nothing.
- `turn.assistant` — the answer, with the turn's token usage and call count.

**Reasoning is recorded whole, and it is not optional.** An earlier draft of
this document left it out and called that a saving, on the grounds that it is not
sent back to a model. That was wrong twice over. It is sent back now — a model
that cannot see how it reached its last answer reasons its way there again — and
it is the largest single part of what a session produces: 150,322 characters
against 8,232 characters of answer in one measured session. A transcript without
it is a summary with the working removed, and the working is what makes a
trajectory worth keeping for training, for review, or for understanding what a
run actually did.

Not recorded: text and reasoning **deltas**, and the interface's own notices.
A delta is how a reply arrived rather than what it is, and a transcript that
stores the arrival cannot be read back as the thing. Notices never reached a
model. That is the whole of what is dropped.

### The payload ceiling was inherited, and is gone

An earlier draft of this section proposed splitting reasoning across events,
because the largest single block measured is 38,791 characters against a 16,384
byte payload ceiling. That was fitting the wrong constraint, and the reasoning
given for it — that a bounded event is the point of an append-only evidence
table — does not survive reading where the bound came from.

The same `octet_length(payload::text) <= 16384` appears on `voice_events`,
`scv_run_events`, program receipts, and `ComputerActivity`. `thread_events`
copied it: the schema said so outright. Where that bound is actually justified,
it is justified by those tables carrying **no content** —
`2026-08-21-sarah-computers-and-scv-architecture-audit.md` records that an SCV
event payload is reduced to a fixed key allowlist and that "no file paths, tool
arguments, tool output, or report prose reach an event row", and that
`ComputerActivity` events are "a projection and never the authority".

`thread_events` is the authority, and the bar set above is a full ATIF
trajectory. A ceiling designed to keep content out of a projection is the wrong
rule for the table that holds the content. It is dropped
(`20260824184030_relax_thread_event_payload_ceiling`), the floor stays at "is a
JSON object", and `INVARIANTS.md` moves with it.

### Storing and sending are different questions

Removing the ceiling does not mean a client sends everything to a model on every
round. Those are separate decisions and the confusion between them is what
produced the chunking proposal:

- **The record holds what happened.** Every turn, all of the reasoning, every
  tool call with its whole result. Unbounded, because a truncated record cannot
  reproduce the session and a session that cannot be reproduced is not evidence
  of anything.
- **The wire is bounded by the client.** The model transcript already bounds a
  tool result to 4,000 characters, and that bound belongs there — it is a
  context-budget decision made against a model's window, not a property of what
  happened.

A client that needs to page a large payload over the wire can do that when it
needs to. It is a transport concern, and solving it in the store cost every
future reader a reassembly step for nothing.

### Resume

Follow Codex, which has the shape right and which this vocabulary already
follows:

- `openagents coder --resume` with no argument shows recent threads and lets one
  be picked, filtered to the current repository by default.
- `openagents coder --resume <uuid>` takes a thread id directly.
- `openagents coder --resume --last` continues the most recent without asking.
- `--all` drops the repository filter and shows which repository each thread
  belongs to.

`GET /api/v3/threads` is the picker's list and `GET /api/v3/threads/{id}/events`
is the transcript it replays. Neither needs anything new.

The one open question is what a resumed session **loads**, which is separate
from what it stores and should be decided separately. Everything is recorded;
that is settled. Whether a long thread is replayed whole, or condensed, or
replayed from some point forward, is a question about context budgets and about
what a model needs to carry on — and it is answerable only because the whole
record is there to choose from. A decision to store less would have foreclosed
it.

## What I would do first

1. **Put thread spend on the leaderboard.** One arm on an existing union, with
   the double-count question answered against `DATA-002`. Nothing else on this
   list is honest until this is done.
2. **Write the coder's turns to `thread_events`, and resume from them.** The
   routes and the cursor exist; what remains is the client. This is also what
   makes a session worth signing in for, since the history stops being local and
   disposable.
3. **Write a coder session's outcome into experience memory, keyed by issue.**
   The ATIF export already holds it; the join is the work.
4. **Then** force the login, because by then it buys the board, the history, and
   the memory.
5. **Then** ask what a score should measure, with the data to answer it rather
   than guess.

## What this document does not claim

None of this is built. The gaps are read from the code as it stands at the
commit above, and the ordering is a view rather than a decision. The leaderboard
arm is the only part I would call obvious.
