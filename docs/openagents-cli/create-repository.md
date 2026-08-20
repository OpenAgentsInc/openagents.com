# Create an OpenAgents repository

Create an empty repository from the web interface or with the OpenAgents CLI.
If the code already exists on GitHub, use a [one-time GitHub
import](import-github.md) instead.

## Create a repository in the browser

1. Sign in to OpenAgents with GitHub.
2. Open `/repositories`.
3. Select **New repository**.
4. Choose your GitHub user or an eligible GitHub organization namespace.
5. Enter a name and optional description.
6. Choose **Private** or **Public**. Private is the default.
7. Enter the default branch. The default value is `main`.
8. Select **Create repository**.

The repository can briefly show a provisioning state. Push instructions appear
after durable provisioning finishes.

## Create a repository with the CLI

Create a private repository in your GitHub user namespace:

```sh
openagents repo create my-project
```

Create a public repository in an eligible organization namespace:

```sh
openagents repo create OpenAgentsInc/my-project --public
```

Set a description and default branch:

```sh
openagents repo create my-project \
  --description "Example repository" \
  --default-branch trunk
```

The CLI waits up to 300 seconds for provisioning by default. Pass
`--wait-timeout 0` to return after the server accepts the durable request. The
repository continues provisioning on the server.

## Attach an existing local project

Create the remote repository and attach it to an existing Git worktree:

```sh
openagents repo create my-project --source .
```

The CLI verifies the Git worktree, adds the server-provided clone URL as the
`origin` remote, and prints the next push command. It does not push
automatically.

Choose a different remote name when `origin` already belongs to another host:

```sh
openagents repo create my-project --source . --remote openagents
git push -u openagents HEAD
```

The CLI refuses to overwrite an existing remote that points to a different
URL. If remote attachment fails, the remote repository still exists.

## Push the first commit

For an existing local project:

```sh
openagents auth setup-git --local
git push -u origin HEAD
```

To start from an empty directory:

```sh
git init my-project
cd my-project
git branch -M main
git remote add origin https://openagents.com/git/OWNER/my-project.git
# Add files, then commit them.
openagents auth setup-git --local
git push -u origin main
```

Prefer the clone URL returned by the browser or CLI instead of constructing it
yourself.

## Names and visibility

Repository names are case-insensitive and normalize to lowercase. A name:

- Contains 1 through 64 ASCII characters.
- Starts with a letter or digit.
- Uses letters, digits, hyphens, underscores, and qualifying dots.
- Cannot use a reserved OpenAgents route or Git-internal name.
- Must be unique within the namespace.

A private repository requires an authorized OpenAgents membership. A public
repository permits anonymous Git reads. The creator becomes the repository
owner. OpenAgents does not automatically copy every GitHub organization member
into the repository.

## Organization repositories

OpenAgents uses GitHub to verify organization identity and membership. You need
an active GitHub organization administrator membership to create a repository
in that organization during the first release.

Custom OpenAgents namespaces, repository transfer, rename, archive, and delete
are not available yet.

## Next steps

- [Clone, push, and pull](git.md)
- [Import a GitHub repository](import-github.md)
- [CLI command reference](command-reference.md)

