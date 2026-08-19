# Chat and inference plan

Date: 2026-08-19

Status: Planned

## Outcome

OpenAgents serves the `/chat` user interface and the core chat and inference logic from this public repository. The repository owns the presentation layer, the conversation and turn lifecycle, inference orchestration, memory, tools, and delegated work. The `pro.openagents.com` service owns only the Sarah persona, voice orchestration, and provider integrations that are specific to the Sarah product.

This repository includes:

- The `/chat` LiveView route and responsive shell.
- `OpenAgents.Conversations`, `OpenAgents.Turns`, `OpenAgents.Messages`, `OpenAgents.Receipts`, `OpenAgents.Tools`, `OpenAgents.Memory`, `OpenAgents.Agents`, and `OpenAgents.Delegation`.
- Server-side inference orchestration with the existing `Req` library.
- Public projections of tool activity, delegated work, memory, privacy controls, and voice state.
- Same-origin proxy endpoints where browser media or downloads require an HTTP endpoint.
- Tests, fixtures, accessibility behavior, and operational status.

The `pro.openagents.com` service includes:

- Sarah prompts, persona instructions, reasoning policy, and model selection.
- Voice-provider session orchestration, usage limits, and recording storage.
- Data-rights exports and deletions that cross the Sarah service boundary.

## Architecture

```text
browser
  |
  | LiveView WebSocket and same-origin HTTP
  v
openagents.com
  - OpenAgentsWeb.ChatLive
  - chat components and browser hooks
  - OpenAgents.Conversations, OpenAgents.Turns, OpenAgents.Messages
  - OpenAgents.Inference, OpenAgents.Tools, OpenAgents.Memory
  - OpenAgents.Delegation, OpenAgents.Agents
  |
  | HTTPS, service authentication, user assertion
  v
pro.openagents.com
  - Sarah persona and prompts
  - voice orchestration and recordings
  - data-rights back-end
```

The browser does not receive provider credentials. `openagents.com` makes server-side calls to inference providers and to `pro.openagents.com` for Sarah-specific and voice-specific behavior. Public projections are sent to the browser through LiveView.

## Ownership boundary

| Concern | `openagents.com` application | `pro.openagents.com` service |
| --- | --- | --- |
| User authentication | Establishes the browser session and stable user subject | Verifies the signed user assertion and enforces resource ownership |
| Agent identity | Renders returned display metadata such as `Sarah` | Selects persona, prompts, models, and behavior |
| Conversation state | Stores conversations, turns, messages, receipts, and cursors | Receives a bounded context from `openagents.com` for Sarah turns |
| Turn ordering | Accepts, validates, orders, rate-limits, and executes turns | Receives ordered turn context from `openagents.com` |
| Streaming | Resumes and projects versioned events to the browser | Returns ordered, replayable events for Sarah and voice |
| Markdown | Parses and sanitizes assistant text for display | Returns plain Markdown, never trusted HTML |
| Tool activity | Executes tools and renders bounded display-safe activity | Receives tool results for Sarah turns |
| Delegated work | Starts agents, controls machines, stores outcomes, and authorizes cancellation | Receives work updates that affect Sarah responses |
| Memory | Extracts, stores, searches, corrects, forgets, and audits memory | Receives memory context for Sarah turns |
| Voice | Manages browser media controls and same-origin requests | Admits sessions, connects providers, enforces limits, and stores recordings |
| Data rights | Presents confirmation and streams downloads | Exports or deletes the authenticated user’s durable data |
| Observability | Records content-free client and transport metrics | Records model, tool, policy, and durable execution metrics |

## Security invariants

Implement these rules before enabling `/chat` in production:

