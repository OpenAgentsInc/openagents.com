# API authentication

Date: 2026-08-22

## Account API clients

Create a token at `/settings/api-tokens`. Manual tokens carry `account:write`
and `forge:write`, do not expire by default, and act with the issuing account's
authority. You can select a 7-, 30-, or 90-day lifetime when a client requires
rotation. The `oa_pat_…` plaintext appears once; OpenAgents stores only its
SHA-256 digest.

Use `account:write` to call the same chat runtime that serves `/chat`:

```sh
curl https://openagents.com/api/v1/chat/responses \
  --header "Authorization: Bearer $OPENAGENTS_API_TOKEN" \
  --header "Content-Type: application/json" \
  --data '{"input":"Read my repository README.","reasoning":{"effort":"high"}}'
```

Set `"stream":true` to receive server-sent events for reasoning, tool calls,
tool results, response text, and terminal completion. The server selects the
model and tools. The token supplies the account identity, so a caller cannot
claim another user's repository authority.

## Forge API clients

`GET` routes under `/api/v3` are public projections of published forge data.
Every `POST`, `PUT`, `PATCH`, and `DELETE` route under `/api/v3` requires an
OpenAgents personal API token with exact `forge:write` scope.

Send a token with `forge:write` as a bearer:

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
