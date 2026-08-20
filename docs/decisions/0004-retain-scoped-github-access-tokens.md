# ADR 0004: Retain scoped GitHub access tokens in the server vault

Date: 2026-08-20

Status: Accepted; hardening required before staging

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
GitHub token as authority for OpenAgents-owned records. Revoke or delete the
token when the user disconnects GitHub, deletes their data, or loses account
access. Gate 6 must verify scopes, rotation, failure behavior, redaction, and
the disclosures shown to users.

## Consequences

- Authenticated repository tools can use the user's delegated GitHub rights.
- Token retention becomes an explicit data-handling obligation.
- Sign-in identity and repository authorization remain separate decisions.
- Documentation and deletion paths must describe the retained credential.
