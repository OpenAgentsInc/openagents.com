# Asynchronous recovery contract

Date: 2026-08-20

Status: Gate 8 implementation contract

This contract defines what the application must do when a runtime process dies
after durable work has begun. PostgreSQL is authority. Processes, registry
entries, PubSub messages, browser state, and provider streams are projections
that may disappear or repeat.

## Shared rules

- Persist identity, ownership, scope, budget, and an execution fence before an
  external effect begins.
- Recovery may resume only when the external operation has a durable
  idempotency or reattachment contract. Otherwise it must terminate the
  durable row honestly and require a new user action.
- Duplicate delivery must return or extend the existing durable record; it
  must not repeat a completed mutation.
- A stale process may not commit after a newer owner has acquired the durable
  fence.
- Every input, stream frame, accumulated projection, tool request, tool result,
  report, and exported representation has a byte, item, time, or count bound.
- Provider-specific errors and private content do not cross the adapter or log
  boundary. Durable failures use bounded application error codes.
- Recovery tests use supervised processes, process monitors, synchronous state
  barriers, and durable-state assertions. Fixed sleeps are not correctness
  mechanisms.

## Text turns

A text turn has no provider reattachment identity that can safely continue an
arbitrary interrupted stream. If its `TurnServer` dies, `TurnRecovery` changes
the active turn, assistant message, receipt, provider step, and tool steps to
an explicit terminal interrupted/failed state in one transaction. It does not
invent completion, usage, or provider output. Re-running recovery is a no-op.

Provider response creation is not retried by the HTTP adapter. The host may
start a new response only through the explicit, bounded tool-continuation
protocol whose durable tool outcome is already committed.

## Voice sessions

A live Realtime transport cannot be reconstructed from PostgreSQL. If its
runtime disappears, `VoiceRecovery` or the restarted `SessionServer` fails the
admitted generation and fences all late events. Final transcript, response,
usage, tool-step, and recording evidence already committed remains durable;
ephemeral transcript deltas do not become final evidence. Typed chat remains
available.

Voice-call admission is not retried by the HTTP adapter. Sideband reconnect is
bounded within the same admitted generation and does not create another call.

## Work jobs

Each delegated computer job durably binds the owner, conversation, computer,
admission-time authority snapshot, and budget snapshot. Each claim increments
the PostgreSQL generation fence. The worker reads the computer, agent, working
directory, and wall-clock limit from the immutable admission fields. A database
trigger makes the delegation request immutable except for its fenced ACP
session checkpoint. `WorkRecovery` restarts an active singleton; the new worker
adopts the row and, when a durable ACP session ID exists, reattaches that
external session. A stale generation cannot checkpoint or finish the job. If a
worker cannot be started, recovery writes an honest interrupted report and
terminal state.

Deep-work and coding jobs use the same generation fence and persist tool steps
before execution. A completed provider call ID or tool invocation is never
executed again merely because a delivery repeats.

## Semantic derivatives

Semantic embeddings are rebuildable derivatives, so retrying the computation
is safe. Claiming a job sets a bounded lease. A second worker may reclaim only
a running job whose lease expired. Provider execution has a shorter hard
timeout than the lease, and embedding persistence rechecks the active manifest
and authoritative message digest. Provider failure becomes a bounded terminal
failure; a process or database failure leaves the leased job reclaimable. A
source mutation or deletion invalidates the job and derivative before a stale
result can become authoritative.

## Required direct evidence

- Kill a live `TurnServer`, run `TurnRecovery`, and assert every durable active
  row becomes terminal without fabricated completion.
- Start `VoiceRecovery` over an admitted active generation and assert the
  runtime is ignored only after the durable session is failed.
- Kill or orphan a work worker at durable checkpoints, run `WorkRecovery`, and
  assert generation-fenced adoption or honest terminal fallback.
- Exercise `SemanticWorker` through provider failure, contained drain/database
  failure, and worker death followed by expired-lease reclamation.

The broader Gate 8 suites continue to own cancellation, malformed provider
events, reconnect, duplicate delivery, memory isolation, data rights, voice
recording, computer credentials, and harmless delegated-work behavior.