- **The browser never receives service or provider credentials.** Store them in runtime configuration and use them only in server-side adapters.
- **Every resource is user-scoped.** The back-end derives ownership from a verified assertion and does not trust a conversation or message ID by itself.
- **Service assertions are short-lived and signed.** Send them in `Authorization: Bearer <token>` over TLS to `pro.openagents.com`.
- **Model output is untrusted.** Parse Markdown through an allowlist, escape every text node, reject unsafe URL schemes, and never render untrusted HTML.
- **Events are ordered and resumable.** Every session event carries a monotonically increasing sequence and opaque cursor.
- **Mutations are idempotent.** Turn creation, cancellation, memory actions, recording chunks, and deletion requests use idempotency keys.
- **Logs are content-free by default.** Log request IDs, status codes, durations, byte counts, and error codes without message content or memory claims.
- **Destructive actions require explicit confirmation.** The UI states the scope, and the back-end revalidates the confirmation.
- **Voice requires a secure context and explicit microphone access.** A voice failure leaves typed chat available.
- **Feature capabilities come from the service.** The UI does not infer that memory, tools, delegation, recording, or voice is available.

## Authentication contract

Reuse the authenticated browser pipeline and `live_session` from `docs/github-auth-plan.md` for `/chat`.

1. Pass `current_scope` to `<Layouts.app>` and derive a stable, non-email user subject from it.
2. Create a short-lived service assertion for every request to `pro.openagents.com` or for a voice session. Use a signed JWT or workload-identity token with these claims:
   - `iss`: `openagents.com`
   - `aud`: `pro.openagents.com`
   - `sub`: the stable OpenAgents user ID
   - `sid`: the browser-session identifier
   - `scope`: the minimum scopes required for the request
   - `iat` and `exp`: a short validity window
   - `jti`: a unique token identifier
3. Send the assertion in `Authorization: Bearer <token>` over TLS.
4. Send a content-free `X-Request-ID` for correlation.
5. Rotate signing keys without a deploy. Keep the active key ID in the token header and publish verification keys through operator-managed configuration.

`pro.openagents.com` verifies signature, issuer, audience, expiration, scope, and resource ownership on every request. It must not accept user identity from an unsigned forwarding header.

Tests use a fake signer and fake `pro.openagents.com` adapter. They never require a production credential.

## Versioned API contract with `pro.openagents.com`

Use `/v1` for the cross-service contract. Every JSON object includes a `schema` field. Treat unknown fields as additive, but reject unknown schema major versions.

### Turn run

`POST /v1/sarah/turns/{turn_id}/run` starts a Sarah turn from the context that `openagents.com` has already built.

Request:

```json
{
  "schema": "openagents.sarah.turn_request.v1",
  "user_id": "user_opaque_id",
  "session_id": "session_opaque_id",
  "turn_id": "turn_opaque_id",
  "messages": [
    {
      "schema": "openagents.chat.message.v1",
      "id": "msg_opaque_id",
      "turn_id": "turn_opaque_id",
      "role": "user",
      "content": "Help me plan this change.",
      "created_at": "2026-08-19T21:00:00Z"
    }
  ],
  "memory": [...],
  "tools": [...],
  "capabilities": {
    "text": true,
    "voice": false
  }
}
```

Response is a server-sent event stream. The `pro.openagents.com` service returns:

- `message.upsert` for the assistant reply.
- `turn.upsert` for active or queued turn state.
- `activity.upsert` for display-safe tool activity.
- `voice.updated` when voice state changes.

When the stream returns `410 Gone` for an expired cursor, `openagents.com` fetches a fresh context and restarts from the last known state.

### Voice session

`POST /v1/sarah/voice/sessions` starts a voice session. `openagents.com` relays the browser SDP and receives a provider session. The browser may establish the resulting WebRTC media path directly, but it never receives a provider API key.

## Public module layout

Use one module per file. Keep HTTP transport outside the LiveView.

