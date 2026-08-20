# Historical chat and inference service-split plan

Date: 2026-08-19

Status: Superseded on 2026-08-20 by
[the integrated architecture](architecture.md) and
[ADR 0001](decisions/0001-integrate-the-complete-public-application.md)

## Historical decision

This plan originally proposed that the public application own the `/chat`
interface while a private Sarah service owned persona, voice, and provider
logic. The implemented repository instead owns the complete product contract:
presentation, durable conversations and turns, persona artifacts, memory,
tools, delegated work, voice, data rights, and provider orchestration.

There is no required private Sarah API in the current architecture. Do not add
one based on this document.

## Requirements preserved from the plan

The rejected service boundary does not invalidate these provider-boundary
requirements:

- Provider credentials and internal-service credentials remain server-side.
- LiveView owns presentation, not outbound HTTP, token construction, retries,
  or provider-wire decoding.
- Provider adapters use bounded connect, response, inactivity, and total
  timeouts and normalize errors before they reach receipts or users.
- Every accepted turn is durable before provider work begins. Streaming,
  PubSub, and browser state are projections rather than authority.
- Resource ownership is derived from an authenticated server-side principal;
  a client-supplied conversation, turn, message, or session ID grants nothing.
- Model output and Markdown are untrusted and must be bounded and sanitized.
- Mutations and replayable provider events use durable identities and
  idempotency rules.
- Logs and operational telemetry exclude credentials, message content,
  transcripts, memory claims, raw tool payloads, and provider error prose.
- Voice permission is explicit, provider failure leaves typed chat available,
  and no provider key is sent to the browser.
- Network providers are replaced by explicit fakes in tests.

These requirements now apply to the in-process adapters and durable contexts
described by [docs/architecture.md](architecture.md). If an infrastructure
service is introduced later, it must remain behind one of those adapters and
must not take ownership of public product policy or data-rights behavior.

## Historical closeout

The proposed cross-service schemas, session bridge, signed user assertions,
and staged HTTP phases were never adopted as the product boundary. Their valid
security properties are covered by the provider, identity, turn, voice, and
release invariants in [INVARIANTS.md](../INVARIANTS.md). Current implementation
and staging work is tracked only in the
[integration hardening plan](2026-08-20-integration-hardening-and-staging-readiness-recommendations.md).
