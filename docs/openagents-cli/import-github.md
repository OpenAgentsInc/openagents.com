# Import a GitHub repository

Import copies one accepted GitHub snapshot into a new OpenAgents repository.
It does not create a mirror or continue synchronizing with GitHub.

## Prerequisites

You need:

- An OpenAgents account connected to GitHub.
- A current GitHub connection with the `repo` and `read:org` grants.
- Read access to the source GitHub repository.
- An eligible destination namespace that matches the GitHub source owner.
- An active GitHub organization administrator membership for an organization
  destination.

If your existing GitHub connection lacks the required grants, reconnect it
before importing.

## Import in the browser

1. Sign in to OpenAgents with GitHub.
2. Open `/repositories`.
3. Select **Import from GitHub**.
4. Choose a repository from the bounded GitHub repository list.
5. Confirm the matching destination namespace.
6. Keep the source name or enter a different destination repository name.
7. Choose **Private** or **Public**. Private is the default, even when the
   GitHub source is public.
8. Review any Git LFS warning.
9. Select **Import repository**.

The import page shows the accepted snapshot and bounded lifecycle state. It
does not expose raw Git output or a GitHub token.

## Import with the CLI

Import a repository into its matching namespace:

```sh
openagents repo import OpenAgentsInc/example
```

Choose a different destination name:

```sh
openagents repo import OpenAgentsInc/example --name example-copy
```

Create a public destination explicitly:

```sh
openagents repo import OpenAgentsInc/example --public
```

You can state the matching organization explicitly:

```sh
openagents repo import OpenAgentsInc/example --namespace OpenAgentsInc
```

The `--namespace` value must match the GitHub source owner in this release. You
cannot import `SOURCE/repository` directly into an unrelated namespace.

The CLI waits up to 300 seconds by default. Pass `--wait-timeout 0` to return
after the server accepts the durable import. A client timeout does not cancel
the server-side import.

## Verify the first production import

Use a small private GitHub repository for the first production import. Include
a second branch and an annotated tag so you can verify the accepted ref
snapshot. If the repository uses Git LFS, expect OpenAgents to preserve the
pointer files without copying the LFS objects.

1. Install the qualified CLI version:

   ```sh
   npm install --global @openagentsinc/cli@0.1.0
   ```

2. Sign in to production and confirm the selected account:

   ```sh
   openagents --profile production auth login
   openagents --profile production auth status
   ```

3. Start one private import and wait for the durable result:

   ```sh
   openagents --profile production repo import OWNER/REPOSITORY --private --wait-timeout 300
   ```

4. Confirm that the repository is ready, then clone it:

   ```sh
   openagents --profile production repo view OWNER/REPOSITORY
   openagents --profile production repo clone OWNER/REPOSITORY
   ```

5. Compare the cloned branches and tags with the accepted GitHub snapshot.
   Confirm that a later GitHub commit does not appear in the OpenAgents copy.

The release process does not create a production repository automatically.
An authenticated operator starts the first production import explicitly.

## What the import copies

| Copied | Not copied |
| --- | --- |
| Git commit and object history reachable from accepted refs | GitHub Issues |
| `refs/heads/*` branches | Pull requests and reviews |
| `refs/tags/*` tags | Actions workflows, runs, and secrets |
| The source default branch | Releases and repository settings |
| Submodule pointer commits | Wikis and Git LFS objects |

OpenAgents freezes the accepted branch and tag map before copying data. It
verifies that same ref snapshot before marking the repository ready. A GitHub
commit created after acceptance is not part of the import.

Git LFS pointer files remain in Git history, but OpenAgents does not copy the
referenced LFS objects. Download or migrate those objects separately before
you rely on the imported repository.

## After the import

OpenAgents becomes the source of truth for the new repository. Later GitHub
changes do not flow to OpenAgents, and OpenAgents pushes do not flow back to
GitHub. The repository page labels the result as imported once and records the
source and accepted snapshot.

Clone and work with the destination as a normal OpenAgents repository:

```sh
openagents repo clone OpenAgentsInc/example
cd example
git push
```

## Next steps

- [Clone, push, and pull](git.md)
- [CLI command reference](command-reference.md)
