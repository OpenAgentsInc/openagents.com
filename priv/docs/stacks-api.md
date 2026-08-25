# Stacks API

The stack surface lives under `/api/v1` beside the rest of the
[REST API](/docs/rest-api). Reads are public on a public repository; writes
require an `oa_pat_` bearer token with `forge:write` scope and an
`Idempotency-Key` header.

## Routes

```text
GET  /api/v1/repos/:owner/:repo/pulls
GET  /api/v1/repos/:owner/:repo/pulls/:pull_number
POST /api/v1/repos/:owner/:repo/pulls
PATCH /api/v1/repos/:owner/:repo/pulls/:pull_number

GET  /api/v1/repos/:owner/:repo/stacks
GET  /api/v1/repos/:owner/:repo/stacks/:stack_number
POST /api/v1/repos/:owner/:repo/stacks
POST /api/v1/repos/:owner/:repo/stacks/:stack_number/append
POST /api/v1/repos/:owner/:repo/stacks/:stack_number/rebase
POST /api/v1/repos/:owner/:repo/stacks/:stack_number/merge
POST /api/v1/repos/:owner/:repo/stacks/:stack_number/unstack
POST /api/v1/repos/:owner/:repo/stacks/:stack_number/dissolve

GET  /api/v1/repos/:owner/:repo/stacks/:stack_number/operations/:operation_id
POST /api/v1/repos/:owner/:repo/stacks/:stack_number/operations/:operation_id/continue
POST /api/v1/repos/:owner/:repo/stacks/:stack_number/operations/:operation_id/abort

PUT  /api/v1/repos/:owner/:repo/pulls/:pull_number/merge-async
GET  /api/v1/repos/:owner/:repo/pulls/:pull_number/merge-async/:operation_id
```

## The stack payload

A stack read returns the stack's `number`, `trunk_ref`, `state`, `health`,
`version`, and its active `entries` in position order. Each entry carries its
`position` and the pull request's `number`, `head` (`ref` and `sha`), and
`base` (`ref` and `sha`), so one read gives you the complete chain and the
exact commits the stack has observed.

```sh
curl https://openagents.com/api/v1/repos/acme/api/stacks/1
```

## Idempotency

Every write takes an `Idempotency-Key`. Repeating a request with the same key
and the same body returns the original result instead of acting twice; the
same key with a different body is refused with `409 Conflict`. Use a fresh
UUID per intended action and retry with the same one on network failure.

## Optimistic concurrency

A stack's `version` increments on every structural change. Writes accept an
optional `expected_stack_version`, and the mutating operations verify branch
heads against what the stack last observed before moving anything. When
either check fails you get a conflict rather than a mutation built on a stack
you have not seen — read again, re-decide, and resubmit.

## Operations

Rebase and merge run as durable operations. The submitting request returns
`202 Accepted` with the operation, and `GET
.../operations/:operation_id` reports its `state`: `pending`, `running`,
`waiting_for_conflict_resolution`, `succeeded`, `partially_succeeded`,
`failed`, or `cancelled`. One operation runs per stack at a time; submitting
while one is active returns `409 Conflict` carrying the active
`operation_id`. A paused rebase resumes through
[`continue` or `abort`](/docs/stack-actions).

## Worked example

Create three chained pull requests, stack them, and merge the bottom two:

```sh
repo=https://openagents.com/api/v1/repos/acme/api
auth="Authorization: Bearer $OPENAGENTS_TOKEN"

# One pull request per layer: base of each is the head of the one below.
curl -X POST -H "$auth" -H "Content-Type: application/json" \
  -d '{"title": "Layer 1", "head": "layer-1",
       "head_repository": "acme/api", "base": "main"}' $repo/pulls
curl -X POST -H "$auth" -H "Content-Type: application/json" \
  -d '{"title": "Layer 2", "head": "layer-2",
       "head_repository": "acme/api", "base": "layer-1"}' $repo/pulls
curl -X POST -H "$auth" -H "Content-Type: application/json" \
  -d '{"title": "Layer 3", "head": "layer-3",
       "head_repository": "acme/api", "base": "layer-2"}' $repo/pulls

# Stack them bottom-first.
curl -X POST -H "$auth" -H "Content-Type: application/json" \
  -H "Idempotency-Key: $(uuidgen)" \
  -d '{"trunk_ref": "main", "pull_requests": [1, 2, 3]}' $repo/stacks

# Land layers 1 and 2; layer 3 restacks automatically.
curl -X POST -H "$auth" -H "Content-Type: application/json" \
  -H "Idempotency-Key: $(uuidgen)" \
  -d '{"pull_request_number": 2, "merge_method": "merge"}' $repo/stacks/1/merge
```

## Next steps

- [Stacked pull requests](/docs/stacked-pull-requests)
- [Merging stacks](/docs/merging-stacks)
- [REST API](/docs/rest-api)
