# API authentication

Date: 2026-08-20

## Forge API clients

`GET` routes under `/api/v3` are public projections of published forge data.
Every `POST`, `PUT`, `PATCH`, and `DELETE` route under `/api/v3` requires an
OpenAgents personal API token with exact `forge:write` scope.

Create a token in the authenticated browser at `/settings/api-tokens`. Choose a
name and a lifetime from 1 through 90 days. The `oa_pat_…` plaintext appears
once; OpenAgents stores only its SHA-256 digest. Send it as a bearer:

```sh
curl \
  --header "Authorization: Bearer $OPENAGENTS_API_TOKEN" \
  --header "Content-Type: application/json" \
  --data '{"title":"Example"}' \
  https://staging.openagents.com/api/v3/repos/OpenAgentsInc/openagents.com/issues
```

Do not put the token in a URL, command history, checked-in environment file, or
issue. Prefer an environment populated by the caller's credential store. The
server returns the same `401 invalid_api_token` response for missing,
malformed, expired, revoked, unknown, and wrong-scope credentials.

The settings page lists non-secret metadata and supports immediate revocation.
Account export includes the same metadata with `credential_exported: false`.
Product-data deletion retains API credentials until the person revokes them;
credential management is independent from conversation deletion.

### Account chat events

Use `POST /api/v3/chat/turns` to submit an account chat message and
`GET /api/v3/chat/events` to list its durable event journal. These routes use
the same account-scoped application service and ordered projection as `/chat`.
Both routes require a personal API token with the `chat:account` scope. A token
with only `forge:write` cannot read or submit account chat data.

Submit a message with this request:

```sh
curl \
  --header "Authorization: Bearer $OPENAGENTS_API_TOKEN" \
  --header "Content-Type: application/json" \
  --data '{"message":"Summarize my repository README.","reasoning":"high"}' \
  https://staging.openagents.com/api/v3/chat/turns
```

The server returns `202 Accepted` after it durably creates the run and its
first `user_message` event. Provider work continues asynchronously. The
response identifies the run and includes its initial `streaming` status,
reasoning effort, and start time.

List the account's event journal with this request:

```sh
curl \
  --header "Authorization: Bearer $OPENAGENTS_API_TOKEN" \
  https://staging.openagents.com/api/v3/chat/events
```

Each event contains an event ID, run ID, run-local sequence number, type,
payload, and observation time. The API orders runs by creation time and events
within each run by sequence number. It returns only the authenticated account's
conversation. A caller cannot select another account or gain access by
supplying a conversation or run ID.

The journal records user messages, reasoning deltas, tool calls and outcomes,
text deltas, and terminal provider-response events. The browser and API consume
this same journal, so they observe the same ordered lifecycle instead of
maintaining separate chat histories.

The terminal `response_completed` event serves as the provider-response
receipt. It retains the Responses output list, including reasoning items,
function calls, function-call identifiers, and encrypted reasoning state. A
later turn replays that output list before its new input and tool results. It
does not reconstruct the prior response from normalized assistant text.

OpenAgents recursively redacts credential-shaped fields before it persists an
event payload or terminal provider response. The same boundary applies before
a tool outcome reaches the provider or client. This redaction does not make
chat content public or nonsensitive: store the bearer token securely and treat
the event journal as account data.

## Browser JSON routes

`/api/tokens`, `/api/computers`, and `/api/computer-agent-jobs` support the
first-party browser interface. They require an active encrypted browser session
and CSRF protection. They are not a CLI authentication mechanism.

## Machines and internal inference

Controller pairing returns a poll secret that expires after 10 minutes and can
claim a machine credential once. Machine credentials are scoped to one owner,
machine, and tier; expire according to `OPENAGENTS_MACHINE_TOKEN_TTL_SECONDS`;
are stored only as digests after claim; allow one active channel registration;
and disconnect immediately on revocation or expiry.

The inference proxy accepts only a server-minted `sig_…` grant. Each grant is
scoped to a conversation and optional paired machine, expires, is
generation-fenced and revocable, and has call, token, and cost ceilings. It is
not an OpenAI credential and cannot select a model outside the grant.

`OpenAgentsWeb.RouteAuthority.inventory/0` is the executable inventory for
HTTP routes and endpoint sockets. The test gate fails when a new route does not
resolve to one of the admitted authority classes with a principal and scope.
