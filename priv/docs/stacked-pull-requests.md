# Stacked pull requests

A stack is an ordered series of dependent pull requests that merge
bottom-first into one trunk branch. Each layer's branch is based on the layer
below it, so a large change ships as several small reviews without losing the
dependency structure between them.

## Why stack

One big pull request is hard to review, and splitting it into independent
pull requests loses the ordering. A stack keeps both properties:

- Each layer is a small, focused review that shows only its own changes.
- The order is explicit. Layer 3 cannot land before layer 2, and the forge
  enforces that rather than trusting reviewers to remember it.
- Branch maintenance cascades. When the trunk or a lower layer moves, one
  server-side rebase moves every branch above it at once.

## The shape of a stack

A stack is a first-class object, not a naming convention. It holds:

- A **trunk** — the branch the whole stack eventually merges into, usually
  the default branch.
- **Ordered layers** — positions count up from 1 nearest the trunk. Each
  layer is one open pull request whose base branch is the head branch of the
  layer below (the bottom layer's base is the trunk).
- A **number** — unique within the repository, like an issue number.
- A **version** — increments on every structural change, so concurrent
  writers can detect that the stack moved underneath them.
- A **health** — `healthy`, or stale when a lower branch was rewritten and
  the layers above it need a rebase before their diffs are trustworthy.

Every layer keeps two bases. The *direct base* is the branch directly below,
and it defines what the layer's own review shows. The *effective base* is the
trunk, and it is what merge policy evaluates against — an intermediate branch
is never a policy target, so stacking cannot be used to slip changes past the
rules that protect the trunk.

## The stack map

Every pull request in a stack shows a stack map: the ordered rail of layers
with the newest on top, a state glyph per layer, the current layer
highlighted, and a trunk row that links to the trunk's file tree. Click any
other layer to jump to its pull request.

Below the map, a readiness line summarizes the whole stack — how many layers
are ready to merge bottom-first, how many are still drafts, or that the stack
needs a rebase first.

Members with write access also see the stack actions here. See
[Rebase and restructure a stack](/docs/stack-actions).

## Layer and cumulative review

A stacked pull request's diff has two views:

- **This layer** — the changes this layer adds over the layer below it. This
  is the default review view, computed from the boundary the stack recorded,
  so it shows only this layer's work even while other layers move.
- **Cumulative** — everything the stack contains through this layer,
  measured from the current trunk tip. Because the comparison starts at the
  *current* trunk, this view also picks up drift when the trunk has moved
  since the stack was created; it answers "what would the trunk gain", not
  "what did this author write".

When a lower layer is rewritten, the layer view above it becomes untrustworthy.
The page says so explicitly and offers the rebase action instead of showing a
diff that silently mixes in another layer's changes.

## Create a stack

Open the pull requests so their branches form a chain — each head is the next
base — then create the stack through the API:

```sh
curl -X POST \
  -H "Authorization: Bearer $OPENAGENTS_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: $(uuidgen)" \
  -d '{"trunk_ref": "main", "pull_requests": [117, 118, 119]}' \
  https://openagents.com/api/v3/repos/acme/api/stacks
```

The order in `pull_requests` runs bottom-first. Creation validates the whole
structure — every pull request open, in this repository, unduplicated, and
chained base-to-head — and refuses anything else. A stack holds at most 100
layers. See [Stacks API](/docs/stacks-api) for the full surface.

## Next steps

- [Rebase and restructure a stack](/docs/stack-actions)
- [Merging stacks](/docs/merging-stacks)
- [Stacks API](/docs/stacks-api)
