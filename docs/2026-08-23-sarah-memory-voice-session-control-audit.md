# Sarah memory, voice, session, and control audit

**Date:** 2026-08-23
**Issue:** `OpenAgentsInc/openagents.com` #89
**Question:** Of the gaps reported after the launch episode, which still exist
in `main`, and what is the evidence either way?

Each gap below states its current status and the exact test that holds it. A
gap marked *held* was already closed in code but had no test naming the
behavior the report asked about; a gap marked *fixed* needed code in this
change.

## 1. Automatic memory saves, consent, and version history

**Held.** A profile-memory write requires consent evidence in the current
message, and `OpenAgents.Memory.Consent` returns
`:memory_consent_required` or `:memory_consent_mismatch` rather than writing
silently. Correction supersedes instead of overwriting, so the prior claim
stays readable as history and `/memory` shows the superseded row.

Evidence: `test/openagents/tools/profile_memory_tools_test.exs`,
`test/openagents/profile_memory_test.exs`,
`test/openagents_web/live/memory_live_test.exs`.

## 2. Voice tool calls in the same ordered activity stream as text

**Fixed.** Voice tool steps were durable in `voice_tool_steps`, but the
transcript only projected the steps of a live session. After the call ended, a
reload showed the spoken answer with no record of the tools that produced it,
while a text turn kept its activity attached to its assistant message.

`Voice.list_tool_step_activity_by_message/1` now joins tool steps to the
assistant message through the voice response receipt, and `ChatLive` merges
that projection with the text projection and orders both by step sequence. One
assistant message therefore carries one ordered activity list regardless of
modality.

Evidence: `test/openagents_web/live/chat_live_test.exs`, "voice tool activity
stays in the ordered transcript after the call ends";
`test/openagents/voice_test.exs`, "a refused host limit is durable and keyed to
the assistant message it belongs to".

## 3. Tool-call budget, visible limit, and typed terminal reason

**Fixed on the voice side.** The text runtime already budgets the loop and
records a typed `tool_call_limit_reached` outcome on the step that exceeded it,
with a runaway backstop above the budget
(`test/openagents/turn_tool_loop_test.exs`). The voice runtime sent the same
typed refusal to the provider but wrote nothing durable, so a truncated call
read back as a complete one.

`Voice.refuse_tool_step/4` now records the refusal as a terminal step with
status `refused`, the typed code, and the host executor disclosure, so the
refusal is evidence in the transcript rather than only a provider-side message.

Evidence: `test/openagents/voice_sessions_test.exs`, "the tool-call limit
refuses the next call and drives one tool-free report".

## 4. Voice session timeout, reconnect, resume, and failure

**Held.** The session budget warns at 80 percent and ends with a visible
reason at the ceiling; sideband loss reconnects under the same generation;
admission times out; a runtime restart fails the admitted generation
deterministically without inventing transcript or usage; a new generation is
admitted with prior conversation and tool evidence.

Evidence: `test/openagents/voice_sessions_test.exs` and
`test/openagents/voice_test.exs`, tests named for each of those behaviors.

## 5. Memory authorization across owners and versions

**Held, now proven.** `OpenAgents.ProfileMemory` scopes every read and
mutation by `owner_visitor_id`, including the locked queries that back forget
and purge. The report asked for a reproduction, so the test now walks a second
owner through the whole surface — list, get, correct, purge, transition, and
each forget mode — against another owner's record and its superseded versions,
and asserts the owner cannot read it, change it, delete it, or learn from the
result that it exists. A forget that targets nothing reports
`already_absent`, which is the same answer an empty account gets.

Evidence: `test/openagents/profile_memory_test.exs`.

## 6. Leaderboard opt-out

**Fixed.** `Leaderboard.ranked_query/1` already excluded accounts with
`public_leaderboard_opted_out`, but nothing let an account set the field: there
was no writer, no control, and no cache invalidation, so the column was
unreachable and the cached projection could serve a withheld account until an
unrelated recompute.

`Accounts.set_public_leaderboard_opt_out/2` writes the preference and
invalidates the cached projection on every change, including the change that
removes the account. `/memory` carries the control and states the current
state. Every public read of the board — the LiveView, the cached server, and
the recompute behind it — goes through `Leaderboard.ranked_query/1`, and no
other module projects the board, so one write covers every public surface.

Evidence: `test/openagents/leaderboard_test.exs`, "an account can withhold
itself from the board and publish itself again";
`test/openagents_web/live/memory_live_test.exs`, "the way back is a link, and
the board preference is the account's to set".

## 7. Return control on the memory page

**Fixed.** `/memory` is a page with an address, but its return control still
sent `toggle_memory`, an event from when memory was a panel inside the
conversation. No handler existed, so the control raised instead of returning.
It navigates to `/sarah` now.

Evidence: `test/openagents_web/live/memory_live_test.exs`.
