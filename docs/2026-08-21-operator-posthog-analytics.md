# Operator PostHog analytics

Date: 2026-08-21

Status: Implemented; activates when read credentials are configured

`/admin/analytics` gives operators the trailing-twenty-four-hour product
picture without opening PostHog. It exists because the numbers an operator
acts on should be one navigation away, rendered in this product's own
components, and gated behind the same operator boundary as every other admin
surface.

## How it works

The page pulls computed results from the PostHog REST API at request time.
`OpenAgents.PostHog` sends HogQL queries over a bearer-authenticated personal
API key and shapes the rows into plain maps. The surface adds no aggregation
of its own: what it renders is exactly what the PostHog app answers for the
same window, so there is no second authority that can drift from the source.

One pull runs four bounded questions:

1. **Activation funnel** — authorization starts, accounts created, returning
   sign-ins, first chat messages sent.
2. **Chat turns** — count, outcome breakdown (completed, failed, cancelled),
   average and longest turn duration.
3. **Event volume** — every event name with count and distinct people.
4. **Top pages** — the eight most-viewed URLs.

## Configuration

All settings are optional. Absent credentials disable the read path only;
event capture is configured separately and keeps working either way.

| Setting | Requirement |
| --- | --- |
| `OPENAGENTS_POSTHOG_PERSONAL_API_KEY` | A `phx_...` personal API key created for this integration |
| `OPENAGENTS_POSTHOG_PROJECT_ID` | The numeric PostHog project id |
| `OPENAGENTS_POSTHOG_APP_HOST` | Optional; defaults to `https://us.posthog.com`. This is the app/API host, not the event ingest host used for capture |

Create the key in PostHog user settings and grant only read scopes. Treat it
as analytics material: it never needs write access, and nothing on this page
requires more.

## States

The surface designs its non-happy states as first-class UI:

| State | Rendered as | Meaning |
| --- | --- | --- |
| Loading | Inline notice | Queries are in flight; no cached numbers are shown |
| Unconfigured | Warning notice naming the two missing settings | Credentials absent at boot; no requests are made |
| Unavailable | Danger notice with retry | PostHog did not answer; nothing stale is rendered |
| Loaded | Cards and tables | Fresh pull with a generated-at stamp |

Refresh re-runs all four questions and replaces the whole projection.

## Boundaries

- Operator-gated like `/admin`: the route requires the configured operator
  GitHub IDs and is classified `analytics:read` in the route authority
  inventory.
- Aggregates only. No conversation content, memory claims, or message text is
  reachable from this page; the queries select counts, durations, and URLs.
- A failed query fails the whole pull. Partial numbers presented side by side
  read as complete, so the page refuses to render them.

## Testing

`test/openagents/posthog_test.exs` covers shaping, authentication headers,
transport failures, and the disabled path against a stubbed transport.
`test/openagents_web/live/admin_analytics_live_test.exs` covers the access
gates and all three non-loaded states plus refresh.

## Related

- [PostHog integration runbook](2026-08-21-posthog-integration-runbook.md) —
  the instrumentation this surface reads
