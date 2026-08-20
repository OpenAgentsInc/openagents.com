# Clone, push, and pull

OpenAgents serves Git smart HTTP at an HTTPS URL returned by the repository API
and web interface. Standard Git performs clone, fetch, push, and pull.

## Clone with the CLI

```sh
openagents repo clone OWNER/REPOSITORY
```

Choose a destination directory:

```sh
openagents repo clone OWNER/REPOSITORY ./local-directory
```

The command uses the server-provided clone URL and invokes Git without putting
the token in the URL or process arguments. For the clone operation, it scopes
the OpenAgents credential helper to the selected API origin.

## Clone with Git

Copy the HTTPS URL from the repository page, then run:

```sh
git clone https://openagents.com/git/OWNER/REPOSITORY.git
```

Public repositories support anonymous clone and fetch. Private repositories
require an authorized credential.

Before you use standard Git with a private repository, configure the helper:

```sh
cd existing-worktree
openagents auth setup-git --local
```

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
and fetch but cannot push. Token authorization is checked again for each Git
request, so revoking or expiring a token takes effect without changing the
remote URL.

## Infer a repository from `origin`

From a worktree whose `origin` is an exact OpenAgents clone URL:

```sh
openagents repo view
```

The CLI accepts only `/git/OWNER/REPOSITORY.git` on the selected API origin. It
does not infer authority from an arbitrary URL that resembles a repository
path. Override inference explicitly when needed:

```sh
openagents repo view --repo OWNER/REPOSITORY
openagents repo clone -R OWNER/REPOSITORY
```

## Authentication safety

The credential helper:

- Returns credentials only for the exact selected OpenAgents origin.
- Rejects username, port, path, or protocol mismatches.
- Reads `OPENAGENTS_TOKEN` or the operating-system credential store.
- Never writes a token into the Git remote URL.
- Never logs complete credential-helper input.

OpenAgents uses HTTPS in this release. SSH remotes and SSH-key management are
not available yet.

## Next steps

- [Install and authenticate the CLI](install.md)
- [CLI command reference](command-reference.md)

