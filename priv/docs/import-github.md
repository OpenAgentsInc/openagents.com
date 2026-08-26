# Import a GitHub repository

An import copies one accepted GitHub snapshot into a new OpenAgents
repository. It is a one-time copy, not a mirror. Later changes do not
synchronize in either direction.

## Check the prerequisites

You need:

- An OpenAgents account connected to GitHub.
- A current GitHub connection with the `repo` and `read:org` grants.
- Read access to the source GitHub repository.
- An eligible destination namespace that matches the GitHub source owner.
- An active GitHub organization administrator membership for an organization
  destination.

Reconnect your GitHub account before importing if its current grant lacks the
required permissions.

## Import in the browser

1. Sign in to OpenAgents with GitHub.
2. Open [Repositories](/repositories).
3. Select **Import from GitHub**.
4. Choose a repository from the bounded GitHub repository list.
5. Confirm the matching destination namespace.
6. Keep the source name or enter another destination name.
7. Choose **Private** or **Public**. Private is the default, even when the
   GitHub source is public.
8. Review the Git LFS warning.
9. Select **Import repository**.

The import page shows the accepted snapshot and bounded lifecycle state. It
does not expose raw Git output or a GitHub token.

## Import with an installed CLI

Import a repository into its matching namespace:

```sh
openagents repo import OpenAgentsInc/example
```

By default, the destination keeps the source repository's GitHub visibility. Use
`--public` or `--private` only when you want to override it.

Choose another destination name:

```sh
openagents repo import OpenAgentsInc/example --name example-copy
```

Create a public destination explicitly:

```sh
openagents repo import OpenAgentsInc/example --public
```

State the matching organization explicitly:

```sh
openagents repo import OpenAgentsInc/example --namespace OpenAgentsInc
```

The `--namespace` value must match the GitHub source owner in this release. You
cannot import `SOURCE/repository` directly into an unrelated namespace.

The CLI waits up to 300 seconds by default. It writes state changes, elapsed
time, and a five-second heartbeat to standard error while it waits. Pass
`--wait-timeout 0` to return after the server accepts the durable import.
A client timeout does not cancel the server-side import.

## Pin a version for a qualification run

A release channel is a pointer that moves, so an import you run today and the
same import next month can run under different builds. Install one exact
version when a qualification run has to stay reproducible:

```sh
curl -fsSL https://openagents.com/install.sh | sh -s 0.0.2
openagents --profile staging \
  repo import OWNER/REPOSITORY \
  --private \
  --wait-timeout 300
```

## Import from a headless agent

In a headless process, start the resumable login before the import:

```sh
openagents --json auth login
# The agent shows you the URL and code. After you approve the request:
openagents --json auth login --resume
```

The first command returns immediately, so the agent does not need streaming
shell output. The agent never receives your GitHub credential or the issued
OpenAgents token.

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

## Verify an import

Use a small private repository for an initial environment check. Include a
second branch and an annotated tag so you can verify the accepted ref
snapshot. If the source uses Git LFS, expect OpenAgents to preserve pointer
files without copying LFS objects.

1. Sign in and confirm the selected account:

   ```sh
   openagents auth login
   openagents auth status
   ```

2. Start one private import and wait for its durable result:

   ```sh
   openagents repo import OWNER/REPOSITORY --private --wait-timeout 300
   ```

3. Confirm that the destination is ready, then clone it:

   ```sh
   openagents repo view OWNER/REPOSITORY
   openagents repo clone OWNER/REPOSITORY
   ```

4. Compare the cloned branch and tag tips with the accepted GitHub snapshot.
   Confirm that the clone contains one commit of history per imported tip.
5. Add a later commit on GitHub and confirm that it does not appear in the
   OpenAgents copy.

OpenAgents does not start an import during a deployment. An authenticated user
must start each import explicitly.

## Understand what the import copies

| Copied | Not copied |
| --- | --- |
| Current commit and file tree at every accepted ref, with depth 1 | Full Git history before each accepted tip |
| `refs/heads/*` branches | Pull requests and reviews |
| `refs/tags/*` tags | Actions runs and secrets |
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

## Work after the import

OpenAgents becomes the source of truth for the destination. Clone and work
with it as a normal OpenAgents repository:

```sh
openagents repo clone OpenAgentsInc/example
cd example
openagents auth setup-git --local
git push
```

The repository page records the GitHub source and labels the result as imported
once.

## Next steps

- [Clone, push, and pull](/docs/clone-push-pull)
- [CLI command reference](/docs/cli-command-reference)
