# Changelog

## Coder v0.1.1

Released August 28, 2026.

Coder v0.1.1 adds first-class Grok delegation, a swarm inbox between sessions,
timing on every message and tool call, ATIF exports that keep child and swarm
transcripts, and Flash routing that sends simple questions to Gemini 3.7 Flash.

### See the session as it runs

- The idle screen shows a **New in v0.1.1** card under the startup facts. The
  card names improved subagent delegation, streaming thinking, Grok as a
  first-class delegate, timing on each message, ATIF export of subagent
  streams and the swarm inbox, and Flash routing of simple requests to Gemini
  3.7 Flash.
- Each assistant message and each tool call shows how long it ran. In-flight
  tool headers count while the call runs, then settle the duration on the
  right, matching the turn clock. A `delegate` header names the agent, for
  example `delegate: grok`.
- Thinking streams while the model works. The loading row says **working** and
  times the wait.
- Device sign-in URLs stay visible and clickable in the terminal.

### Delegate to more agents

- Delegate to Grok over ACP. Child activity streams into the parent tool box,
  and ATIF export stores the child transcript in `extra.subagent` instead of
  one notice per thought token. A long-running Grok child is no longer killed
  for silence while it is still streaming.
- Delegate to Claude over ACP. Coder Mini is a built-in agent with worktree
  isolation and a model override.
- Built-in delegates pick default models. One `delegate` call can set the
  lane, worktree, and child options.
- Parallel tool calls that share a stream index stay separate. Coder no longer
  concatenates their names or ids.

### Message other sessions

- Sessions on the same machine can list each other, send messages, and drain a
  swarm inbox at turn boundaries. ATIF export keeps that inbox in
  `extra.swarm`.
- Delegate children register in the swarm and report messages back to the
  parent.

### Route Flash work

- On the default Flash grant, short capability questions such as "what tools
  do you have" route to Gemini 3.7 Flash. Coding work stays on GLM 5.3 Flash.

### Measure, recall, and sign in

- `openagents gym` prints suite, run, results, env, corpus, and dataset views
  from frozen v1 documents. The `/gym` pane draws the same `results_trend` and
  `run_status` documents. Missing costs stay `unknown`.
- `history_recall` reads the session's own record. Checkpoints and budget
  facts land in the export and summary.
- Credentials live in `~/.openagents/credentials.json` on every platform
  instead of the operating-system credential store. Headless
  `openagents auth login` prints the approval URL and user code so you can
  finish the device flow with `openagents auth login --resume`.

The installer and `openagents update` resolve this version on the `stable`
channel for macOS, Linux (glibc and musl), and Windows.

Read the closed work for [swarm messaging](https://openagents.com/OpenAgentsInc/openagents/issues/182),
[Grok ACP](https://openagents.com/OpenAgentsInc/openagents/issues/251),
[ATIF child streams](https://openagents.com/OpenAgentsInc/openagents/issues/276),
[Flash routing](https://openagents.com/OpenAgentsInc/openagents/issues/278),
[tool timing](https://openagents.com/OpenAgentsInc/openagents/issues/277),
[gym views](https://openagents.com/OpenAgentsInc/openagents/issues/165),
[Coder Mini](https://openagents.com/OpenAgentsInc/openagents/issues/246),
[history recall](https://openagents.com/OpenAgentsInc/openagents/issues/159), and
[credential files](https://openagents.com/OpenAgentsInc/openagents/issues/261).

## Coder v0.1.0

Released August 26, 2026.

Coder v0.1.0 brings interactive coding, model access, tools, delegation, and
durable session history into the OpenAgents CLI.

### Work in your terminal

- Stream Markdown responses, reasoning, tool status, and diffs in an interactive
  terminal interface. The interface includes scrollback, prompt history,
  multiline paste, and dropped image references.
- Read, write, edit, and search files. Run shell commands with bounded tool
  output.
- Resume prior threads from their server-side transcripts.

### Choose how inference runs

- Switch between Coder Flash and Coder Free with `Shift+Tab`. Coder displays the
  active lane below the composer.
- Use local Ollama models or a development server lane when you want inference
  to run outside the hosted lanes.
- Inspect the effective model and account balance, and retry transient provider
  failures without losing the turn.

### Delegate work

- Delegate to installed ACP-compatible coding agents, including Claude Code,
  Codex, and Devin.
- Run child tasks in parallel and keep their transcripts with the parent task.
- Discover installed skills and capabilities, and run delegated tools behind
  the shell safety gate.

### Control long-running work

- Use `/goal` to set an objective, inspect its status and budget, pause or resume
  it, and clear it when the work is complete.
- Cancel the current turn without clearing queued work or exiting Coder. Coder
  also cleans up active tools and child processes and settles canceled turns
  once.
- Sign in and out from the terminal while storing credentials in your operating
  system's credential store.

The release is covered by an interactive PTY test harness and a Cargo workspace
completion gate. Installed binaries report their published release version.

Read the closed work for the [native terminal interface](https://openagents.com/OpenAgentsInc/openagents/issues/117),
[first-class tools](https://openagents.com/OpenAgentsInc/openagents/issues/127),
[model lanes](https://openagents.com/OpenAgentsInc/openagents/issues/131),
[CLI consolidation](https://openagents.com/OpenAgentsInc/openagents/issues/137),
[ACP delegation](https://openagents.com/OpenAgentsInc/openagents/issues/72), and
[turn cancellation](https://openagents.com/OpenAgentsInc/openagents/issues/142).
