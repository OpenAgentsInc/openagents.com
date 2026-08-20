# API tokens

Tokens authenticate programmatic access to the REST API. Manage them at
[API tokens](/settings/api-tokens).

## Creating a token

Create a token and copy it immediately. Only a hash is stored, so the value
cannot be shown again — if you lose it, revoke it and create another.

## Using a token

Send it as a bearer token:

```
curl -H "Authorization: Bearer $OPENAGENTS_TOKEN" \
  https://openagents.com/api/v3/repos/OpenAgentsInc/openagents.com/issues
```

## Revoking

Revoking takes effect immediately. Any request in flight with that token fails
on its next call.

## Scope

A token acts as you. It reaches what your account reaches and nothing more.
