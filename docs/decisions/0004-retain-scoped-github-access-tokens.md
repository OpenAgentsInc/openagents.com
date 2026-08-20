# ADR 0004: Retain scoped GitHub access tokens in the server vault

Date: 2026-08-20

Status: Accepted and implemented

## Context

GitHub provides sign-in identity and user-authorized repository access. The
repository already encrypts OAuth access tokens so server-side repository tools
can act with the user's authority. Other documents incorrectly say that the
callback discards the token.

## Decision

Retain the minimum-scoped GitHub access token in the server-side token vault
for features that require GitHub repository access. Encrypt every token with an
operator-managed key, associate it with one active user, and never expose it to
LiveView assigns, browser payloads, logs, receipts, or telemetry.

Keep OpenAgents issue and project data in PostgreSQL; do not use a retained
GitHub token as authority for OpenAgents-owned records. Logout clears only the
browser session. Explicit disconnect revokes the GitHub token before clearing
the local envelope. Product-data deletion retains the grant and says so;
disconnect is the independent credential-deletion action.

Use a versioned envelope with an active key ID and a temporary prior-key map.
Rewrap all retained grants transactionally before retiring an old key. Export
connection metadata but never ciphertext or plaintext.

## Consequences

- Authenticated repository tools can use the user's delegated GitHub rights.
- Token retention becomes an explicit data-handling obligation.
- Sign-in identity and repository authorization remain separate decisions.
- Documentation and deletion paths must describe the retained credential.
- OAuth App `repo` is broader than the read tools need because GitHub offers no
  read-only private-source OAuth scope. Migrate to a fine-grained GitHub App
  before expanding the GitHub-backed tool surface.
- Public profile identity needs no scope, so do not add `read:user` to the
  retained-tools authorization request.
