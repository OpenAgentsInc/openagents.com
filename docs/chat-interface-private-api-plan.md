# Chat interface and private API plan

Date: 2026-08-19

Status: Planned

## Outcome

OpenAgents will serve the `/chat` user interface from this public repository. The interface lets an authenticated user chat with Sarah through a separate API service, configured as `https://api.openagents.com` in production.

This repository owns the presentation layer and API client. The private API service owns Sarah’s behavior and all sensitive application logic.

The public application includes:

- The `/chat` LiveView route and responsive shell.
- The transcript, composer, queued-turn display, streaming updates, and connection state.
- Safe Markdown rendering and message actions.
- Public projections of tool activity, delegated work, memory, privacy controls, and voice state.
- A versioned API client, server-to-server authentication, retry policy, and event-stream bridge.
- Same-origin proxy endpoints where browser media or downloads require an HTTP endpoint.
- Tests, fixtures, accessibility behavior, and operational status.

The public application does not include:

- Sarah’s prompts, persona instructions, reasoning policy, or model selection.
- Inference-provider integrations or credentials.
- Memory extraction, retrieval, ranking, correction policy, or storage.
- Conversation, turn, message, receipt, tool-step, recording, or work-job persistence.
- Tool definitions, tool routing, execution policy, computer control, or agent delegation logic.
- Voice-provider session orchestration, usage limits, or recording storage.
- Entitlement, safety, moderation, or data-retention policy.

The private API may use any internal architecture. The public application depends only on the versioned HTTP and event contracts documented here.

## Architecture

```text
browser
  |
  | LiveView WebSocket and same-origin HTTP
  v
openagents.com
  - OpenAgentsWeb.ChatLive
  - chat components and browser hooks
  - OpenAgents.ChatAPI behaviour
  - OpenAgents.ChatAPI.ReqClient
  - OpenAgents.Chat.SessionBridge
  - voice and export proxy controllers
  |
  | HTTPS, service authentication, user assertion
  v
api.openagents.com
  - conversation and message authority
  - Sarah persona and inference
  - memory and tools
  - delegated work
  - voice orchestration
  - durable records and data rights
```

The browser does not receive the service credential and does not call the private API directly for text chat. `openagents.com` makes server-to-server calls with `Req` and sends public projections to the browser through LiveView.

Voice setup and recordings use same-origin controller routes. Those controllers validate the browser session and CSRF token, then relay bounded requests to the private API. The browser may establish the resulting WebRTC media path directly, but it never receives a provider API key.

## Ownership boundary

| Concern | Public `openagents.com` application | Private API service |
| --- | --- | --- |
| User authentication | Establishes the browser session and stable user subject | Verifies the signed user assertion and enforces resource ownership |
| Agent identity | Renders returned display metadata such as `Sarah` | Selects persona, prompts, models, and behavior |
| Conversation state | Holds bounded transient projections in LiveView and bridge processes | Stores conversations, turns, messages, receipts, and cursors |
| Turn ordering | Renders active and queued turns | Accepts, validates, orders, rate-limits, and executes turns |
| Streaming | Resumes and projects versioned events | Produces ordered, replayable events |
| Markdown | Parses and sanitizes assistant text for display | Returns plain Markdown, never trusted HTML |
| Tool activity | Renders a bounded display-safe activity object | Selects tools, executes them, and removes sensitive fields |
| Delegated work | Renders status, elapsed time, bounded log text, and cancellation | Starts agents, controls machines, stores outcomes, and authorizes cancellation |
| Memory | Renders records and explicit correction or deletion controls | Extracts, stores, searches, corrects, forgets, and audits memory |
| Voice | Manages browser media controls and same-origin requests | Admits sessions, connects providers, enforces limits, and stores recordings |
| Data rights | Presents confirmation and streams downloads | Exports or deletes the authenticated user’s durable data |
| Observability | Records content-free client and transport metrics | Records model, tool, policy, and durable execution metrics |

Do not add Ecto schemas for chat data to this repository. API response structs are transport data, not local database records.

## Security invariants

Implement these rules before enabling `/chat` in production:

