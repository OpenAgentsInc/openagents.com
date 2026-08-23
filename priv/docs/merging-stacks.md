# Merging stacks

A stack merges bottom-first. You can land the whole stack or any contiguous
prefix of it — layers 1 and 2 while layer 3 is still in review — but never a layer
whose foundations have not landed.

Merging requires write access, and merge policy is evaluated against the
trunk for every layer. A layer's direct base being an intermediate branch
never relaxes what the trunk requires.

## Merge a prefix in one operation

`POST /api/v3/repos/:owner/:repo/stacks/:stack_number/merge` lands a
contiguous prefix as one operation:

```sh
curl -X POST \
  -H "Authorization: Bearer $OPENAGENTS_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: $(uuidgen)" \
  -d '{"pull_request_number": 118, "merge_method": "merge"}' \
  https://openagents.com/api/v3/repos/acme/api/stacks/1/merge
```

- `pull_request_number` names the highest layer to land. The operation
  merges the contiguous prefix from the bottom of the stack through that
  layer.
- `merge_method` is `merge`, `squash`, or `rebase`.
- `expected_stack_version` and expected head OIDs are optional guards; when
  supplied, a stack that moved since you read it fails the merge instead of
  landing something you did not review.

The request returns `202 Accepted` with a durable operation. Poll `GET
.../stacks/:stack_number/operations/:operation_id` until it succeeds or
fails. The trunk moves once for the whole prefix. Merged pull requests close as
merged, their entries leave the stack, and the layers above become the new
bottom.

## Merge one layer asynchronously

`PUT /api/v3/repos/:owner/:repo/pulls/:pull_number/merge-async` submits a
merge against one stacked pull request — it lands the contiguous prefix from
the bottom of the stack through that layer — and returns `202 Accepted`
immediately with an `operation_id` and a poll URL:

```sh
curl -X PUT \
  -H "Authorization: Bearer $OPENAGENTS_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: $(uuidgen)" \
  -d '{"merge_method": "squash"}' \
  https://openagents.com/api/v3/repos/acme/api/pulls/117/merge-async
```

Poll `GET .../pulls/:pull_number/merge-async/:operation_id` for the outcome.
`merge_status` is `pending` while the operation runs, then `merged` or
`failed`. `merge_method` defaults to `merge`. Repeating the request with the
same `Idempotency-Key` and body replays the same operation instead of
starting a second one; a different active operation on the stack returns
`409 Conflict` with that operation's id.

The submission is validated when it executes, not when it is accepted:
branch heads, stack membership, and merge policy are all checked at execution
time. An unstacked pull request cannot merge through this surface.

## Automatic restack after a partial merge

Landing a prefix rewrites the foundation under the remaining layers, so a
partial merge restacks them automatically: the remaining branches are rebased
onto the new trunk tip in the same coordinated fashion as
[Rebase the stack](/docs/stack-actions), and the stack's version advances.
The layers left behind stay reviewable without a manual cleanup step, and a
restack that would conflict fails the merge during planning — it never lands
the prefix and strands the rest.

## What atomic means here

Within one merge operation, the trunk either gains the whole requested prefix
or none of it — a conflict or policy failure partway lands nothing. It does
not mean the trunk pauses for you: another merge can land between your read
and your merge, which is what the `expected_stack_version` guard is for.

## Next steps

- [Stacked pull requests](/docs/stacked-pull-requests)
- [Stacks API](/docs/stacks-api)
