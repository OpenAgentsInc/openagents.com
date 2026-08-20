# Status API

[`/api/status`](/api/status) returns the same projection the
[status page](/status) renders, as JSON.

## Shape

A schema version, fleet node states, and the forge pipeline with its loop
metric. The schema version is part of the contract: a consumer should read it
and refuse a version it does not know rather than guess.

## Disclosure

Identical to the status page. Counts, states, and durations; no operator
identities, module names, hostnames, or repository paths. It is unauthenticated,
so it is safe to poll from anywhere.

## Polling

There is no rate limit today. The projection is cached, so polling more often
than it refreshes returns the same payload.

## Related

[`/api/changelog`](/api/changelog) serves the changelog under the same rules.