- **The private API remains the authority.** Client-side and LiveView validation improve usability but never replace API authorization or policy.
- **The browser never receives service or provider credentials.** Store them in runtime configuration and use them only in server-side adapters.
- **Every resource is user-scoped.** The API derives ownership from a verified assertion and does not trust a conversation or message ID by itself.
- **The API base URL is operator-owned configuration.** Never derive it from request parameters, headers, or user content.
- **The API returns public projections.** Tool arguments, prompts, provider IDs, internal instructions, secrets, and unbounded output never cross the boundary.
- **Model output is untrusted.** Parse Markdown through an allowlist, escape every text node, reject unsafe URL schemes, and never render API-provided HTML.
- **Events are ordered and resumable.** Every session event carries a monotonically increasing sequence and opaque cursor.
- **Mutations are idempotent.** Turn creation, cancellation, memory actions, recording chunks, and deletion requests use idempotency keys.
- **Logs are content-free by default.** Log request IDs, status codes, durations, byte counts, and error codes without message content or memory claims.
- **Destructive actions require explicit confirmation.** The public UI states the scope, and the private API revalidates the confirmation.
- **Voice requires a secure context and explicit microphone access.** A voice failure leaves typed chat available.
- **Feature capabilities come from the API.** The public application does not infer that memory, tools, delegation, recording, or voice is available.

## Authentication contract

The current application needs authenticated browser sessions before the chat route can ship. Complete `docs/github-auth-plan.md` first, then reuse its account, browser pipeline, and authenticated `live_session` instead of creating a second authentication system for chat.

1. Complete `docs/github-auth-plan.md` and use its authenticated `live_session`.
2. Pass `current_scope` to `<Layouts.app>` and derive a stable, non-email user subject from it.
3. Create a short-lived service assertion for every API request or stream connection. Use a signed JWT or workload-identity token with these claims:
   - `iss`: `openagents.com`
   - `aud`: `api.openagents.com`
   - `sub`: the stable OpenAgents user ID
   - `sid`: the browser-session identifier
   - `scope`: the minimum API scopes required for the request
   - `iat` and `exp`: a short validity window
   - `jti`: a unique token identifier
4. Send the assertion in `Authorization: Bearer <token>` over TLS.
5. Send a content-free `X-Request-ID` for correlation.
6. Rotate signing keys without a deploy. Keep the active key ID in the token header and publish verification keys through operator-managed configuration.

The private API verifies signature, issuer, audience, expiration, scope, and resource ownership on every request. It must not accept user identity from an unsigned forwarding header.

Tests use a fake signer and fake API adapter. They never require a production credential.

## Versioned API contract

Use `/v1` for the first contract. Every JSON object includes a `schema` field. Treat unknown fields as additive, but reject unknown schema major versions.

### Session snapshot

`POST /v1/chat/sessions` ensures that the authenticated user has a chat session. The public application may send a configured agent ID, such as `sarah`, but it cannot send prompts or model settings.

Request:

```json
{
  "schema": "openagents.chat.session_request.v1",
  "agent_id": "sarah"
}
```

Response:

```json
{
  "schema": "openagents.chat.session.v1",
  "id": "chat_opaque_id",
  "cursor": "event_cursor",
  "agent": {
    "id": "sarah",
    "display_name": "Sarah"
  },
  "capabilities": {
    "text": true,
    "voice": false,
    "memory": true,
    "delegation": true,
    "recording": false,
    "data_export": true,
    "data_delete": true
  },
  "active_turn": null,
  "queued_turns": [],
  "messages": [],
  "has_older_messages": false
}
```

Keep capability values and agent display metadata declarative. A capability controls whether its public UI renders; it does not expose how the service implements that capability.

### Message history

`GET /v1/chat/sessions/{session_id}/messages?before={message_id}&limit=50` returns messages in chronological order plus a new `has_older_messages` value.

Message projection:

```json
{
  "schema": "openagents.chat.message.v1",
  "id": "msg_opaque_id",
  "turn_id": "turn_opaque_id",
  "role": "assistant",
  "content": "Plain Markdown text",
  "status": "streaming",
  "modality": "text",
  "interrupted": false,
  "created_at": "2026-08-19T21:00:00Z",
  "activity": []
}
```

