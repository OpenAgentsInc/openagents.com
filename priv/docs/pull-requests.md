# Proposing and merging changes

A pull request proposes merging one branch into another. Browse a
repository's pull requests at `/:owner/:repo/pulls`, and open one to review
its changes at `/:owner/:repo/pulls/:number`.

## What a pull request holds

A pull request pairs an issue with a branch comparison. The issue carries the
title, description, comments, state, and a number that is unique within the
repository and shared with plain issues. The comparison names a head branch,
a base branch, and the exact commits each pointed at when the comparison was
last observed, so the review diff is reproducible rather than whatever the
branches happen to say later.

A new pull request starts as a draft. Publish it by clearing the draft flag
when it is ready for review.

## The review diff

The pull request page shows the changes the head branch adds over the base
branch, as a unified diff with per-file collapse. When the pull request
belongs to a [stack](/docs/stacked-pull-requests), the page adds a stack map
and a layer-aware diff so each layer reviews only its own changes.

## Create one through the API

Pull requests are created through the REST API. `POST
/api/v3/repos/:owner/:repo/pulls` takes:

- `title` — required.
- `head` — required; the branch the work lives on.
- `head_repository` — required; the `owner/name` of the repository holding
  `head`. You need write access to it.
- `base` — optional; defaults to the repository's default branch.
- `body` — optional description.
- `draft` — optional; defaults to `true`.

```sh
curl -X POST \
  -H "Authorization: Bearer $OPENAGENTS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"title": "Add rate limiting", "head": "rate-limit",
       "head_repository": "acme/api", "base": "main"}' \
  https://openagents.com/api/v3/repos/acme/api/pulls
```

`PATCH /api/v3/repos/:owner/:repo/pulls/:pull_number` updates `title`,
`body`, `state`, `draft`, and `base`. While a pull request is an active stack
member its base belongs to the stack, so a direct base edit is refused —
restructure the stack instead.

Pull requests can be switched off per repository. When they are off, creation
returns `409 Conflict`.

## Merging

Merging is currently a stack operation: a pull request merges through the
stack it belongs to, and a stack can be as small as one pull request. See
[Merging stacks](/docs/merging-stacks). A standalone merge button for
unstacked pull requests is not implemented yet.

## Next steps

- [Stacked pull requests](/docs/stacked-pull-requests)
- [Rebase and restructure a stack](/docs/stack-actions)
- [Stacks API](/docs/stacks-api)
