# Repository hosting

OpenAgents hosts Git repositories and serves them through Git smart HTTP. You
can create, import, browse, and delete repositories in the browser, and you can
do the same work from a terminal with the
[OpenAgents CLI](/docs/openagents-cli).

## What you can do

The current release lets you:

- Create a private or public repository in your GitHub user namespace.
- Create a repository in an eligible GitHub organization namespace.
- Import a GitHub repository as a one-time copy.
- List and inspect repositories that you can access.
- Clone, push, pull, and fetch with standard Git.
- Delete a repository you own with explicit confirmation.

The current release does not provide continuous GitHub mirroring, SSH
transport, or rulesets.

## Understand namespaces and access

OpenAgents uses GitHub namespaces in this release. Your OpenAgents user
namespace matches your GitHub login. Eligible organization namespaces match
the GitHub organization login.

OpenAgents keys namespaces to GitHub's immutable account IDs. If a GitHub login
changes, OpenAgents can update the displayed login without changing the
repository's identity.

Creating or importing in an organization requires an active GitHub
organization administrator membership. OpenAgents adds the creator as the
repository owner. It does not automatically grant access to every member of
the GitHub organization.

## Understand visibility and credentials

New repositories are private unless you explicitly make them public. Anyone
can clone and fetch a public repository. Only authorized OpenAgents members can
see a private repository, and an unauthorized request does not reveal whether
the repository exists.

OpenAgents stores the GitHub access token used for GitHub operations on the
server. It never sends that token to the browser or the CLI. The CLI stores its
OpenAgents API token in the operating-system credential store or reads it from
`OPENAGENTS_TOKEN` for the current process.

Repository access does not grant deployment or operator authority.

## Manage repositories in the browser

After you sign in, open [Repositories](/repositories).

- Select **New repository** to create an empty repository.
- Select **Import from GitHub** to copy one GitHub repository.
- Open a repository to see its clone URL, lifecycle state, code, Issues,
  Projects, and import receipt when applicable.
- Open a repository's **Delete repository** section to permanently delete a
  repository you own.

## Next steps

- [Create a repository](/docs/create-repository)
- [Import from GitHub](/docs/import-github)
- [Clone, push, and pull](/docs/clone-push-pull)
- [Delete a repository](/docs/delete-repository)
- [The OpenAgents CLI](/docs/openagents-cli)