Allowed roles are `user`, `assistant`, and `system`. Allowed message statuses are `queued`, `streaming`, `complete`, `failed`, and `cancelled`. Reject or safely map unknown enum values instead of creating atoms from API strings.

### Turn creation and queueing

`POST /v1/chat/sessions/{session_id}/turns` accepts one user message.

Headers:

- `Idempotency-Key`: a client-generated UUID retained for retries.
- `X-Request-ID`: a content-free trace ID.

Request:

```json
{
  "schema": "openagents.chat.turn_request.v1",
  "content": "Help me plan this change."
}
```

Response status is `202 Accepted`. The response includes the authoritative user message and turn projection. If another turn is active, the API creates the turn with `status: "queued"`. The private API owns FIFO ordering and queue limits so reconnects and multiple tabs cannot lose or reorder work.

The public application performs these local checks for immediate feedback:

- Trim leading and trailing whitespace.
- Refuse an empty message.
- Limit UTF-8 input to the contract’s advertised maximum, initially 8,000 bytes.

The API repeats every validation and returns the authoritative outcome.

### Turn and queue mutations

Use these idempotent endpoints:

- `POST /v1/chat/turns/{turn_id}/cancel` cancels an active turn.
- `DELETE /v1/chat/turns/{turn_id}` removes a queued turn.
- `POST /v1/chat/delegations/{delegation_id}/cancel` cancels delegated work when the capability and policy allow it.

The API responds with the updated projection. The event stream remains the source of reconciliation for every open tab.

### Session event stream

`GET /v1/chat/sessions/{session_id}/events?after={cursor}` returns a server-sent event stream. The API sends a heartbeat often enough to detect dead connections without generating a UI update.

Each event contains:

- A monotonically increasing event ID.
- A versioned event name.
- The session ID.
- The resource ID.
- A bounded public payload.
- The server timestamp.

Initial event types:

- `session.snapshot` replaces all transient projections after a cursor reset.
- `message.upsert` inserts or updates a message.
- `turn.upsert` updates active or queued turn state.
- `turn.removed` removes a queued turn.
- `activity.upsert` updates display-safe tool activity attached to a message or active turn.
- `delegation.started`, `delegation.chunk`, `delegation.truncated`, and `delegation.completed` drive the live work rail.
- `voice.updated` updates voice session state and capability metadata.
- `voice.transcript` inserts an ephemeral or durable voice transcript projection.
- `memory.updated` tells an open memory manager to refresh its list.
- `capabilities.updated` enables or removes optional controls.
- `session.reset` clears the local transcript after an authorized reset.

The stream supports `Last-Event-ID` or the `after` cursor. When the API returns `410 Gone` for an expired cursor, fetch a fresh session snapshot and reset the LiveView streams.

Prefer full `message.upsert` projections to unaudited client-side text concatenation. If the API also emits `assistant.delta` events for latency, each delta includes a sequence, and the next full upsert reconciles the accumulated content.

### Activity projection

The API converts internal tool and work state into a bounded display object before returning it:

```json
{
  "schema": "openagents.chat.activity.v1",
  "id": "activity_opaque_id",
  "status": "running",
  "title": "Searching your conversation history",
  "status_note": null,
  "detail": null,
  "started_at": "2026-08-19T21:00:01Z",
  "completed_at": null
}
```

The public application renders this object but does not derive titles from internal tool names or inspect raw arguments. Limit `title`, `status_note`, and `detail` by bytes at both services. Do not include provider call IDs, prompts, credentials, hidden instructions, or unrestricted tool output.

### Error envelope

Every non-stream error uses this shape:

```json
{
  "schema": "openagents.error.v1",
  "error": {
    "code": "rate_limited",
    "message": "Try again in a moment.",
    "retry_after_ms": 2000,
    "request_id": "request_opaque_id"
  }
}
```

Map stable codes to reviewed user-facing copy. Never render upstream stack traces, raw provider errors, internal policy details, or arbitrary response bodies.

