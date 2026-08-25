# Rebase and restructure a stack

A stack stays useful only while its branches stay coherent. These actions
keep them that way, and every one of them runs on the server as a durable
operation rather than as a sequence of client-side pushes that can be
interrupted halfway.

All of them require write access to the repository.

## Rebase the stack

When the trunk moves, or a lower layer is rewritten, the layers above it go
stale. Click **Rebase the stack** on any stacked pull request page — it also
appears in the stale-boundary notice — or call `POST
/api/v1/repos/:owner/:repo/stacks/:stack_number/rebase`.

The rebase works bottom-to-top on the server:

1. It verifies every branch still points where the stack last observed it. A
   branch that moved since fails the operation instead of being silently
   overwritten.
2. It replays each layer's own commits onto the new base, keeping author
   identity. Server rebases are unsigned.
3. It moves every branch in one atomic batch. Either the whole stack moves or
   none of it does — a concurrent push to any stack branch makes the batch
   fail and preserves that push.

The pull request page shows the operation's progress — queued, running,
finished, or failed — with a **Check progress** button. Only one operation
can run per stack at a time; a second request while one is active returns the
active operation instead of starting another.

### Conflicts

A rebase that hits a conflict pauses rather than failing. The operation
reports which layer conflicted, and the API offers two ways out:

- `POST .../stacks/:stack_number/operations/:operation_id/continue` — resolve
  the conflict yourself, push the resolution commit, and pass its OID as
  `resolution_oid`. The operation verifies it and finishes the remaining
  layers.
- `POST .../stacks/:stack_number/operations/:operation_id/abort` — give up.
  No branch moves; the stack is exactly as it was.

Both re-verify branch heads before acting, so a resolution computed against
branches that have since moved is refused rather than applied.

## Remove the top layer

**Remove from stack** appears on the stack's top layer only. It detaches that
pull request from the stack — the pull request itself stays open and stops
being a layer. The equivalent API is `POST
/api/v1/repos/:owner/:repo/stacks/:stack_number/unstack` with
`{"pull_request": <number>}`.

Only the top layer can leave, because removing a middle layer would orphan
the branches above it. To take a middle layer out, remove layers from the top
down to it, or dissolve the stack.

## Grow the stack

`POST /api/v1/repos/:owner/:repo/stacks/:stack_number/append` adds one open
pull request on top. Its base branch must be the current top layer's head
branch.

## Dissolve the stack

`POST /api/v1/repos/:owner/:repo/stacks/:stack_number/dissolve` closes the
stack as an object while leaving every pull request open and every branch
where it is. Use it when the layers should continue as independent pull
requests.

A stack with an operation in flight refuses to unstack or dissolve until the
operation finishes.

These are the restructure operations available today. Reordering layers in
place is not supported — recreate the stack in the order you want instead.

## Next steps

- [Merging stacks](/docs/merging-stacks)
- [Stacks API](/docs/stacks-api)
