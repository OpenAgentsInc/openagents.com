# The OpenAgents CLI

`openagents` is the OpenAgents command-line interface, distributed on npm as
`@openagentsinc/cli`. It signs you in, configures Git authentication, manages
[repositories](/docs/repositories) from a terminal, and calls implemented API
routes such as Issues and Projects.

## What the CLI does

The current release lets you:

- Sign in with the device flow and check your authentication status.
- Store an API token in the operating-system credential store, or read one
  from `OPENAGENTS_TOKEN`.
- Install a Git credential helper scoped to the selected OpenAgents origin.
- Create, import, list, view, clone, and delete repositories.
- Wait on durable provisioning and import state machines.
- Call Issues, Projects, and other API routes with `openagents api`.
- Use JSON output and stable exit codes in scripts and agents.

The CLI does not provide named `issue` or `project` commands, pull request
commands, continuous GitHub mirroring, SSH transport, rulesets, or a
self-update command. Use `openagents api` for the routes that have no named
command yet.

## Choose how to run the CLI

Install the CLI globally when you use it regularly or when you want to
configure Git authentication that remains available after the current command:

```sh
npm install --global @openagentsinc/cli
openagents --help
```

Use `npx` for one command without a global installation:

```sh
npx --yes @openagentsinc/cli@latest --help
npx --yes @openagentsinc/cli@latest repo list
```

Do not configure a persistent Git credential helper through `npx`. The helper
configuration refers to the `openagents` executable, but the temporary `npx`
executable disappears when the command ends. Install the CLI globally before
you run `openagents auth setup-git --local` or
`openagents auth setup-git --global --yes`.

See [Install the CLI](/docs/install-cli) for authentication, profiles,
configuration, and the complete `npx` guidance.

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