## Public module layout

Use one module per file. Keep HTTP transport outside the LiveView.

```text
lib/openagents/chat_api.ex
lib/openagents/chat_api/req_client.ex
lib/openagents/chat_api/error.ex
lib/openagents/chat_api/session.ex
lib/openagents/chat_api/message.ex
lib/openagents/chat_api/turn.ex
lib/openagents/chat_api/activity.ex
lib/openagents/chat/session_bridge.ex
lib/openagents/chat/session_supervisor.ex
lib/openagents/chat/session_registry.ex
lib/openagents_web/live/chat_live.ex
lib/openagents_web/components/chat_shell.ex
lib/openagents_web/components/chat_message.ex
lib/openagents_web/components/chat_composer.ex
lib/openagents_web/components/chat_activity.ex
lib/openagents_web/components/chat_memory.ex
lib/openagents_web/components/chat_voice.ex
lib/openagents_web/controllers/chat_voice_controller.ex
lib/openagents_web/controllers/chat_export_controller.ex
lib/openagents_web/markdown.ex
assets/js/chat_voice_controller.js
assets/js/paced_transcript.js
```

`OpenAgents.ChatAPI` defines a behaviour for session, history, mutation, memory, voice, and export operations. `OpenAgents.ChatAPI.ReqClient` implements it with the existing `Req` dependency. Tests select `OpenAgents.ChatAPI.Fake` through application configuration.

Do not put HTTP calls, token creation, response decoding, or retry rules directly in `OpenAgentsWeb.ChatLive`.

## Session bridge

Use one supervised bridge per `{user_subject, session_id}` to avoid one private API event stream per browser tab.

1. Start `OpenAgents.Chat.SessionRegistry` and `OpenAgents.Chat.SessionSupervisor` in `OpenAgents.Application` after `OpenAgents.PubSub`.
2. Start or find a `SessionBridge` when an authenticated LiveView connects.
3. Let the bridge open the API event stream from the session cursor.
4. Decode bounded frames and broadcast public DTO events on a PubSub topic derived from the opaque session ID.
5. Track the last confirmed cursor in bridge state.
6. Reconnect with exponential backoff and jitter after transport failure.
7. Request a fresh snapshot after `410 Gone`, invalid ordering, or an unrecoverable parse error.
8. Stop the bridge after the last local subscriber leaves and a short grace period expires.

The bridge holds only bounded public projections and cursor state. It does not persist message content in the public database.

Use a task under a `Task.Supervisor` for the blocking HTTP stream. Monitor the task, and send decoded events to the bridge process. Bound frame size, idle time, reconnect count, and total buffered bytes.

## Phase 1: Add authentication and the API adapter

1. Reuse the authenticated browser pipeline and `live_session` from `docs/github-auth-plan.md` for `/chat`.
2. Add `OpenAgents.ChatAPI` and response structs with explicit string-to-enum validation.
3. Add `OpenAgents.ChatAPI.ReqClient` with a fixed configured base URL.
4. Add service assertion creation and credential redaction.
5. Configure connection, first-byte, inactivity, and total-request timeouts by operation.
6. Retry safe reads and stream reconnections. Retry mutations only with the same idempotency key.
7. Bound response bodies before decoding and reject unexpected content types.
8. Add a fake API implementation and representative JSON and event fixtures under `test/support`.

**Exit criteria:** tests cover successful session creation, authentication failure, timeout, malformed JSON, unknown schema version, unknown enum value, oversized response, retry-safe reads, and idempotent mutation retry.

## Phase 2: Build the text chat shell

Add `live "/chat", ChatLive, :index` inside the authenticated `live_session`. Reserve `chat` in any future wildcard owner or repository routing.

`ChatLive.mount/3` performs this sequence:

1. Read the authenticated user from `current_scope`.
2. Ensure the API session.
3. Convert the returned message projections into `OpenAgents.ChatAPI.Message` structs.
4. Assign capability, active-turn, connection, and history state.
5. Build the composer with `to_form/2`.
6. Initialize `stream(:messages, messages)` and `stream(:queued_turns, queued_turns)`.
7. On connected mount, start or join the session bridge and subscribe to its PubSub topic.

