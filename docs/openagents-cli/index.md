# OpenAgents CLI

The OpenAgents CLI (`openagents`) manages OpenAgents-hosted Git repositories
from a terminal. It uses the same repository API as the OpenAgents web
interface and leaves Git data transfer to standard Git.

The CLI is available from npm. OpenAgents qualified repository imports on
staging before deploying the same server revision to the production fleet.

The same guides are published on the [OpenAgents documentation
site](https://openagents.com/docs/openagents-cli).

Install the CLI globally for regular use, or run a one-time command through
`npx`:

```sh
npm install --global @openagentsinc/cli
npx --yes @openagentsinc/cli@latest --version
```

Do not configure a persistent Git credential helper through `npx`. Install the
CLI globally before you run `openagents auth setup-git`.

## What you can do

The first release lets you:

- Sign in through your GitHub-backed OpenAgents account.
- Create a private or public repository in your GitHub user namespace.
- Create a repository in an eligible GitHub organization namespace.
- Import a GitHub repository as a one-time copy.
- List and inspect repositories that you can access.
- Clone repositories and configure Git authentication.
- Push, pull, and fetch through Git smart HTTP.
- Use JSON output and stable exit codes in scripts and agents.

Pull requests, repository deletion, continuous GitHub mirroring, SSH transport,
rulesets, and self-update are not part of this release.

## Namespaces and access

OpenAgents uses GitHub namespaces in the first release. When you sign in with
GitHub, your OpenAgents user namespace has the same login as your GitHub user.
Eligible organization namespaces use the same GitHub organization login. You
do not claim a separate OpenAgents namespace.

OpenAgents keys namespaces to GitHub's immutable account IDs. If a GitHub login
changes, OpenAgents can update the displayed login without changing the
repository's identity.

Creating or importing in an organization requires an active GitHub organization
membership with the organization administrator role. OpenAgents adds the
creator as the repository owner. It does not automatically grant access to
every member of the GitHub organization.

## Visibility and privacy

New repositories are private unless you explicitly select public visibility.
A public repository permits anonymous Git reads. A private repository is
visible only to authorized OpenAgents members, and unauthorized requests do
not reveal whether it exists.

OpenAgents stores GitHub access tokens on the server and never sends them to
the browser or the CLI. The CLI stores its OpenAgents API token in an approved
operating-system credential store, or reads it from `OPENAGENTS_TOKEN` for a
single environment.

Repository creation does not grant deployment or operator authority. The
deployment allowlist remains separate from hosted repositories.

## Manage repositories in the browser

After you sign in, open `/repositories` to see the repositories that you can
access.

- Select **New repository** to create an empty repository.
- Select **Import from GitHub** to copy one GitHub repository.
- Open a repository to see its clone URL, lifecycle state, Issues, Projects,
  code, and import receipt when applicable.

## Next steps

- [Install the CLI](install.md)
- [Create a repository](create-repository.md)
- [Import a GitHub repository](import-github.md)
- [Clone, push, and pull](git.md)
- [CLI command reference](command-reference.md)
