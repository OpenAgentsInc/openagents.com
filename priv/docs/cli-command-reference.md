# OpenAgents CLI command reference

The `openagents` command manages authentication and hosted repositories.

```text
openagents <subcommand> [flags]
```

Run `openagents <command> --help` for the reference that matches your installed
version. When you use `npx`, replace the `openagents` prefix with
`npx --yes @openagentsinc/cli@latest`.

## Use global flags

| Flag | Description |
| --- | --- |
| `--profile production\|staging\|local` | Select a named API profile. |
| `--api-url ORIGIN` | Use a custom HTTPS or loopback API origin. |
| `--json` | Write one machine-readable JSON value. |
| `--no-color` | Disable ANSI output. |
| `--help`, `-h` | Show help. |
| `--version`, `-v` | Show the CLI version. |
| `--completions bash\|zsh\|fish\|sh` | Print a shell completion script. |

Place shared flags before the subcommand:

```sh
openagents --profile staging --json repo list
npx --yes @openagentsinc/cli@latest --profile staging --json repo list
```

Setting `NO_COLOR` also disables ANSI output.

## Run authentication commands

| Command | Description |
| --- | --- |
| `openagents auth login` | Start browser-assisted device authorization and store the token. |
| `openagents auth login --headless` | Return an authorization URL, user code, and resume command without waiting. |
| `openagents auth login --resume` | Complete the pending device authorization after approval. |
| `openagents auth login --token-stdin` | Read and store a token from standard input. |
| `openagents auth token-stdin` | Read and store a token from standard input. |
| `openagents auth status` | Show the selected API, account, namespaces, expiry, and helper state. |
| `openagents auth logout` | Remove the stored token for the selected API origin. |
| `openagents auth setup-git --local` | Configure the current Git repository. |
| `openagents auth setup-git --global --yes` | Configure global Git settings with explicit confirmation. |

`auth git-credential` is an internal Git-helper endpoint. Do not invoke it
directly.

Do not run either `auth setup-git` form through `npx`. Install the CLI globally
before you save a persistent helper configuration.

## Create a repository

```text
openagents repo create [flags] <name-or-namespace/name>
```

| Flag | Description |
| --- | --- |
| `--description TEXT` | Set the repository description. |
| `--public` | Create a public repository. |
| `--private` | Create a private repository, which is the default. |
| `--default-branch NAME` | Set the initial default branch. The default is `main`. |
| `--wait-timeout SECONDS` | Wait for provisioning. The default is `300`; `0` does not wait. |
| `--source DIRECTORY` | Attach the new repository to a Git worktree. |
| `--remote NAME` | Set the remote name used with `--source`. The default is `origin`. |

The command creates the server repository before it configures a local remote.
It never pushes automatically.

## Import a repository

```text
openagents repo import [flags] <github-owner/repository>
```

| Flag | Description |
| --- | --- |
| `--name NAME` | Override the destination repository name. |
| `--namespace OWNER` | State the matching eligible GitHub owner. |
| `--public` | Create a public destination. |
| `--private` | Create a private destination, which is the default. |
| `--wait-timeout SECONDS` | Wait for import. The default is `300`; `0` does not wait. |

This command performs one import. It does not start synchronization. A client
timeout does not cancel the accepted server-side import.

## List repositories

```text
openagents repo list [--namespace OWNER] [--limit 1..100] [--after CURSOR]
```

The default limit is `30`. When more results exist, human output prints the
next opaque cursor and JSON output returns it as `next_cursor`.

## View a repository

```text
openagents repo view [OWNER/REPOSITORY]
openagents repo view --repo OWNER/REPOSITORY
```

When you omit the repository, the CLI infers it from an exact OpenAgents
`origin` remote on the selected API origin.

## Clone a repository

```text
openagents repo clone [OWNER/REPOSITORY] [DIRECTORY]
openagents repo clone --repo OWNER/REPOSITORY [DIRECTORY]
```

The CLI retrieves the clone URL from the API and starts standard Git.

## Use JSON in noninteractive processes

With `--json`, stdout contains machine-readable output. Human progress and
errors do not contaminate a successful JSON response. Responses never include
an API token or token digest.

In a noninteractive process, `auth login` returns the authorization URL, user
code, and resume command immediately. Surface the URL and code to the user.
After approval, run `auth login --resume`. Use `--headless` to select the same
behavior in a terminal.

```sh
openagents --json auth login
openagents --json auth login --resume
```

You can also set `OPENAGENTS_TOKEN` to an `oa_pat_` user token or provide an
existing credential-store entry. Repository endpoints do not accept
`OPENAGENTS_AGENT_TOKEN`. Pass every ambiguous value as an argument or flag.
Do not use global Git-helper setup in a noninteractive process. Handle
`SIGINT` and `SIGTERM` as exit code `130`; the CLI cancels in-flight HTTP work
and terminates its child Git process.

## Handle exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success. |
| `1` | Git, output, or unclassified operational failure. |
| `2` | Usage, configuration, or validation error. |
| `3` | Authentication, authorization, or credential-store failure. |
| `4` | Repository or API resource not found. |
| `5` | Conflict, such as an existing repository name. |
| `6` | Network, server, transport, or API-contract failure. |
| `7` | Provisioning or import failure or timeout. |
| `130` | Interrupted by `SIGINT` or `SIGTERM`. |

## Know which commands are unavailable

This release does not provide `repo delete`, `repo mirror`, pull-request,
ruleset, SSH-key, generic API, or self-update commands. Use only commands shown
by the installed version's `--help` output.

## Next steps

- [Install the CLI](/docs/install-cli)
- [Create a repository](/docs/create-repository)
- [Import from GitHub](/docs/import-github)
- [Clone, push, and pull](/docs/clone-push-pull)