Build a full-height, responsive chat surface through `<Layouts.app flash={@flash} current_scope={@current_scope} ...>`. Extend the layout with an explicit full-height chat variant instead of duplicating the application shell.

The first UI increment includes:

- A collapsible desktop sidebar and mobile overlay.
- A real connected or reconnecting indicator driven by LiveView socket state.
- A single transcript scroller.
- Chronological message rows.
- A pinned composer with an autosizing textarea.
- **Enter** to send and **Shift+Enter** for a newline.
- An always-available composer while another turn runs.
- Queued-turn rows with remove controls.
- A stop control for the active turn.
- A load-earlier control that preserves scroll position when messages prepend.
- Empty, loading, offline, API-unavailable, and signed-out states.

Use stable element IDs:

```text
#chat-app
#chat-sidebar
#chat-sidebar-toggle
#chat-mobile-menu
#chat-connection-indicator
#transcript
#messages
#load-older
#message-form
#chat_message
#composer-error
#send-message
#cancel-turn
#message-queue
#queued-{turn_id}
```

Use `phx-update="stream"` on message and queue parents. When activity stored in another assign changes a streamed row, reinsert the corresponding message so the row rerenders.

**Exit criteria:** LiveView tests prove authenticated access, initial history, send, queue, dequeue, cancel, composer reset, validation, older-history prepend, reconnect state, and account isolation through the fake API.

## Phase 3: Add safe streaming and transcript behavior

1. Implement the session bridge and SSE decoder.
2. Apply events idempotently by session ID, resource ID, and event sequence.
3. Ignore events for another session.
4. Reconcile optimistic form state with authoritative `message.upsert` and `turn.upsert` events.
5. Reset streams from `session.snapshot` after cursor expiry.
6. Keep the composer draft when the API rejects a turn. Clear it only after `202 Accepted`.
7. Scroll to the bottom after a local send and when the viewer already sits near the bottom.
8. Preserve the viewer’s position while loading older messages.
9. Support stable message fragment links such as `/chat#messages-{message_id}`.
10. Add copy-message, copy-link, and copy-code controls through one delegated transcript hook.
11. Localize machine-readable UTC timestamps in the browser.

Add `OpenAgentsWeb.Markdown` to parse assistant Markdown into an allowlisted AST. Escape all text, remove raw HTML, allow only reviewed tags and attributes, and permit only `http`, `https`, `mailto`, relative, and fragment links. Complete open Markdown delimiters while a response streams so partial syntax does not flash as raw markup.

User messages render as escaped plain text. Assistant voice transcripts render as escaped plain text. Assistant text messages may render through the safe Markdown path.

**Exit criteria:** tests cover ordered and duplicate events, reconnect from cursor, cursor expiry, partial Markdown, unsafe links, raw HTML, message anchors, copy controls, and scroll preservation.

## Phase 4: Add activity and delegated-work projections

Render API-provided public activity objects as expandable event rows attached to the corresponding assistant message. Show status in text and color so color never carries the result alone.

Support these statuses:

- `requested`
- `running`
- `succeeded`
- `failed`
- `refused`
- `cancelled`
- `unavailable`
- `interrupted`

Add one bounded live delegation projection:

- Show it as a right rail on wide screens and an inline transcript section on narrow screens.
- Display the API-provided title, public worker label, elapsed time, status, and bounded log text.
- Keep at most one expanded live delegation and three recent summary rows.
- Mark truncated logs explicitly.
- Offer cancellation only when the API capability says it is allowed.
- Keep the durable activity event in the transcript after the live rail closes.

The public renderer never decodes internal tool framing or maps private tool names. The API sends display-ready plain text fields and semantic status values.

**Exit criteria:** tests cover activity before text, terminal activity persistence, live delegation start and completion, supersession, truncation, cancellation, mobile placement, and payload redaction.

## Phase 5: Add memory and data-rights surfaces

Render memory only when `capabilities.memory` is true. The private API supplies account-scoped public memory records.

Use these endpoints:

