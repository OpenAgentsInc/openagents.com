# Install the OpenAgents CLI

The CLI is a single native binary. On macOS and Linux:

```sh
curl -fsSL https://openagents.com/install.sh | sh
```

On Windows, PowerShell has no `sh`, and its `curl` is not the curl that command
names. Run this instead:

```powershell
irm https://openagents.com/install.ps1 | iex
```

The installer detects your operating system and processor, downloads the
matching build, verifies its SHA-256 checksum, and links three names —
`openagents`, `coder`, and `oa` — into `~/.openagents/bin`. It also adds that
directory to `PATH` in your shell configuration file. Open a new shell, then
confirm the installation:

```sh
openagents --version
```

The three names are one binary. Run it bare and it starts a coder session; give
it a command and it runs that command. So `openagents` and `coder` are two doors
onto the same program, and `oa` is the short one:

```sh
coder                   # start a coder session
openagents repo list    # run a command
oa repo list            # the same command, less typing
```

## Update

```sh
openagents update
```

The command resolves the same channel the installer resolves, compares the
version it names against the running binary, and stops there when they agree.
Otherwise it downloads the new artifact, fetches `SHA256SUMS-<version>` over a
separate request, refuses anything it cannot verify, and replaces the binary in
place. `openagents self-update` is the same command.

Ask what the channel names without installing anything:

```sh
openagents update --check
```

Follow a different channel, or install one exact version:

```sh
openagents update --channel beta
openagents update --version 0.0.2
```

`--force` reinstalls the version already running, which is how you repair a
binary you suspect is damaged.

Running the installer again does the same job and is the right choice when the
binary cannot start at all.

## Install a specific version

Pass a version to the script when a script or qualification run must be
reproducible:

```sh
curl -fsSL https://openagents.com/install.sh | sh -s 0.0.2
```

The version must read as `X.Y.Z` or `X.Y.Z-suffix`. The installer refuses
anything else before it downloads.

## Choose a channel

Without a version, the installer resolves a channel to the version that channel
currently names. `stable` is the default. Set `OPENAGENTS_CHANNEL` to follow a
different one:

```sh
curl -fsSL https://openagents.com/install.sh | OPENAGENTS_CHANNEL=beta sh
```

A channel is a pointer that moves, so the version you get today is not the
version you get next month. Pass an explicit version when you need the answer
to stay the same.

`stable` names the current release and is what you get by default. `beta` does
not resolve at present: a channel that names no version makes the installer say
so and stop rather than guess, so follow `beta` only when a release candidate is
outstanding. Ask a channel what it names without installing anything:

```sh
curl -fsSL https://openagents.com/releases/stable
```

## Choose where the binary lands

The installer links `openagents`, `coder`, and `oa` into `~/.openagents/bin`.
Set `OPENAGENTS_BIN_DIR` to link them somewhere already on your `PATH`:

```sh
curl -fsSL https://openagents.com/install.sh | OPENAGENTS_BIN_DIR="$HOME/.local/bin" sh
```

The downloaded binary itself always lands in `~/.openagents/downloads`.

## Supported platforms

| Platform | Build |
| --- | --- |
| macOS on Apple silicon | `macos-aarch64` |
| macOS on Intel | `macos-x86_64` |
| Linux on x86-64, glibc | `linux-x86_64` |
| Linux on x86-64, musl | `linux-x86_64-musl` |
| Linux on ARM64, glibc | `linux-aarch64` |
| Linux on ARM64, musl | `linux-aarch64-musl` |
| Windows on x86-64 | `windows-x86_64` |

On Apple silicon, a shell running under Rosetta reports an Intel processor. The
installer detects that and installs the native `macos-aarch64` build anyway.

On Linux, the installer picks between the two C library builds by looking for
the glibc dynamic loader for your architecture. A system that has it can run
the dynamically linked build and receives it. A system that does not — Alpine,
a distroless or BusyBox image, NixOS — receives the statically linked musl
build, which depends on no loader at all. Distributions are never named or
guessed at, and the check needs no tools beyond the shell, so it holds on
images that carry neither `ldd` nor a release file.

The script is POSIX shell, so `sh` runs it everywhere, including Alpine and
other minimal images that ship no `bash`. `bash` also runs it on any system that
has one, so either form works.

On Windows, run the installer under Git for Windows or MSYS2 Bash. It installs
`openagents.exe`, `coder.exe`, and `oa.exe` as three copies rather than
symlinks. Under WSL, use the Linux build: WSL is Linux, and `uname -s` reports
it as such.

## What the installer verifies

The installer downloads `SHA256SUMS-<version>` separately from the artifact and
compares the artifact against the entry that names it. It refuses to install
when the sums file is missing, when it names no entry for your platform, when
the checksums disagree, or when neither `shasum` nor `sha256sum` is available.
The bytes are never made executable before the comparison succeeds.

macOS builds are signed with an Apple Developer ID certificate and notarized by
Apple, so Gatekeeper admits them without a right-click override.

The installer has no local fallback. It installs what it downloaded or it fails
and says so.

## Verify a download by hand

Download the artifact and its sums file, then compare them yourself:

```sh
curl -fsSLO https://openagents.com/releases/openagents-0.0.2-macos-aarch64
curl -fsSLO https://openagents.com/releases/SHA256SUMS-0.0.2
shasum -a 256 openagents-0.0.2-macos-aarch64
grep openagents-0.0.2-macos-aarch64 SHA256SUMS-0.0.2
```

The two hexadecimal digests must match exactly. On Linux, use `sha256sum` in
place of `shasum -a 256`.

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

The CLI stores the pending request in a private mode-`0600` local file. It
removes the request after successful authorization or when it detects that the
request expired.

The CLI stores the resulting `oa_pat_` token for the selected API origin:

- On macOS, it uses Keychain through the `security` command.
- On Linux, it uses Secret Service through `secret-tool`.
- On a system without an admitted credential store, it fails closed. Use
  `OPENAGENTS_TOKEN` for the current process instead.

Check the selected account, namespaces, token source, expiry, and Git-helper
state:

```sh
openagents auth status
```

Remove the stored credential for the selected API origin:

```sh
openagents auth logout
```

## Use a token without a browser

Read and store a token from standard input. The CLI never accepts a token as a
command-line argument.

```sh
openagents auth token-stdin
```

`openagents auth login --token-stdin` provides the same behavior.

For an agent or CI process, set the token for the process:

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

Place a shared profile or API flag before the subcommand:

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

Set `OPENAGENTS_CONFIG_PATH` to read another configuration file. The file
accepts `profile` or `api_url` and never stores credentials.

```json
{
  "profile": "local"
}
```

## Configure Git authentication

After you install the CLI, configure only the current Git repository:

```sh
openagents auth setup-git --local
```

Configure every local repository only when you intend to use the same helper
for the selected OpenAgents origin:

```sh
openagents auth setup-git --global --yes
```

The helper is scoped to the selected OpenAgents origin. It refuses unrelated
hosts and never places a token in a Git URL or process argument.

## Next steps

- [Create a repository](/docs/create-repository)
- [Import from GitHub](/docs/import-github)
- [Clone, push, and pull](/docs/clone-push-pull)
- [Call the API with the CLI](/docs/cli-api)
- [CLI command reference](/docs/cli-command-reference)
