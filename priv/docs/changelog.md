# Changelog

## Coder 0.1

Released August 2026.

Coder 0.1 brings interactive coding, model access, tools, delegation, and
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
