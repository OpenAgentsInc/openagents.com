# GitHub authentication and token lifecycle

Date: 2026-08-20

Status: Implemented and locally verified for Gate 6

Decision: [ADR 0004](decisions/0004-retain-scoped-github-access-tokens.md)

## Current contract

GitHub serves two distinct roles that use separate grants:

1. Sign-in establishes the local OpenAgents account identity from GitHub's
   immutable numeric user ID. It requests only `user:email`.
2. The repository authorization flow requests the rights that server-side
   GitHub repository tools need: `repo,read:org`. A person starts it from the
   connect page (`/github/connect`) or from `openagents auth connect-github`,
   never automatically at sign-in.

The sign-in callback stores the email-scoped token as versioned AES-256-GCM
ciphertext in the local user row. It does not authorize repository imports,
organization membership checks, or other repository tools. Those operations
require the `repo,read:org` scope set to be present in the stored grant and
fail closed without it. Because GitHub reports the union of every scope an
application has ever been granted, the repository requirement is presence,
not exact equality: a returning account's grant may carry more than what the
request asked for, and the required set inside it is what matters.

GitHub exposes public profile identity without a scope. OpenAgents requests
`user:email` so sign-in can access the account's email address without asking
for repository access. A future GitHub App integration should use fine-grained,
repository-selected permissions for repository tools; until then, the classic
OAuth `repo` scope covers every repository the account can reach, and the
connect page says so. See GitHub's
[OAuth scope reference](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps)
and [authorization guidance](https://docs.github.com/en/apps/oauth-apps/authorizing-oauth-apps).

## Implemented flow

1. `POST /auth/github` creates a high-entropy state value, a PKCE S256
   challenge, and a short-lived PostgreSQL OAuth-attempt row. The attempt
   records its mode in the browser session: sign-in (the default, public) or
   repository (requires a signed-in account; a repository start from an
   anonymous visitor is refused).
2. The encrypted browser session carries only the attempt reference and PKCE
   verifier while GitHub handles authorization. The requested scope comes
   from the mode: `user:email` for sign-in, `repo,read:org` for repository.
3. `GET /auth/github/callback` consumes the attempt exactly once, exchanges the
   code server-side, validates the grant against the attempt's mode — exact
   `user:email` for sign-in, `repo,read:org` present for repository — and
   reads the GitHub `/user` projection server-side.
4. `OpenAgents.Accounts` upserts the local account by numeric GitHub ID and
   refreshes the mutable login, name, and avatar projection.
5. `OpenAgents.Accounts.TokenVault` encrypts the access token in a version-2
   envelope carrying the non-secret active key ID before the ciphertext is
   stored. The row also records scopes and connection/rotation timestamps.
6. The authenticated session contains only the local user ID. Repository tools
   reject a grant that does not contain their required scopes. A repository
   callback keeps the session, flashes success, and returns to
   `/github/connect`; a sign-in callback renews the session and lands where
   the person started.
7. `DELETE /logout` clears the browser session but intentionally does not
   revoke the retained GitHub grant.
8. `DELETE /github/connection` authenticates the browser and uses the OAuth
   application's Basic-authenticated token-deletion endpoint. Local ciphertext
   is cleared only after GitHub returns `204`; a provider or configuration
   failure preserves the local record so the revocation can be retried. GitHub
   documents the endpoint in its
   [OAuth authorization REST API](https://docs.github.com/en/rest/apps/oauth-applications#delete-an-app-token).

### The CLI connect flow

`openagents auth connect-github` starts a device authorization with `kind:
"github_connect"` against `POST /api/v1/device/authorizations` and prints the
connect-page URL with its code. The connect page shows the same request the
browser path shows, and the Connect GitHub button is the approval: starting
the repository authorization while the page carries the code claims the
device record for that account. The CLI then polls the unchanged token
endpoint; a `github_connect` claim answers `{"status": "connected",
"github_login": ...}` and mints no API token, because the retained GitHub
token never leaves the server. A `github:connect` scope is a request marker,
not an API scope: `ApiTokens.create/2` refuses it, and a device create that
mixes it with API scopes is refused.

The token must never enter LiveView assigns, HTML, JSON responses, logs,
telemetry, receipts, exception messages, build output, or exported account
data.

## Current configuration

Runtime configuration requires:

- `GITHUB_CLIENT_ID`
- `GITHUB_CLIENT_SECRET`
- `GITHUB_REDIRECT_URI`
- `GITHUB_TOKEN_ENCRYPTION_KEY`, a Base64-encoded 32-byte key
- `GITHUB_TOKEN_ENCRYPTION_KEY_ID`, a bounded non-secret identifier
- `GITHUB_TOKEN_DECRYPTION_KEYS_JSON`, an optional JSON object of at most 16
  environment-prefixed prior key IDs to Base64-encoded 32-byte keys during
  rotation; it must not repeat the active key ID

Production-mode validation requires an HTTPS callback with the configured
environment host. Tests use deterministic local configuration and fake Req
responses; they do not require a live GitHub credential.

Existing rows retain their recorded scope metadata because that is the grant
they actually received. Do not rewrite metadata to claim a provider-side scope
reduction that did not occur.

## Rotation and data rights

Rotate without losing access to existing ciphertext:

1. Generate a new 32-byte key and a new environment-specific key ID.
2. Make the new key active and put the prior ID/key in
   `GITHUB_TOKEN_DECRYPTION_KEYS_JSON`.
3. Prove release readiness, migrate, and run `bin/rotate-github-tokens`.
4. Verify `users.github_token_key_id` contains no prior ID, retain the rotation
   receipt/count, and remove the prior key in the following deploy.

This procedure rotates only the GitHub vault. The machine pairing vault seals
under its own `MACHINE_TOKEN_ENCRYPTION_KEY` and its records survive this
rotation unread and unmoved (`INVARIANTS.md`, VAULT-001; #192 records the
release where that was not true). Keep step 2's prior key in
`GITHUB_TOKEN_DECRYPTION_KEYS_JSON` until one pairing lifetime after the
rotation deploy: the pairing vault's decrypt fallback reads that keyring for
any pairing sealed while `config/runtime.exs` still bridged its key to the
GitHub key.

The rewrap is one database transaction and reports only a count. Any
unsealable row rolls the transaction back and emits no credential material.

Account export includes connection status, scopes, connection time, and
rotation time plus `credential_exported: false`. Product-data deletion removes
conversation, voice, and memory data but deliberately retains the GitHub grant
with the minimal account row; the deletion UI and export say so. **Disconnect
GitHub tools** is the explicit grant-deletion operation.

OAuth callback parameter logging is disabled at the router, sensitive
parameter names are globally filtered, and the staging log export must pass the
scanner documented in [Secrets and log handling](security/secrets-and-log-handling.md).

## Executable evidence

- `test/openagents/github_oauth_test.exs`
- `test/openagents/github_oauth/runtime_config_test.exs`
- `test/openagents/accounts_test.exs`
- `test/openagents/accounts/token_vault_test.exs`
- `test/openagents/github_test.exs`
- `test/openagents/tools/github_repo_tools_test.exs`
- `test/openagents_web/auth_controller_test.exs`
- `test/openagents_web/auth_gate_test.exs`
- `test/openagents/log_safety_test.exs`
- `test/openagents_web/route_authority_test.exs`

The complete route-authority and secret-handling acceptance criteria remain in
[the hardening plan](2026-08-20-integration-hardening-and-staging-readiness-recommendations.md).
