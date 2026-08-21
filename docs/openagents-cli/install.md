# Install the OpenAgents CLI

The npm package is `@openagentsinc/cli`, and it installs the `openagents`
command. The package requires Node.js 20 or later.

## Install with npm

```sh
npm install --global @openagentsinc/cli
```

Verify the installed version:

```sh
openagents --version
```

To update after a release, install the latest npm package again:

```sh
npm install --global @openagentsinc/cli@latest
```

The CLI does not include an `openagents update` command.

## Run one command with npx

Use `npx` when you want to run one command without a global installation:

```sh
npx --yes @openagentsinc/cli@latest --version
npx --yes @openagentsinc/cli@latest repo list
```

Pin a version for a reproducible run:

```sh
npx --yes @openagentsinc/cli@0.1.4 --version
```

Place all CLI arguments after the package name:

```sh
npx --yes @openagentsinc/cli@latest --profile staging auth status
npx --yes @openagentsinc/cli@latest repo import OWNER/REPOSITORY
```

Do not run `auth setup-git` through `npx`. The command writes a persistent Git
helper configuration that calls `openagents`, but the temporary executable is
unavailable after `npx` exits. Install the CLI globally before you configure a
local or global Git helper.

## Run the CLI from source

From the root of the `openagents` monorepo:

```sh
pnpm --filter @openagentsinc/cli run build
node packages/openagents-cli/dist/main.js --version
```

## Sign in

Start the browser-assisted device authorization flow:

```sh
openagents auth login
```

In an interactive terminal, the CLI prints a verification URL and user code,
opens the URL when your operating system supports it, and waits for approval.
Complete the flow with the GitHub account connected to OpenAgents. If the
browser does not open, use the printed URL.

In a headless or noninteractive agent process, the command returns immediately
with the complete authorization URL, user code, and resume command. This
behavior works with shell tools that do not stream command output. Have the
agent surface the URL and code to you. After you approve the request in any
browser, have the agent run:

```sh
openagents auth login --resume
```

Use `--headless` to force the resumable flow in an interactive terminal. Use
`openagents --json auth login` and `openagents --json auth login --resume`
when an agent needs structured output. The agent never receives your GitHub
token or the issued OpenAgents token.

The two-step flow also works without a global installation:

```sh
npx --yes @openagentsinc/cli@latest --json auth login
# After approval:
npx --yes @openagentsinc/cli@latest --json auth login --resume
```

The CLI stores the pending request in a private mode-`0600` local file. It
removes the request after successful authorization or when it detects that the
request expired.

The CLI stores the resulting `oa_pat_` token for the selected API origin:

- On macOS, it uses Keychain through the `security` command.
- On Linux, it uses Secret Service through `secret-tool`.
- On an unsupported platform or a host without an admitted credential store,
  it fails closed. Use `OPENAGENTS_TOKEN` without storing the token.

Check the selected account, namespaces, token source, expiry, and Git helper
state:

```sh
openagents auth status
```

Remove the stored credential for the selected API origin:

```sh
openagents auth logout
```

## Use a token without a browser

For an interactive token import, pass the token through standard input. The
CLI never accepts a token as a command-line argument.

```sh
openagents auth token-stdin
```

`openagents auth login --token-stdin` provides the same behavior.

For an agent or CI process, set the token in the environment for the process:

```sh
OPENAGENTS_TOKEN="oa_pat_..." openagents --json repo list
```

`OPENAGENTS_TOKEN` must contain an OpenAgents user token that starts with
`oa_pat_`. `OPENAGENTS_AGENT_TOKEN` is an internal agent-runtime credential.
Repository endpoints do not accept it.

Do not put a token in a Git URL, configuration file, shell history, or process
argument.

## Select an API profile

The CLI uses the production profile by default.

| Profile | API origin |
| --- | --- |
| `production` | `https://openagents.com` |
| `staging` | `https://staging.openagents.com` |
| `local` | `http://localhost:4000` |

Select a named profile or a custom origin before the command:

```sh
openagents --profile staging auth status
openagents --profile local repo list
openagents --api-url https://forge.example.com repo list
```

Custom origins must use HTTPS. The CLI permits HTTP only for loopback hosts.
An API URL must be an origin without a path, query, fragment, username, or
password.

The CLI resolves endpoint settings in this order:

1. `--api-url`
2. `--profile`
3. `OPENAGENTS_API_URL`
4. `OPENAGENTS_PROFILE`
5. `api_url` in `~/.config/openagents/config.json`
6. `profile` in `~/.config/openagents/config.json`
7. The production profile

You can set `OPENAGENTS_CONFIG_PATH` to read a different configuration file.
The file accepts `profile` or `api_url` and never stores credentials.

```json
{
  "profile": "local"
}
```

## Configure Git authentication

After you install the CLI globally, configure only the current Git repository:

```sh
openagents auth setup-git --local
```

Global setup requires an interactive terminal and explicit confirmation:

```sh
openagents auth setup-git --global --yes
```

The helper is scoped to the selected OpenAgents origin. It refuses unrelated
hosts and never places a token in a Git URL or process argument.

## Next steps

- [Create a repository](create-repository.md)
- [Clone, push, and pull](git.md)
- [CLI command reference](command-reference.md)
