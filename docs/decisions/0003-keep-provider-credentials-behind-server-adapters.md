# ADR 0003: Keep provider credentials behind server adapters

Date: 2026-08-20

Status: Accepted

## Context

Text inference, embeddings, shadow programs, and realtime voice currently use
OpenAI implementations. Product lifecycle code must not depend on one
provider's transport, and browsers must not hold provider credentials.

## Decision

Define provider behavior through server-side adapters. Keep provider request
construction, credentials, transport, timeouts, bounded retries, response
validation, and error normalization behind those adapters. Keep durable turn,
voice, memory, and work policy in provider-independent OpenAgents contexts.

Never send a provider API key or internal-service credential to the browser.
Use explicit fake adapters for tests, and require adapters to redact secrets
from logs, receipts, telemetry, and user-visible errors.

## Consequences

- Direct OpenAI use remains an adapter choice rather than a product boundary.
- The application can replace a provider without rewriting durable lifecycle
  code.
- Browser compromise does not expose server credentials.
- Adapter contracts need conformance, timeout, and failure-path tests.
