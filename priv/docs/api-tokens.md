# API tokens

Tokens authenticate programmatic access to the REST API. Manage them at
[API tokens](/settings/api-tokens).

The OpenAgents CLI normally obtains an API token through browser-assisted
device authorization and stores it in the operating-system credential store.
See [Install the CLI](/docs/install-cli) when you do not need to create a token
manually.

## Creating a token

Create a token and copy it immediately. Only a hash is stored, so the value
cannot be shown again — if you lose it, revoke it and create another.

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
