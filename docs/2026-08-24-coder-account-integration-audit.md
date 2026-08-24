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

**A payload is 2 to 16,384 bytes**, enforced by
`thread_events_payload_bound_check` on `octet_length(payload::text)`.

**A listing returns at most 50 events**, `@maximum_listed` in
`OpenAgents.Threads`.

Measured against four real coder sessions from the same afternoon:

| Session | Turns | Tool calls | Events at turn level | Events at tool level | Largest tool result |
| --- | --- | --- | --- | --- | --- |
| `16-58-34` | 13 | 42 | 13 | 55 | 6,511 B |
| `17-04-23` | 16 | 45 | 16 | 61 | 6,511 B |
| `17-08-32` | 4 | 5 | 4 | 9 | 8,418 B |
| `17-24-37` | 6 | 0 | 6 | 6 | 0 B |

The payload cap is not the binding constraint: the largest tool result observed
was 8.4 KB, and the transcript already bounds a result to 4,000 characters
before it reaches a model, so the same bound applied to an event keeps every one
of them comfortably inside 16 KB. A 30 KB shell output would not fit, which is
why the bound is applied rather than assumed.

**The listing cap was the binding constraint.** Turn-level persistence fits
inside fifty with room to spare; tool-level passes it on an ordinary working
session. So `list_events/2` now takes an `:after` cursor and the route publishes
each event's id, because a history that cannot be read back is not persistence.
That is the one server change this section required, and it is done.

### What to record

Recorded, in the order they happen:

- `turn.user` — what the reader asked.
- `tool.ran` — one event per call, carrying the tool, its arguments, and its
  bounded result. Call and result are one event rather than two: they are one
  fact, and splitting them doubles the count against the cap for nothing.
- `turn.assistant` — the answer, with the turn's token usage and call count.

Not recorded: text deltas, reasoning deltas, and the interface's own notices.
Deltas are how a reply arrives, not what it is, and a transcript that stores the
arrival cannot be read back as the thing. Reasoning is display-only for the same
reason it is not on the model transcript. Notices never reached a model.

That is roughly ATIF's step shape, which is not a coincidence: `/export` already
writes a session in exactly this granularity, and the two should not disagree
about what a session was.

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

The one open question is what a resumed session sends to the model. The
transcript is evidence of what happened, not a chat history in a provider's
shape, so replaying it verbatim is not obviously right — and a long thread would
reintroduce exactly the context-size problem that bounding tool results just
solved. My instinct is that a resumed session replays the turns and the tool
results, not the deltas, and bounds them the same way a live session does.

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