```text
lib/openagents/conversations.ex
lib/openagents/conversations/conversation.ex
lib/openagents/conversations/message.ex
lib/openagents/turns.ex
lib/openagents/turns/turn.ex
lib/openagents/turns/receipt.ex
lib/openagents/inference.ex
lib/openagents/tools.ex
lib/openagents/tools/tool.ex
lib/openagents/tools/tool_step.ex
lib/openagents/memory.ex
lib/openagents/memory/record.ex
lib/openagents/agents.ex
lib/openagents/delegation.ex
lib/openagents/sarah.ex
lib/openagents/sarah/req_client.ex
lib/openagents/sarah/turn.ex
lib/openagents/sarah/voice.ex
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

`OpenAgents.Sarah` defines a behaviour for Sarah turn and voice operations. `OpenAgents.Sarah.ReqClient` implements it with the existing `Req` dependency. Tests select `OpenAgents.Sarah.Fake` through application configuration.

Do not put HTTP calls, token creation, response decoding, or retry rules directly in `OpenAgentsWeb.ChatLive`.

## Session bridge

Use one supervised bridge per `{user_subject, session_id}` to avoid one back-end event stream per browser tab.

1. Start `OpenAgents.Sarah.SessionRegistry` and `OpenAgents.Sarah.SessionSupervisor` in `OpenAgents.Application` after `OpenAgents.PubSub`.
2. Start or find a `SessionBridge` when an authenticated LiveView connects.
3. Let the bridge open the `pro.openagents.com` event stream from the session cursor.
4. Decode bounded frames and broadcast public DTO events on a PubSub topic derived from the opaque session ID.
5. Track the last confirmed cursor in bridge state.
6. Reconnect with exponential backoff and jitter after transport failure.
7. Request a fresh snapshot after `410 Gone`, invalid ordering, or an unrecoverable parse error.
8. Stop the bridge after the last local subscriber leaves and a short grace period expires.

The bridge holds only bounded public projections and cursor state. It does not persist message content in the public database; `OpenAgents.Conversations` owns persistence.

## Phase 1: Chat shell and authentication

1. Reuse the authenticated browser pipeline and `live_session` from `docs/github-auth-plan.md` for `/chat`.
2. Add `OpenAgents.Conversations` and `OpenAgents.Turns` with Ecto schemas.
3. Add `OpenAgents.Sarah` and `OpenAgents.Sarah.ReqClient` with a configured `pro.openagents.com` base URL.
4. Add `OpenAgentsWeb.ChatLive` with a composer, transcript scroller, and connection state.
5. Add service assertion creation and credential redaction.
6. Configure connection, first-byte, inactivity, and total-request timeouts by operation.
7. Add a fake Sarah implementation and representative JSON and event fixtures under `test/support`.

**Exit criteria:** tests cover authenticated access, session creation, message send, turn state, timeout, malformed JSON, unknown schema version, and retry.

## Phase 2: Streaming and tool activity

1. Implement the session bridge and SSE decoder.
2. Apply events idempotently by session ID, resource ID, and event sequence.
3. Ignore events for another session.
4. Reconcile optimistic form state with authoritative `message.upsert` and `turn.upsert` events.
5. Reset streams from `session.snapshot` after cursor expiry.
6. Add `OpenAgents.Tools` for tool execution and `OpenAgents.Tools.ToolStep` for activity projection.

**Exit criteria:** LiveView tests prove streaming, reconnect, tool activity, and cancellation.

## Phase 3: Memory and delegation

1. Add `OpenAgents.Memory` for record extraction, retrieval, ranking, correction, and deletion.
2. Add `OpenAgents.Delegation` for starting and tracking agent work.
3. Add `OpenAgents.Agents` for agent selection and authorization.
4. Surface memory and delegated work in the chat UI.

**Exit criteria:** users can save, search, correct, delete memory records, and start, monitor, and cancel delegated work.

## Phase 4: Voice

1. Add `OpenAgents.Sarah.Voice` for voice session creation.
2. Add `OpenAgentsWeb.ChatVoiceController` for same-origin voice setup.
3. Add `OpenAgentsWeb.Components.ChatVoice` for media controls.
4. Add the browser voice JavaScript.

**Exit criteria:** authenticated users can start a voice session, send audio, and receive assistant audio without ever seeing a provider credential.
