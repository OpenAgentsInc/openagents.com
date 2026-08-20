# Install the OpenAgents CLI

The npm package is `@openagentsinc/cli`, and it installs the `openagents`
command. The package requires Node.js 24 or later.

The production npm release remains gated. The install command below applies
after the package is published.

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

The CLI prints a verification URL and user code, opens the URL when your
operating system supports it, and waits for approval. Complete the flow with
the GitHub account connected to OpenAgents.

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

Configure only the current Git repository:

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

