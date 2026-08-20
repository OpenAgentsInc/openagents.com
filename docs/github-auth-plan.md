# GitHub authentication and token lifecycle

Date: 2026-08-20

Status: Authentication implemented; token-lifecycle hardening pending Gate 6

Decision: [ADR 0004](decisions/0004-retain-scoped-github-access-tokens.md)

## Current contract

GitHub serves two distinct roles:

1. OAuth establishes the local OpenAgents account identity from GitHub's
   immutable numeric user ID.
2. A retained access token authorizes server-side GitHub repository tools with
   the user's delegated rights.

The application currently implements the second model. The callback stores the
access token as AES-256-GCM ciphertext in the local user row. It does not
discard the token after reading the GitHub profile. Documentation and data
rights must not claim otherwise.

## Implemented flow

1. `POST /auth/github` creates a high-entropy state value, a PKCE S256
   challenge, and a short-lived PostgreSQL OAuth-attempt row.
2. The encrypted browser session carries only the attempt reference and PKCE
   verifier while GitHub handles authorization.
3. `GET /auth/github/callback` consumes the attempt exactly once, exchanges the
   code server-side, and reads the GitHub `/user` projection server-side.
4. `OpenAgents.Accounts` upserts the local account by numeric GitHub ID and
   refreshes the mutable login, name, and avatar projection.
5. `OpenAgents.Accounts.TokenVault` encrypts the access token with the configured
   key before `github_token_ciphertext` is stored.
6. The authenticated session contains only the local user ID. Repository tools
   unseal the token server-side when an explicit GitHub operation needs it.
7. `DELETE /logout` clears the browser session but intentionally does not
   revoke the retained GitHub grant.

The token must never enter LiveView assigns, HTML, JSON responses, logs,
telemetry, receipts, exception messages, build output, or exported account
data.

## Current configuration

Runtime configuration requires:

- `GITHUB_CLIENT_ID`
- `GITHUB_CLIENT_SECRET`
- `GITHUB_REDIRECT_URI`
- `GITHUB_TOKEN_ENCRYPTION_KEY`, a Base64-encoded 32-byte key

Production-mode validation requires an HTTPS callback with the configured
environment host. Tests use deterministic local configuration and fake Req
responses; they do not require a live GitHub credential.

## Hardening required before staging

Gate 6 owns the remaining lifecycle and disclosure work:

- Request and document the minimum scopes needed by the enabled GitHub tools.
- Show a clear user disclosure that delegated repository access is retained
  encrypted after sign-in.
- Add an explicit disconnect operation that deletes the local ciphertext and,
  where GitHub supports it for this OAuth application, revokes the grant.
- Define what account data deletion does to the retained token. The current
  product-data deletion keeps the minimal local account row, so token removal
  must be implemented and tested rather than inferred.
- Support encryption-key rotation with a versioned envelope and a rehearsed
  rewrap path.
- Fail closed when the key is missing, malformed, or belongs to the wrong
  environment, without printing token or key material.
- Normalize revoked/expired token failures and require reauthorization without
  exposing GitHub response bodies.
- Add log and telemetry scans for token, code, state, verifier, and callback
  query leakage.
- Document the token's presence as metadata in export/delete disclosures
  without exporting the credential itself.

## Executable evidence

- `test/openagents/github_oauth_test.exs`
- `test/openagents/github_oauth/runtime_config_test.exs`
- `test/openagents/accounts_test.exs`
- `test/openagents/accounts/token_vault_test.exs`
- `test/openagents/github_test.exs`
- `test/openagents/tools/github_repo_tools_test.exs`
- `test/openagents_web/auth_controller_test.exs`
- `test/openagents_web/auth_gate_test.exs`

The complete route-authority and secret-handling acceptance criteria remain in
[the hardening plan](2026-08-20-integration-hardening-and-staging-readiness-recommendations.md).
