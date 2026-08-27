# Welcome

OpenAgents is a software forge with an agent layer on top of it. This
documentation covers the parts you can use today.

## What is here now

OpenAgents [hosts Git repositories](/docs/repositories) that you can create,
import from GitHub once, clone, push, pull, and browse. Use the browser or
[Coder](/docs/install-cli), the command-line agent, which installs as a single
binary.

The issue tracker includes issues, labels, milestones, assignees, and projects,
each with a browser view and a GitHub-compatible REST endpoint. Code browsing
renders files and commits in repositories that you can access.

[Pull requests](/docs/pull-requests) propose one branch into another, and
[stacks](/docs/stacked-pull-requests) order several of them so each builds on
the one before it.

Three surfaces describe the system itself rather than your work. The
[changelog](/docs/changelog) presents product releases. [Status](/status)
reports fleet health. The
[leaderboard](/leaderboard) ranks contributors by tokens.

## What is not here yet

Code review and webhooks are not built. A pull request can be opened, browsed
with its diff, commented on, and merged, but nothing records an approval, a
requested change, or a comment anchored to a line.

Where a page in these docs describes something, that thing exists and you can
click it — a documentation site that mixes shipped features with planned ones
leaves you unable to tell which half you are reading.

## Compatibility

The REST API is shaped after GitHub's. See [REST API](/docs/rest-api) for the
implemented repository, issue, and project endpoints and the documented
differences.
