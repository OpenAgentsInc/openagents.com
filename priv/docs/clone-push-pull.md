# Clone, push, and pull

OpenAgents serves Git smart HTTP at the HTTPS clone URL returned by the
repository API and web interface. Standard Git performs clone, fetch, push,
and pull operations.

## Clone with the CLI

```sh
openagents repo clone OWNER/REPOSITORY
```

Choose a destination directory:

```sh
openagents repo clone OWNER/REPOSITORY ./local-directory
```

The command retrieves the server-provided clone URL and invokes Git without
putting the token in the URL or process arguments. It scopes the OpenAgents
credential helper to the selected API origin for that clone process.

## Clone with Git

Copy the HTTPS URL from the repository page, then run:

```sh
git clone https://openagents.com/OWNER/REPOSITORY.git
```

Public repositories support anonymous clone and fetch. Private repositories
require an authorized credential.

Before you use standard Git with a private repository, configure the helper in
the worktree:

```sh
cd existing-worktree
openagents auth setup-git --local
```

The helper configuration refers to the `openagents` executable by path, so
install it where it stays: the installer links it into `~/.openagents/bin` and
puts that directory on your `PATH`.

Use global setup only when you want every local repository to use the helper
for the selected OpenAgents origin:

```sh
openagents auth setup-git --global --yes
```

## Push and pull

After you configure the helper, use standard Git commands:

```sh
git push -u origin main
git fetch origin
git pull --ff-only
```

Repository owners, maintainers, and contributors can push. Viewers can clone
and fetch but cannot push. OpenAgents checks token authorization for each Git
request, so revoking or expiring a token takes effect without changing the
remote URL.

## Infer a repository from origin

From a worktree whose `origin` is an exact OpenAgents clone URL:

```sh
openagents repo view
```

The CLI accepts only `/OWNER/REPOSITORY.git` on the selected API origin. It
does not infer authority from another URL that resembles a repository path.
Override inference explicitly when needed:

```sh
openagents repo view --repo OWNER/REPOSITORY
openagents repo clone -R OWNER/REPOSITORY
```

## Review authentication safety

The credential helper:

- Returns credentials only for the exact selected OpenAgents origin.
- Rejects username, port, path, or protocol mismatches.
- Reads `OPENAGENTS_TOKEN` or the operating-system credential store.
- Never writes a token into the Git remote URL.
- Never logs complete credential-helper input.

OpenAgents uses HTTPS in this release. SSH remotes and SSH-key management are
not available yet.

## Next steps

- [Install the CLI](/docs/install-cli)
- [Create a repository](/docs/create-repository)
- [CLI command reference](/docs/cli-command-reference)