- `GET /v1/users/me/memory` lists bounded public records.
- `POST /v1/users/me/memory/{record_id}/correct` submits explicit replacement wording and the expected generation.
- `POST /v1/users/me/memory/forget` accepts one explicit selector: record, category, or all active records.
- `GET /v1/users/me/exports/memory` streams the memory export.
- `GET /v1/users/me/exports/all` streams the complete user export.
- `DELETE /v1/users/me/data` requests complete account-data deletion after typed confirmation.

The memory manager includes:

- Active, superseded, and forgotten status.
- The claim, category, source type, and source date returned by the API.
- Correction forms driven by `to_form/2`.
- Explicit record, category, and all-memory confirmation steps.
- Memory-only and complete-data export controls.
- A separate typed confirmation for complete deletion.

Proxy exports through `OpenAgentsWeb.ChatExportController`. Stream the API response without storing it, preserve a safe content type and filename, set `Cache-Control: no-store`, and never log its body.

Do not reproduce memory policy or mutate local memory state optimistically. Refresh after the API confirms a correction or deletion and when `memory.updated` arrives.

**Exit criteria:** tests cover capability-off behavior, account-scoped lists, generation conflict, correction, each deletion scope, explicit confirmation, multi-tab refresh, safe downloads, no-store headers, and deletion failure.

## Phase 6: Add voice through same-origin proxies

Render voice controls only when `capabilities.voice` is true. Keep typed chat available throughout the voice lifecycle.

Add same-origin routes under `/chat/voice`:

- `POST /chat/voice/calls` relays a bounded SDP offer and returns the SDP answer.
- `DELETE /chat/voice/calls` ends the authenticated user’s active call.
- `POST /chat/voice/calls/interrupt` requests interruption.
- `POST /chat/voice/calls/recording` relays one bounded recording chunk when recording is enabled.
- `POST /chat/voice/calls/recording/complete` finalizes recording metadata.
- `POST /chat/voice/telemetry` relays an allowlisted client event name without arbitrary detail.

`OpenAgentsWeb.ChatVoiceController` performs authentication, CSRF protection, content-type checks, byte limits, idempotency, and API forwarding. It does not talk to an inference provider.

Add `ChatVoiceController` as an external LiveView hook in `assets/js/chat_voice_controller.js` and register it in `assets/js/app.js`. The hook manages:

- Secure-context and browser-capability checks.
- Microphone permission.
- `RTCPeerConnection`, local tracks, the data channel, and remote audio.
- A paused microphone until the peer, control channel, and server session are ready.
- Mute, interrupt, playback unlock, end, reconnect, and page-exit behavior.
- Remote-session detection when another tab owns the active call.
- Recording disclosure and optional recording that cannot break the call.
- Cleanup of every track, peer, channel, timer, and recording resource.

Use these stable controls:

```text
#voice-controller
#voice-status
#voice-indicator
#voice-start
#voice-mute
#voice-interrupt
#voice-unlock
#voice-end
#voice-output
#voice-recording-indicator
```

Keep the microphone disabled when playback is blocked, the server is not ready, the user muted it, the peer disconnects, or a text turn is active. State every terminal reason in the live status region.

Use an external `PacedTranscript` hook for live assistant voice transcripts. The hook owns only its text node, uses `phx-update="ignore"`, and preserves reveal progress when an ephemeral row becomes durable.

**Exit criteria:** JavaScript unit tests cover microphone gating, cleanup, error wording, recording eligibility, and state transitions. Controller tests cover CSRF, authentication, content type, byte limits, upstream errors, and credential redaction. A secure-browser drill covers connect, speech, interruption, mute, playback blocking, remote-tab state, end, and typed-chat fallback.

## Phase 7: Match the public design system

Port the interaction hierarchy, not a second component library.

- Build the interface from `OpenAgentsWeb.CoreComponents`, DaisyUI patterns, and Tailwind classes.
- Extend the shared component library for reusable event rows, status indicators, and icon-only buttons.
- Use the existing OpenAgents color and type system.
- Keep component-specific styling colocated where possible. Do not use `@apply`.
- Use the existing icon component and give every icon-only control an `aria-label`.
- Keep the transcript measure readable and the composer pinned without creating nested page scrolling.
- Preserve visible focus, touch targets, reduced-motion behavior, and sufficient contrast.
- Use functional components. Do not introduce LiveComponents unless a component needs independent state and lifecycle.

