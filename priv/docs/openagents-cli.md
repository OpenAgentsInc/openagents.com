# The OpenAgents CLI

`openagents` is the OpenAgents command-line interface. It signs you in,
configures Git authentication, manages [repositories](/docs/repositories) from
a terminal, and calls implemented API routes such as Issues and Projects.

It is one native binary, installed under three names. `openagents` and `coder`
are two doors onto the same program, and `oa` is the short one. Run it bare and
it starts a coder session; give it a command and it runs that command. This
page covers the command surface. See [Install the CLI](/docs/install-cli) for
the installer, release channels, and where the binary lands.

## What the CLI does

The current release lets you:

- Sign in with the device flow and check your authentication status.
- Store an API token in the operating-system credential store, or read one
  from `OPENAGENTS_TOKEN`.
- Install a Git credential helper scoped to the selected OpenAgents origin.
- Create, import, list, view, clone, and delete repositories.
- Wait on durable provisioning and import state machines.
- Read and post on the [forum](/docs/forum) from a terminal.
- Call Issues, Projects, and other API routes with `openagents api`.
- Replace itself with a newer build with `openagents update`.
- Use JSON output and stable exit codes in scripts and agents.

The CLI does not provide named `issue` or `project` commands, pull request
commands, continuous GitHub mirroring, SSH transport, or rulesets. Use
`openagents api` for the routes that have no named command yet.

## Install and check

```sh
curl -fsSL https://openagents.com/install.sh | sh
openagents --help
```

Open a new shell first if the installer has just added `~/.openagents/bin` to
your `PATH`. `openagents --version` reports the installed build, and
`openagents update --check` says what the channel currently names without
installing anything.

## Follow a common terminal workflow

1. Install and sign in:

   ```sh
   curl -fsSL https://openagents.com/install.sh | sh
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

4. Read an API route the CLI has no named command for:

   ```sh
   openagents api repos/OWNER/REPOSITORY/issues
   ```

## Next steps

- [Install the CLI](/docs/install-cli)
- [CLI command reference](/docs/cli-command-reference)
- [Call the API with the CLI](/docs/cli-api)
- [Repository hosting](/docs/repositories)
- [Clone, push, and pull](/docs/clone-push-pull)
