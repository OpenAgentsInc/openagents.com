# API tokens

Tokens authenticate programmatic access to the REST API. Manage them at
[API tokens](/settings/api-tokens).

The OpenAgents CLI normally obtains an API token through browser-assisted
device authorization and stores it in the operating-system credential store.
See [Install the CLI](/docs/install-cli) when you do not need to create a token
manually.

`OPENAGENTS_TOKEN` must contain an OpenAgents user token that starts with
`oa_pat_`. `OPENAGENTS_AGENT_TOKEN` is for an internal agent runtime and does
not authenticate repository API or Git operations.

## Creating a token

Create a token and copy it immediately. Only a hash is stored, so the value
cannot be shown again — if you lose it, revoke it and create another.

Manual tokens do not expire by default. You can choose a 7-, 30-, or 90-day
lifetime. A manual token carries `account:write` for account APIs and
`forge:write` for repository APIs.

## Using a token

Send it as a bearer token:

```
curl -H "Authorization: Bearer $OPENAGENTS_TOKEN" \
  https://openagents.com/api/v3/repos/OpenAgentsInc/openagents.com/issues
```

## Revoke a token

Revoking takes effect immediately. Any request in flight with that token fails
on its next call.

## Understand the scope

A token acts as you. It reaches what your account reaches and nothing more.
The server derives your identity from the token and ignores caller-supplied
identity claims.

## Call chat programmatically

`POST /api/v1/chat/responses` uses the same model, repository tools, reasoning
events, and tool-result events as `/chat`.

```
curl https://openagents.com/api/v1/chat/responses \
  -H "Authorization: Bearer $OPENAGENTS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"input":"Read the README of my connected repository."}'
```

Add `"stream":true` to receive server-sent events.