Place sizeable JavaScript hooks in `assets/js` and register them in the existing `app.js` bundle. Use colocated hooks for small behavior attached to one component. Never add raw inline scripts.

**Exit criteria:** the layout works at narrow mobile, tablet, desktop, and wide delegation-rail breakpoints with keyboard-only navigation and reduced motion.

## Phase 8: Add failure handling and observability

Distinguish these failure classes in UI and telemetry:

- LiveView connection loss: show **Reconnecting** and let LiveView restore the page.
- Private API unavailable during mount: render a retryable unavailable state without exposing details.
- Event stream disconnected: keep the current transcript, show delayed updates, and resume from the cursor.
- Turn rejected: retain the draft and map the stable API error code to reviewed copy.
- Turn failed after acceptance: preserve the partial assistant message and label it **Incomplete**.
- Turn cancelled: preserve the partial response and label it **Stopped**.
- Cursor expired: refresh the session snapshot and reset transient streams.
- Voice failure: close local media and leave typed chat available.
- Export or deletion failure: keep the confirmation state and show a scoped error.

Record content-free Telemetry events for:

- API request duration, status class, and response bytes.
- Event-stream connection, reconnect, cursor reset, and frame rejection.
- Time from accepted turn to first assistant content.
- Time from accepted turn to terminal state.
- Active bridge count and subscriber count.
- Voice admission result and client state transitions.

Do not include message content, memory claims, activity detail, SDP, recording bytes, user email, or service assertions in telemetry metadata.

Add a readiness dependency policy. A private API outage should not take down repository and issue surfaces. `/chat` may report degraded while the rest of `openagents.com` remains ready.

**Exit criteria:** fault-injection tests cover timeouts, disconnects, malformed events, cursor reset, API `401`, API `403`, API `409`, API `429`, API `5xx`, and recovery without duplicate messages.

## Phase 9: Test the complete boundary

Add focused test files:

```text
test/openagents/chat_api/req_client_test.exs
test/openagents/chat/session_bridge_test.exs
test/openagents_web/live/chat_live_test.exs
test/openagents_web/controllers/chat_voice_controller_test.exs
test/openagents_web/controllers/chat_export_controller_test.exs
test/openagents_web/markdown_test.exs
assets/test/chat_voice_controller_test.mjs
assets/test/paced_transcript_test.mjs
```

Use a supervised local fake API server for transport tests. Script JSON responses, SSE frames, connection drops, delays, and status codes. Keep its fixtures free of prompts, provider payloads, credentials, and other private implementation details.

LiveView tests use stable IDs with `element/2`, `has_element?/2`, `render_submit/2`, and `render_click/2`. Do not assert against raw HTML strings.

Required test cases include:

- Signed-out route handling and authenticated mount.
- Account isolation against guessed session, message, turn, activity, memory, export, and voice IDs.
- Initial and paginated history.
- Message send, API rejection, idempotent retry, and draft retention.
- One active turn with API-owned FIFO queueing.
- Queue removal and active-turn cancellation.
- Streaming content, activity before content, completion, failure, and cancellation.
- Event replay, duplicate events, out-of-order events, cursor expiry, and snapshot reset.
- Multiple tabs sharing one session bridge and receiving the same updates.
- Safe Markdown under partial and adversarial input.
- Memory correction and destructive confirmation.
- Export and deletion behavior.
- Voice admission, cleanup, and typed fallback.
- API outage isolation from non-chat routes.

Run `mix precommit` before every handoff. If JavaScript tests become part of the interface, add the Node test command to the `precommit` alias so the standard gate covers them.

## Configuration inventory

Use runtime configuration and safe defaults:

