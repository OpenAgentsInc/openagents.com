# GitHub authentication and token lifecycle

Date: 2026-08-20

Status: Implemented and locally verified for Gate 6

Decision: [ADR 0004](decisions/0004-retain-scoped-github-access-tokens.md)

## Current contract

GitHub serves two distinct roles:

1. OAuth establishes the local OpenAgents account identity from GitHub's
   immutable numeric user ID.
2. A retained access token authorizes server-side GitHub repository tools with
   the user's delegated rights.

The application implements the second model only after the person chooses the
button labeled **Sign in and enable GitHub tools** beside a retention
disclosure. The callback stores the access token as versioned AES-256-GCM
ciphertext in the local user row. It does not discard the token after reading
the GitHub profile.

The OAuth app requests only `repo`. GitHub exposes public profile identity with
no OAuth scope, so the redundant `read:user` scope is not requested. The
repository tools need to read repositories the user authorizes, including
private repositories. GitHub OAuth Apps do not offer read-only source-code
access, so `repo` is the narrowest OAuth App scope that satisfies that feature
even though the scope grants broad read/write repository and related project
rights. The consent UI says so. OpenAgents exposes only its bounded read tools
to this credential. A future GitHub App migration should replace this broad scope with
fine-grained, repository-selected read permissions. See GitHub's
[OAuth scope reference](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps)
and [authorization guidance](https://docs.github.com/en/apps/oauth-apps/using-oauth-apps/authorizing-oauth-apps).

## Implemented flow

1. `POST /auth/github?github_tools=enabled` refuses a request that does not
   carry the explicit tools choice, then creates a high-entropy state value, a PKCE S256
   challenge, and a short-lived PostgreSQL OAuth-attempt row.
2. The encrypted browser session carries only the attempt reference and PKCE
   verifier while GitHub handles authorization.
3. `GET /auth/github/callback` consumes the attempt exactly once, exchanges the
   code server-side, refuses missing or different granted scopes, and reads the
   GitHub `/user` projection server-side.
4. `OpenAgents.Accounts` upserts the local account by numeric GitHub ID and
   refreshes the mutable login, name, and avatar projection.
5. `OpenAgents.Accounts.TokenVault` encrypts the access token in a version-2
   envelope carrying the non-secret active key ID before the ciphertext is
   stored. The row also records scopes and connection/rotation timestamps.
6. The authenticated session contains only the local user ID. Repository tools
   unseal the token server-side when an explicit GitHub operation needs it.
7. `DELETE /logout` clears the browser session but intentionally does not
   revoke the retained GitHub grant.
8. `DELETE /github/connection` authenticates the browser and uses the OAuth
   application's Basic-authenticated token-deletion endpoint. Local ciphertext
   is cleared only after GitHub returns `204`; a provider or configuration
   failure preserves the local record so the revocation can be retried. GitHub
   documents the endpoint in its
   [OAuth authorization REST API](https://docs.github.com/en/rest/apps/oauth-applications#delete-an-app-token).

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

Rows migrated from the pre-Gate-6 envelope retain `read:user,repo` metadata
because that is the grant they actually received. Before staging admission,
revoke those legacy grants and have their owners reconnect under `repo` only;
do not rewrite metadata to claim a provider-side scope reduction that did not
occur.

## Rotation and data rights

Rotate without losing access to existing ciphertext:

1. Generate a new 32-byte key and a new environment-specific key ID.
2. Make the new key active and put the prior ID/key in
   `GITHUB_TOKEN_DECRYPTION_KEYS_JSON`.
3. Prove release readiness, migrate, and run `bin/rotate-github-tokens`.
4. Verify `users.github_token_key_id` contains no prior ID, retain the rotation
   receipt/count, and remove the prior key in the following deploy.

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
