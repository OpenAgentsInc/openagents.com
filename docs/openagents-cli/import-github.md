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

The CLI waits up to 300 seconds by default. It writes state changes, elapsed
time, and a five-second heartbeat to standard error while it waits. Pass
`--wait-timeout 0` to return after the server accepts the durable import.
A client timeout does not cancel the server-side import.

Run one import without a global installation:

```sh
npx --yes @openagentsinc/cli@latest repo import OWNER/REPOSITORY
```

Pin the package version for a reproducible qualification run:

```sh
npx --yes @openagentsinc/cli@0.1.5 \
  --profile staging \
  repo import OWNER/REPOSITORY \
  --private \
  --wait-timeout 300
```

In a headless agent process, start the resumable login before the import:

```sh
npx --yes @openagentsinc/cli@latest --json auth login
# The agent shows you the URL and code. After you approve the request:
npx --yes @openagentsinc/cli@latest --json auth login --resume
```

The first command returns immediately, so the agent does not need streaming
shell output. Install the CLI globally before you run `auth setup-git`; a saved
Git helper cannot call the temporary executable after `npx` exits.

## Import a large repository

OpenAgents imports every accepted branch and tag at depth 1 by default. This
shallow snapshot preserves each current tip and its files without copying the
source repository's full history. It makes repositories with years of history
available much faster and bounds the first transfer by current content rather
than commit count.

OpenAgents keeps the resulting Git bundle on disk and streams it to and from
the durable forge WAL in 1 MiB chunks. The application does not read the
complete bundle into the BEAM heap. The default server limits allow a bundle
up to 20 GiB and an import to run for up to six hours.

The CLI's `--wait-timeout` controls only how long that client waits. It does
not change or cancel the server import. For a large repository, accept the
operation immediately and check it separately:

```sh
openagents repo import OWNER/REPOSITORY --wait-timeout 0
openagents repo view OWNER/REPOSITORY
```

The repository page reports queued, copying, storing, ready, and failed states.
Server logs record every stage and the bundle byte count. A bundle over the
server limit fails with `import_too_large`; an operation over the server time
limit fails with `import_timeout`.

Large imports still need enough temporary disk for the shallow Git objects and
the bundle. Git LFS objects remain outside the import.

## Verify the first production import

Use a small private GitHub repository for the first production import. Include
a second branch and an annotated tag so you can verify the accepted ref
snapshot. If the repository uses Git LFS, expect OpenAgents to preserve the
pointer files without copying the LFS objects.

1. Install the qualified CLI version:

   ```sh
   npm install --global @openagentsinc/cli@0.1.5
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

5. Compare the cloned branch and tag tips with the accepted GitHub snapshot.
   Confirm that the clone contains one commit of history per imported tip and
   that a later GitHub commit does not appear in the OpenAgents copy.

The release process does not create a production repository automatically.
An authenticated operator starts the first production import explicitly.

## What the import copies

| Copied | Not copied |
| --- | --- |
| Current commit and file tree at every accepted ref, with depth 1 | Full Git history before each accepted tip |
| `refs/heads/*` branches | Pull requests and reviews |
| `refs/tags/*` tags | Actions workflows, runs, and secrets |
| The source default branch | Releases and repository settings |
| Submodule pointer commits | Wikis and Git LFS objects |

OpenAgents freezes the accepted branch and tag map before copying data. It
verifies that same ref snapshot before marking the repository ready. The
destination records those commits as shallow boundaries, so normal cloning and
new commits work without the omitted ancestry. A GitHub commit created after
acceptance is not part of the import.

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