| Environment variable | Purpose | Default posture |
| --- | --- | --- |
| `OPENAGENTS_CHAT_ENABLED` | Enables the route and bridge supervisors | `false` until staged |
| `OPENAGENTS_CHAT_API_URL` | Fixed private API origin | `http://127.0.0.1` in development only |
| `OPENAGENTS_CHAT_AGENT_ID` | Selects the public agent identity | `sarah` |
| `OPENAGENTS_CHAT_ASSERTION_KEY` | Signs service-to-service user assertions | Required in production and never logged |
| `OPENAGENTS_CHAT_ASSERTION_KEY_ID` | Identifies the active verification key | Required in production |
| `OPENAGENTS_CHAT_CONNECT_TIMEOUT_MS` | Bounds TCP and TLS connection setup | Explicit bounded value |
| `OPENAGENTS_CHAT_REQUEST_TIMEOUT_MS` | Bounds non-stream requests | Explicit per-operation value |
| `OPENAGENTS_CHAT_STREAM_IDLE_TIMEOUT_MS` | Detects a dead event stream | Longer than the API heartbeat |
| `OPENAGENTS_CHAT_MAX_RESPONSE_BYTES` | Bounds JSON response bodies | Explicit production value |
| `OPENAGENTS_CHAT_MAX_EVENT_BYTES` | Bounds one event-stream frame | Explicit production value |
| `OPENAGENTS_CHAT_VOICE_MAX_SDP_BYTES` | Bounds browser SDP requests | Explicit production value |
| `OPENAGENTS_CHAT_RECORDING_MAX_CHUNK_BYTES` | Bounds one optional recording chunk | Explicit production value |

When chat is enabled in production, validate required URL and authentication settings during startup. Redact values from configuration errors.

## Commit sequence

Keep each commit independently buildable and testable.

| Order | Commit | Required verification |
| --- | --- | --- |
| 1 | Define the chat API contract and fake adapter | DTO, schema, enum, and error tests pass |
| 2 | Add authenticated server-to-server chat requests | Authentication, timeout, redaction, and isolation tests pass |
| 3 | Add the responsive text chat shell | Mount, history, composer, queue, and cancel tests pass |
| 4 | Add resumable session event streaming | Ordering, replay, reconnect, and cursor-reset tests pass |
| 5 | Add safe Markdown and transcript actions | Adversarial rendering and browser-hook tests pass |
| 6 | Add activity and delegated-work projections | Lifecycle, cancellation, truncation, and redaction tests pass |
| 7 | Add memory and data-rights projections | Correction, confirmation, export, and deletion tests pass |
| 8 | Add voice through same-origin API proxies | Controller, JavaScript, and secure-browser drills pass |
| 9 | Add chat telemetry and failure isolation | Fault-injection and non-chat readiness tests pass |
| 10 | Enable the external chat interface | Staging acceptance matrix and `mix precommit` pass |

## Final acceptance drill

Run the final drill against a staging instance of the private API:

1. Sign in and open `/chat` in two browser tabs.
2. Send a message and verify that both tabs render the same user message, streaming response, and terminal state.
3. Send two more messages while the first turn runs and verify API-owned FIFO queueing.
4. Remove one queued turn, cancel the active turn, and verify that the remaining queued turn starts.
5. Disconnect the event stream, restore it, and verify cursor-based replay without duplicate messages.
6. Load older history and verify that the scroll position remains stable.
7. Render headings, lists, links, code blocks, partial Markdown, raw HTML, and unsafe URLs.
8. Run a tool and delegated-work flow and verify only bounded public activity appears.
9. Correct and forget a memory, export data, and exercise complete-deletion confirmation without exposing another account’s resources.
10. Start voice, speak, interrupt Sarah, mute, restore blocked playback, and end the call. Verify that typed chat remains available after each simulated voice failure.
11. Stop the private API and verify that `/chat` reports degradation while repository and issue pages remain healthy.
12. Inspect browser source, LiveView assigns, logs, and telemetry for service credentials, prompts, provider payloads, hidden tool arguments, and data from another account.
13. Run `mix precommit` and all JavaScript tests at the final SHA.

After this drill passes, `openagents.com` owns the complete public chat experience while `api.openagents.com` remains the private behavioral and data authority.
