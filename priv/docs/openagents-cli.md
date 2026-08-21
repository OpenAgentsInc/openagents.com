# Repositories and the OpenAgents CLI

OpenAgents hosts Git repositories and serves them through Git smart HTTP. You
can create and import repositories in the browser or manage them from a
terminal with the OpenAgents CLI (`openagents`).

## What you can do

The current release lets you:

- Create a private or public repository in your GitHub user namespace.
- Create a repository in an eligible GitHub organization namespace.
- Import a GitHub repository as a one-time copy.
- List and inspect repositories that you can access.
- Clone repositories and configure Git authentication.
- Delete a repository you own with explicit confirmation.
- Push, pull, and fetch with standard Git.
- Use JSON output and stable exit codes in scripts and agents.

The current release does not provide pull requests, continuous GitHub
mirroring, SSH transport, rulesets, or a self-update command.

## Choose how to run the CLI

Install the CLI globally when you use it regularly or when you want to
configure Git authentication that remains available after the current command:

```sh
npm install --global @openagentsinc/cli
openagents --version
```

Use `npx` for one command without a global installation:

```sh
npx --yes @openagentsinc/cli@latest --version
npx --yes @openagentsinc/cli@latest repo list
```

Do not configure a persistent Git credential helper through `npx`. The helper
configuration refers to the `openagents` executable, but the temporary `npx`
executable disappears when the command ends. Install the CLI globally before
you run `openagents auth setup-git --local` or
`openagents auth setup-git --global --yes`.

See [Install the CLI](/docs/install-cli) for authentication, profiles,
configuration, and the complete `npx` guidance.

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

## Follow a common terminal workflow

1. Install and sign in:

   ```sh
   npm install --global @openagentsinc/cli
   openagents auth login
   openagents auth status
   ```

2. Create or import a repository:

   ```sh
   openagents repo create my-project
   # Or copy a GitHub repository once:
   openagents repo import OWNER/REPOSITORY
   ```

3. Clone and configure standard Git:

   ```sh
   openagents repo clone OWNER/REPOSITORY
   cd REPOSITORY
   openagents auth setup-git --local
   git pull --ff-only
   git push
   ```

## Next steps

- [Install the CLI](/docs/install-cli)
- [Create a repository](/docs/create-repository)
- [Import from GitHub](/docs/import-github)
- [Clone, push, and pull](/docs/clone-push-pull)
- [Delete a repository](/docs/delete-repository)
- [CLI command reference](/docs/cli-command-reference)
