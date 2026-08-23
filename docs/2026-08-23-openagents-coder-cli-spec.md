# The `openagents coder` terminal coding agent

**Date:** 2026-08-23
**Status:** Specification. None of it is implemented.
**Commits measured:** `d035a1186ee0` on `openagents/main` for this repository; `df62c1fe353d` in the `openagents` monorepo for `packages/openagents-cli` (version `0.2.1` in that tree, `0.3.0` on npm — see section 11); the `probe` repository at `192a5e4` for the current Rust tree, at `e0c78a7` for the archived OpenTUI work, and at `origin/codex/issue-142-coder-compat` for the ratatui lineage.
**Question:** What has to be true for `npm i -g @openagentsinc/cli` followed by `openagents coder` to give you a terminal coding agent that uses the account you already signed in with, calls the APIs `openagents.com` already serves, and creates no second backend?
**Method:** direct reading of `lib/openagents_web/router.ex` and every pipeline it declares, the chat, delegation, computer, Box, and inference controllers and their contexts, `INVARIANTS.md`, and `docs/taxonomy.md`; direct reading of all 22 source files in `packages/openagents-cli/src/` in the `openagents` monorepo; and direct reading of the `probe` repository's five crates, two published packages, zerobase specification, rendering-gap audit, archived OpenTUI commits, and the ratatui work preserved on its `codex/*` branches. Claims this repository cannot settle are in section 11 with the command or file that settles them.

---

## 0. Summary

`openagents coder` is one more subcommand in the CLI you already install. It
mints a budgeted inference grant with the token `openagents auth login` stored,
launches the OpenAgents coding-agent runtime as a child process, speaks Agent
Client Protocol v1 to it over standard input and output, and renders the
session in a full-screen OpenTUI interface where you approve what it does.

The central decision is that **the CLI is an ACP client, not a second coding
agent.** Five findings support it.

1. **The agent already exists and is almost complete.** The `probe` repository
   at `192a5e4` ships a sans-I/O Rust core with a turn state machine
   (`crates/probe-core/src/turn.rs`), permission as data
   (`crates/probe-core/src/permission.rs`), six real tools with path
   confinement and output caps (`crates/probe-bin/src/tools.rs`), an ACP v1
   server (`crates/probe-acp/src/server.rs`), OpenAI-compatible and Gemini wire
   lowerings, and a WebAssembly build whose 452 KB artifact is checked in and
   whose ABI is deliberately synchronous — lines and events in, a JSON command
   array out — so the JavaScript host owns every asynchronous concern. Its
   native host reads `PROBE_INFERENCE_GRANT` and `PROBE_INFERENCE_URL` from the
   environment. It is already pointed at this server.
2. **The authority path exists and is one route short.** `POST
   /api/inference/proxy` (`lib/openagents_web/router.ex:342`) is an
   OpenAI-compatible chat-completions surface a delegated coding agent calls
   with an `OpenAgents.Inference.Grant` as its bearer; the provider credential
   never leaves the server. Three call sites mint grants
   (`lib/openagents/work/scv.ex:133`, `lib/openagents/work/coding.ex:64`,
   `lib/openagents/work/delegation_server.ex:168`) and every one is
   server-initiated. **No route mints a grant for a client holding a user
   token.** That single missing route is the whole server-side gap, and
   `lib/openagents/work/coding.ex:64` already proves the schema accepts
   `machine_id: nil`.
3. **probe wrote down the channel it lacked, and the CLI is that channel.**
   probe's zerobase specification says in its A4 appendix that the paired
   computer controller has "no channel by which a per-delegation inference
   grant can reach probe," and calls the amendment that would create one the
   single thing the free-agent loop requires. A CLI holding the user's own
   token needs no amendment. `openagents coder` is that observation turned into
   a command.
4. **Being the client is what makes approvals work.** probe's TypeScript era
   spent three commits failing to prompt for permission from inside a tool
   handler, because the chat loop owned standard input while tools ran in a
   forked fiber (`efcb799`, `29459f1`, `cfdd422`); it ended with a handler that
   always allowed. The fix it drew is that permission is a protocol, not a
   prompt. A terminal that is a separate process from the agent gets that for
   free: `session/request_permission` arrives as a JSON-RPC request and your
   keystroke is the response.
5. **The CLI has no streaming and no interactive code at all.**
   `ApiTransport` reads the whole response body as text and parses it
   (`packages/openagents-cli/src/api-transport.ts:103`), there is no
   `EventSource`, no readline, no raw mode, and no ANSI anywhere in the
   package. `terminal-session.ts` is 17 lines that report whether standard
   input and output are TTYs. The interface is genuinely new capability and
   must degrade when it cannot run.

The recommendation is to ship the smallest honest slice first: one server route
that mints a session-scoped grant, one CLI subcommand that spawns the runtime
and drives ACP in line-oriented mode, and only then the OpenTUI interface,
writes, and delegation.

---

## 1. What `openagents coder` is

### 1.1 Install to first turn

```sh
npm install --global @openagentsinc/cli
openagents auth login
cd your-repository
openagents coder
```

Three commands, one of which you already ran. `auth login` stores a token in
the operating-system credential store keyed by API origin
(`packages/openagents-cli/src/credential-store.ts:60`); `coder` reads that same
token through the same `resolveApiSession` every other command calls
(`packages/openagents-cli/src/session.ts:47`). There is no second sign-in, no
provider key, and no configuration file to write.

`openagents coder "fix the failing milestone test"` runs one turn
non-interactively and exits, so the command works from a script and from
another agent.

### 1.2 How the pieces fit

```text
  your terminal                          openagents.com
  ┌────────────────────────────┐         ┌───────────────────────────┐
  │ openagents coder           │         │                           │
  │                            │  token  │ POST /api/v3/coder/       │
  │  CoderSession ─────────────┼────────►│      sessions             │
  │   mints, revokes           │◄────────┤   → sig_… grant           │
  │                            │  grant  │                           │
  │  AcpClient                 │         │                           │
  │   session/new              │         │                           │
  │   session/prompt           │         │                           │
  │   session/update      ▲    │         │                           │
  │   request_permission  │    │         │                           │
  │  OpenTUI renderer     │    │         │                           │
  └───────────────────────┼────┘         │                           │
                stdio     │              │                           │
  ┌───────────────────────▼────┐  grant  │ POST /api/inference/proxy │
  │ the coding runtime         ├────────►│   meters, fans to the     │
  │  turn loop, tools, scrub   │◄────────┤   provider, returns SSE   │
  └────────────────────────────┘   SSE   └───────────────────────────┘
         │
         ▼ reads, edits, shell, git — in your working directory
```

Three processes, one token, one grant. The CLI never sees a provider
credential; the runtime never sees your account token; the server never
executes anything on your disk.

### 1.3 Why it belongs in the CLI

A separate binary would have to re-solve four problems the CLI has solved, and
would then hold them at a different version than the CLI does.

- **Identity.** The device-authorization flow, the credential store, the
  `OPENAGENTS_TOKEN` escape hatch, and the "no supported credential adapter on
  this platform" refusal took a device flow, a macOS keychain adapter, a
  `secret-tool` adapter, and read-back verification to get right
  (`packages/openagents-cli/src/credential-store.ts`, `device-client.ts`).
- **API origin.** Profiles are named origins with a seven-step resolution order
  and an origin normalizer that refuses non-loopback HTTP
  (`packages/openagents-cli/src/endpoint.ts:82`, `:41`). A second binary that
  guessed the origin would send a staging token to production the first time
  someone set one environment variable and not the other.
- **Git push authority.** `openagents auth setup-git` installs the same binary
  as a Git credential helper, which is how an ordinary `git push` authenticates
  against the smart HTTP transport at `lib/openagents_web/router.ex:318`. An
  agent that cannot push is a code reader. Reusing the CLI means the agent
  inherits push authority from a command you already ran.
- **Error and exit-code discipline.** Fifteen tagged errors map to eight exit
  codes through an exhaustive switch
  (`packages/openagents-cli/src/errors.ts:141`). An agent invoked from CI needs
  those codes to mean what they mean for `openagents repo create`.

The counter-argument is real: a coding agent is a larger program than a
repository client, and folding it in makes `@openagentsinc/cli` a bigger
install for everyone who wants `openagents api`. The ACP-client decision is
what answers it. The CLI gains a session service, a JSON-RPC client, and a
renderer; the loop, the tools, and the transports stay in the runtime package
where they already are.

---

## 2. What it takes from probe, and what it leaves

### 2.1 What it consumes rather than reimplements

Everything below is built and tested in the `probe` repository at `192a5e4`.
`openagents coder` calls it and adds none of it.

| Concern | Where it lives | What it already guarantees |
| --- | --- | --- |
| Turn loop | `crates/probe-core/src/turn.rs` | Tools execute strictly one at a time; a bounded sixteen tool rounds; cancellation is an ordinary transition from any state that keeps partial text |
| Permission | `crates/probe-core/src/permission.rs` | A typed request carrying tool, ACP kind, title, command string, and a content-free FNV-1a input digest; a denial still reaches the model as a tool result |
| Tools | `crates/probe-bin/src/tools.rs` | Six tools; paths refused on `..`, absolute form, and `.git`; 48 KiB output cap; `/bin/sh -c` with no standard input and a 240-second ceiling; grant variables removed from every child environment |
| Edit safety | `crates/probe-core/src/editing.rs` | Byte-order-mark and line-ending preservation, exact-match planning, and a stale-content guard whose failure is typed rather than swallowed |
| Redaction | `crates/probe-core/src/redact.rs` | A `SecretSet` of values, a `RedactedText` with no constructor that skips it, and a receipt type that is content-free by construction |
| ACP surface | `crates/probe-acp/` | Protocol version 1, one active prompt per session, an event-to-`session/update` mapping that chunks text under a 32 KiB budget, and a 2 MiB line cap set at half the controller's silent-drop threshold |
| Wire | `crates/probe-wire/` | OpenAI-compatible and Gemini lowerings with incremental SSE parse state and endpoint provenance |

Two details make it consumable from Node without a native toolchain. The
WebAssembly ABI is synchronous by design — `handleLine`, `onProviderEvent`,
`onProviderFailure`, and `onToolOutcome` each return a JSON command array — so
the JavaScript host owns every asynchronous concern and no JavaScript Promise
Integration is required. And the built artifact is checked in at
`packages/probe/wasm/probe_wasm_bg.wasm`, so consuming it is an `npm install`
rather than a Rust build.

### 2.2 The four lessons that shape the client

**Permission is a protocol, not a prompt.** The failure was specific and worth
naming, because a full-screen renderer would reproduce it exactly. probe's
`permission.ts` created a second readline interface on standard input while the
chat loop already owned one; the escape-interrupt handler in raw mode consumed
the answer (`29459f1`). The replacement read raw bytes with the prompt on
standard error, and still could not work, because the tool ran in a forked
fiber that could not block on the loop's stream (`cfdd422`). The module's final
comment states the rule: any interactive permission experience must be plumbed
through the main loop by a side channel. Being a separate process is the
strongest possible form of that side channel.

The runtime offers exactly two options — `allow_once` and `reject_once` — and
never an "always" (`crates/probe-acp/src/server.rs`). It fails closed: a
cancelled response, an error response, and an unreadable body all decode as
denied. The client must not weaken either property. Section 7.3 explains how a
session-scoped approval lives in the client's policy without adding a third
option to the wire.

**Redaction belongs in the type.** The grant is the secret that matters, and it
is scrubbed on two walls: the runtime registers it in its `SecretSet` and
scrubs every outgoing line and every tool result, and the client scrubs
everything it renders and writes. The grant value never reaches the transcript
file, a log line, or a tool's environment.

**Untested code is where every defect was.** probe's archived edit module
advertised a stale-content guard that a blanket catch swallowed, so a detected
concurrent modification reported success — and so did a genuine `EACCES`. Its
OpenTUI renderer had zero test coverage. The renderer here is a pure function
from a session-state snapshot to a renderable tree, fixture-tested, with the
ACP client unaware that it exists.

**The conformance contract is already written.** probe's A2 appendix
enumerates what an ACP client must supply and what the agent must satisfy:
protocol version 1 on initialize, `loadSession: true` advertised before resume
is attempted, client capabilities `fs: false` and `terminal: false` with only
`session/request_permission` and `session/update` registered, oversize
JSON-RPC lines dropped whole rather than erroring, `tool_call` frames carrying
`toolCallId`, `kind`, `title`, and `rawInput.command`, `agent_thought_chunk`
droppable so nothing user-relevant may live only there, and any option whose
id, name, or kind matches `/bypass/i` refused. That is the client's test-fixture
list, not a design exercise.

### 2.3 The OpenTUI era, measured honestly

probe integrated `@opentui/core` at version `0.3.4` in three commits over ten
minutes on 2026-06-08: `f046a51` ("Phase 0: Integrate @opentui/core"),
`593d425` ("Phase 1: Rich tool output via CodeRenderable +
LineNumberRenderable"), and `e0c78a7`. Exactly one source file existed,
`packages/runtime/src/opentui-renderer.ts`, and it was deleted with the rest of
the TypeScript tree in `f24253f`. What it actually contained:

- `createCliRenderer({ exitOnCtrlC: true, targetFps: 30, screenMode: "main-screen" })`,
  inline rather than full-screen, activated only behind `--tui` and only when
  standard output was a TTY.
- One `ScrollBoxRenderable` added to `renderer.root`. **No panes, no footer, no
  composer, no header, no split.**
- One `MarkdownRenderable` per turn with `streaming: true`, `conceal: true`,
  and `internalBlockMode: "top-level"`; each text delta appended to `.content`
  and OpenTUI reconciled blocks incrementally.
- Tool calls rendered as one flat `TextRenderable` line. Tool results routed
  through four typed branches — error, file read, directory listing, code
  search — each a dim header plus a `LineNumberRenderable` wrapping a
  `CodeRenderable` with the filetype inferred from the path.
- Tool errors in the one `BoxRenderable` in the file, bordered red.
- `DiffRenderable` was imported and re-exported and **never instantiated.**
  There is no recoverable diff-rendering code from that era.
- Escape-to-interrupt (`86bf9cd`) worked only in the plain ANSI path. The TUI
  path forked the same fiber and handled the interrupted case but installed no
  keypress listener, so under `--tui` there was no way to trigger it.

The zerobase specification's own verdict is that the file was "90% a color
table," and that is fair: a 24-entry GitHub-dark `SyntaxStyle` and a 45-entry
extension map.

What survives is the reasoning, recorded in that repository's
`docs/probe-rendering-gap-audit.md`, which measured what hand-rolled ANSI cost:
code blocks rendered plain gray because the language argument was ignored; the
diff you approved compared lines positionally, truncated to ten a side, and
filtered to only `+` and `-` lines; tool results were one-line summaries, so
what the agent read went to the model and not to you; and streaming Markdown
used regular-expression replacement, so a fenced block spanning two chunks
rendered as raw backticks. `@opentui/core` answers each with a composable
renderable over a Yoga flexbox layout, and its imperative API needs no JSX,
which suits a package built by plain `tsc` with no bundler.

`openagents coder` builds the interface probe's audit planned and never
reached: its P2 row, a scrollable transcript, and its P3 row, a
`TextareaRenderable` composer in split-footer mode.

### 2.4 The ratatui lineage, and why it is not the model

probe's `codex/*` branches carry a far richer terminal interface than the
OpenTUI era ever had: a `probe-tui` crate on ratatui, crossterm, and syntect
with a typed overlay stack (`ScreenId::{Chat, Help, SetupOverlay,
ApprovalOverlay}`), a thirty-variant `UiEvent` enum, a real composer with
grapheme-aware cursor movement, a twenty-four-entry history, slash commands and
mentions, a retained transcript model, `insta` snapshot tests pinning every
screen including the approval overlay, and — most relevant — a **resumable
approval broker** that persists pending tool approvals per session and resolves
them on a worker thread, which is the shape the OpenTUI era failed to reach.
That branch also carries `docs/101-openagents-coder-runtime-adapter.md`, which
is prior art for this document and should be read before Stage 1.

It is not the model here for one reason: it is Rust in the agent process, and
the whole argument of section 0 is that the interface belongs in the client, in
the language the CLI is already written in. The ideas port; the crate does not.
Recover the design documents with `git show
origin/codex/issue-142-coder-compat:docs/45-...-resumable-approval-broker.md`
and its siblings.

### 2.5 What it deliberately does not take

- **A second model transport family.** probe supports OpenAI-compatible,
  Gemini, and stub transports. The coder configures exactly one: the OpenAgents
  inference proxy under a grant. A user who wants their own key is describing a
  different product.
- **In-process permission prompting, in any form.** See section 2.2.
- **The archived CLI monolith.** probe's `cli.ts` reached 1,974 lines holding
  argument parsing, an ANSI Markdown renderer, tool implementations, per-backend
  formatters, and two chat loops. The layering in section 3 exists to keep that
  from recurring.
- **A `--tui` opt-in flag.** The interface is the default when the terminal
  supports it, and `--plain` opts out. An interface nobody turns on gets no
  test coverage, which is exactly what happened.

---

## 3. The OpenTUI interface

The interface is one screen. There is no conversation list, no workspace
chrome, and no settings pane, which matches how the web surface is governed
(UI-001) and matches what a terminal is good at.

### 3.1 Layout

`createCliRenderer({ screenMode: "split-footer" })` gives a scrollback region
and a fixed footer, which is the shape the interaction needs: the transcript
grows upward and the composer stays put. probe's era used `"main-screen"`
because it was preserving inline output; there is nothing to preserve here.

```text
┌──────────────────────────────────────────────────────────┐
│ transcript          ScrollBoxRenderable, viewport-culled │
│                                                          │
│   you        plain text, dim rule above                  │
│   assistant  MarkdownRenderable, streaming: true         │
│   tool call  header line, expandable body                │
│   diff       DiffRenderable, unified                     │
│                                                          │
├──────────────────────────────────────────────────────────┤
│ status   repository · branch · model · calls · tokens    │
├──────────────────────────────────────────────────────────┤
│ composer TextareaRenderable, multi-line                  │
└──────────────────────────────────────────────────────────┘
```

The status line is the one piece of chrome that earns its row. An agent
spending a metered grant must show what it has spent: `call_count` against
`max_calls`, and token usage against `max_total_tokens`, both of which the
grant already tracks and the proxy already meters
(`lib/openagents/inference.ex`). An agent that exhausts its budget mid-edit
without ever having shown the budget is an agent that lost your work.

An approval request replaces the composer with a decision pane rather than
opening a modal over the transcript, so the diff under discussion stays
visible.

### 3.2 Keybindings

| Key | Action |
| --- | --- |
| `Enter` | Submit the composer |
| `Shift+Enter` | Newline in the composer |
| `Esc` `Esc` | Interrupt the running turn, within a five-second window |
| `Ctrl+C` | Interrupt if a turn is running, otherwise exit |
| `Ctrl+D` | Exit on an empty composer |
| `PageUp` / `PageDown` | Scroll the transcript |
| `Ctrl+O` | Expand or collapse the focused tool call |
| `y` / `n` / `a` | Approve once, refuse, or approve this class for the session, in the decision pane only |
| `Ctrl+R` | Toggle the diff between unified and split |

Interruption is double-escape inside a five-second window, which is probe's
design (`86bf9cd`) and is not a stylistic choice: in raw mode an arrow key
arrives as `0x1b` followed by more bytes, so a single escape cannot be
distinguished from the start of a sequence without a timeout that makes every
arrow key feel slow. The first escape prints a muted "again to interrupt", any
other byte cancels the armed state, and the second escape sends
`session/cancel`. The zerobase specification kept this pattern explicitly and
the current tree has no host CLI to put it in; this is that host.

Interruption is a protocol message, not a signal. The runtime treats
cancellation as an ordinary state transition, keeps the partial assistant text,
and lets an already-running tool finish and record its outcome. `Ctrl+C` at the
process level must still exit 130, which the package already asserts against a
live process (`packages/openagents-cli/test/signals.test.ts:70`).

### 3.3 Streaming assistant output

The client receives `session/update` notifications and renders them; it does
not parse provider events, because the runtime already lowered them into a
neutral union and mapped that union to ACP. `agent_message_chunk` appends to an
accumulator assigned to `MarkdownRenderable.content` with `streaming: true`, so
per-block reconciliation leaves settled paragraphs alone while a code fence
three blocks down is still arriving. That is what makes an incomplete fence
render as code rather than as backticks.

`agent_thought_chunk` renders dim and collapsed by default. The runtime already
assumes a client may drop it entirely, so nothing user-relevant may live only
there.

One honest caveat about how far "streaming" reaches today. The inference proxy
builds the complete chat-completions SSE body and sends it once
(`lib/openagents_web/controllers/inference_proxy_controller.ex:155`–`:170`)
because its current consumer reads the whole body before parsing; the runtime's
own JavaScript transport does the same. Until both change, a response arrives
in one piece and the interface must not fake a progressive cursor — the status
line shows `waiting`. Chunking the proxy is a small, separable, additive server
change and is listed in section 6.2.

### 3.4 Tool-call rendering

A tool call renders as a collapsed one-line header that expands in place:

```text
▸ read_file   lib/openagents/inference.ex               142 lines
▸ grep_files  "mint("                                    3 matches
▾ shell       mix test test/openagents/inference_test.exs  exit 1
    …output rendered in a CodeRenderable, capped…
```

The header is built from the ACP frame the runtime already populates:
`toolCallId` for correlation, `kind` for the glyph, `title` — which the runtime
sets to `rawInput.command` when present and to the tool name otherwise — and
`status` for the terminal marker. This is a header line composed by the client,
not the carriage-return rewrite probe used in its plain ANSI path (`c51637c`);
that technique cannot survive a renderer that owns the screen.

Rules that follow from probe's measurements:

- **File reads render through `CodeRenderable` wrapped in
  `LineNumberRenderable`**, with the filetype inferred from the extension and
  plain text as the fallback, which is exactly what `593d425` built.
- **Edits render through `DiffRenderable`** against a real unified patch. probe
  generated one with `createTwoFilesPatch` at three lines of context and never
  wired it to a renderable; this is the wiring.
- **Shell output is captured with ANSI stripped** and rendered in a bounded
  scroll region. A terminal emulator inside a renderable is a separate project.
- **Every rendered body is capped and says so when it truncates.** The display
  cap is not the model's cap: the runtime already bounds tool output at 48 KiB
  and chunks ACP content under a 32 KiB text budget. Where the two differ, show
  both. A summary that hides the difference is how "the agent said it read the
  file" becomes unfalsifiable.

### 3.5 Approval prompts

An approval is a `session/request_permission` request. The decision pane shows
the tool, the ACP kind, the exact command string or the exact patch, the path
relative to the working directory, and the decisions. It shows no free-form
model-authored justification above the fold, because the argument for an action
is the action.

```text
  ┌ approve edit ────────────────────────────────────────┐
  │ lib/openagents/inference.ex                          │
  │                                                      │
  │  @@ -41,7 +41,7 @@                                   │
  │ -      max_calls: max_calls(),                       │
  │ +      max_calls: max_calls(kind),                   │
  │                                                      │
  │ [y] approve once   [a] approve edits this session    │
  │ [n] refuse and tell the agent why                    │
  └──────────────────────────────────────────────────────┘
```

Refusal is a typed outcome the agent must handle, not an error that fails the
turn: the runtime turns a denial into a tool result the model reads, so the
next round knows it was refused and why. That mirrors TOOL-002 on the server,
where a refused tool produces a bounded typed result rather than a silent
substitution.

### 3.6 What happens without a real terminal

`terminal-session.ts` already reports whether both standard input and output
are TTYs (`packages/openagents-cli/src/terminal-session.ts:8`), and `auth
login` already branches on it. `coder` branches the same way.

| Condition | Mode |
| --- | --- |
| TTY, renderer available, no `--json` | Full OpenTUI interface |
| Not a TTY, or `--json`, or `--plain` | Line-oriented stream to standard output, no cursor control; approvals refused unless `--approve` names an effect class |
| Renderer's artifact unavailable | Line-oriented mode with one notice on standard error, exit code unchanged |

The interface is optional. The agent is not.

---

## 4. Sessions, turns, and receipts

### 4.1 Say which record you mean

Four durable families are in scope and only one of them is the coder's.

- **Turns** (`turns`, `account_chat_runs`, `account_chat_events`) are Sarah's
  conversation. TURN-001 permits one active turn per conversation, enforced by
  a partial unique index. DATA-002 permits one conversation per authenticated
  user, enforced by a unique index. `AccountTurns.submit/3` calls
  `Conversations.ensure_conversation(user)`, so every caller of `POST
  /api/v3/chat/turns` lands in that one conversation.
- **Work jobs** (`work_jobs`) are delegation, not execution. A `deep_work.v1`
  call starts one; a Computer delegation starts one of kind `delegation`; a
  self-edit starts one of kind `coding` (WORK-001,
  `lib/openagents/work/coding.ex`).
- **Inference grants** (`inference_grants`) are model authority: budgeted in
  tokens, calls, and estimated cost, time-bounded, revocable, and
  generation-fenced by conversation.
- **Push receipts** are the forge's durable record of every accepted push, and
  they are what makes a commit explicable after the session ends.

### 4.2 What a coder session is

A coder session is a **coding-agent session** in the sense `docs/taxonomy.md`
already defines: a complete interaction with a coding agent from start to
finish, spanning one or more turns, whose durable pieces today are turns, work
jobs, and SCV runs. The taxonomy is explicit that the named product unit is
proposed and not built. This document does not build it either, and that is the
point.

Concretely, for the first slice:

- **One session mints one inference grant.** The grant is the durable
  server-side anchor. It already carries the owner, the conversation, the
  model, the budget, the call count, the usage map, and a terminal status. "How
  much did this session spend" is a query against a table that exists.
- **One coder turn is one `session/prompt` and its bounded tool loop.** It is
  not a row in `turns` and not a row in `account_chat_runs`. Writing it there
  would put a second author into the account's single conversation and would
  collide with TURN-001 the first time you ran `openagents coder` in two
  checkouts at once. The runtime's own sixteen-round tool bound happens to
  match TURN-005's sixteen; that is a coincidence worth keeping rather than a
  shared implementation.
- **The local transcript is local.** The client writes append-only JSON Lines
  under the CLI's configuration root, mode `0600`, one file per session, so
  `openagents coder --resume` and `openagents coder --show <id>` work offline.
  It is a convenience, never authority, and it holds no grant value. The
  runtime cannot supply this: its sessions are an in-memory map, and although
  it advertises `loadSession: true`, nothing restores a transcript across
  processes. Section 10 keeps that gap in the client, where it is cheap.
- **What lands on the server is the evidence the server already collects:**
  metered grant usage per call, the push receipt for whatever the session
  committed, and — when the session delegates — the Box run or work job the
  delegation created.

The honest gap this leaves is that a commit produced by `openagents coder`
carries no durable explanation of why. Closing it is the checkpoint receipt
family and the commit trailer that `docs/taxonomy.md` already names as
proposed. The coder should be the first producer of those receipts and should
not invent a private table in the meantime. That is Stage 4.

### 4.3 The rule this section exists to state

**Do not create a second work record.** If the session runs locally, the grant
ledger and the forge receipt are the record. If the session delegates, the
delegation's own substrate record — a Box run or a `work_jobs` row — is the
record, reached through `OpenAgents.Delegations`, which stores no state of its
own and derives every projection from those substrates (IDENTITY-009). There is
no third ledger.

---

## 5. Authentication

`openagents coder` adds no authentication. It calls
`resolveApiSession(endpointOverrides(flags))`
(`packages/openagents-cli/src/session.ts:47`), the same function every other
command calls, and gets back `{endpoint, token}` or a typed
`AuthenticationRequired` that exits 3.

What that inherits, exactly:

- **Token lookup order.** `OPENAGENTS_TOKEN` in the environment wins with
  `source: "environment"`; otherwise the operating-system credential store,
  keyed by resolved origin, service `openagents-cli`
  (`packages/openagents-cli/src/credential-store.ts:46`,
  `packages/openagents-cli/src/session.ts:30`). macOS uses `security`, Linux
  uses `secret-tool`, and every other platform refuses with
  `CredentialPersistenceUnavailable` and tells you to set `OPENAGENTS_TOKEN`
  for the invocation.
- **Profiles.** A profile is a named API origin, not an account: `production`
  is `https://openagents.com`, `staging` is `https://staging.openagents.com`,
  `local` is `http://localhost:4000`
  (`packages/openagents-cli/src/endpoint.ts:5`). Resolution runs `--api-url`,
  `--profile`, `OPENAGENTS_API_URL`, `OPENAGENTS_PROFILE`, the config file's
  `api_url`, the config file's `profile`, then production
  (`packages/openagents-cli/src/endpoint.ts:82`). Because credentials are keyed
  by resolved origin, `openagents --profile staging coder` uses the staging
  token against the staging origin with no further ceremony.
- **Scopes.** The token needs `chat:account` for the grant-mint route in
  section 6.2, and `forge:write` for issue and pull-request tools. Those are
  separate scopes on separate pipelines (`lib/openagents_web/router.ex:57`,
  `:39`). The coder asks for the narrow scope each tool needs rather than
  requiring a token that can do everything, and a tool whose scope the token
  lacks is a typed refusal naming the missing scope, not a `403` traceback.
- **Git.** Pushing uses the credential helper `openagents auth setup-git`
  installed, so the agent's `git push` is your `git push`. If the helper is not
  installed, the coder says so once and offers the exact command rather than
  writing credentials itself.

**The token never reaches the runtime.** The client exchanges it for a grant
and passes only the grant, in the child process environment at spawn, exactly
as probe's A4 appendix specifies: `PROBE_INFERENCE_GRANT` and
`PROBE_INFERENCE_URL`, never in argv, never in a file, never in a prompt. The
runtime removes both from any shell it spawns.

`openagents coder --token-stdin` does not exist and should not. If you want a
one-invocation token, `OPENAGENTS_TOKEN` already does that for every command.

---

## 6. The API surface, route by route

### 6.1 What exists today

Every route below is live at `d035a1186ee0`, with its router line.

**Model access.**

| Route | Line | Authority |
| --- | --- | --- |
| `POST /api/inference/proxy` | `router.ex:342` | An `inference_grants` bearer, not a user token |

The proxy translates an OpenAI-compatible body into
`OpenAgents.Providers.Request`, fans it into the configured provider, meters
usage against the grant, and returns chat-completions SSE. The grant pins the
model; a request body cannot select another
(`lib/openagents_web/controllers/inference_proxy_controller.ex:44`). This is
the coder's only model transport, and the runtime already speaks it.

**Repository and tracker context, for read-only tools.**

| Route | Line |
| --- | --- |
| `GET /api/v3/repos/:owner/:repo` | `router.ex:517` |
| `GET /api/v3/repos/:owner/:repo/issues` | `router.ex:518` |
| `GET /api/v3/repos/:owner/:repo/issues/:issue_number` | `router.ex:519` |
| `GET /api/v3/repos/:owner/:repo/issues/:issue_number/dependencies` | `router.ex:521` |
| `GET /api/v3/repos/:owner/:repo/pulls` | `router.ex:525` |
| `GET /api/v3/repos/:owner/:repo/pulls/:pull_number` | `router.ex:526` |
| `GET /api/v3/repos/:owner/:repo/stacks` | `router.ex:532` |
| `GET /api/v3/repos/:owner/:repo/projectsV2` | `router.ex:539` |

These sit on `:optional_forge_api`, which uses
`OpenAgentsWeb.Plugs.OptionalApiTokenAuth` with scope `forge:write`
(`router.ex:102`–`:106`), so a signed-in coder reads private repositories and an
anonymous caller reads public ones.

**Tracker and code writes, for write tools.**

| Route | Line |
| --- | --- |
| `POST /api/v3/repos/:owner/:repo/issues` | `router.ex:404` |
| `POST /api/v3/repos/:owner/:repo/issues/:issue_number/comments` | `router.ex:405` |
| `PATCH /api/v3/repos/:owner/:repo/issues/:issue_number` | `router.ex:587` |
| `POST /api/v3/repos/:owner/:repo/pulls` | `router.ex:588` |
| `POST /api/v3/repos/:owner/:repo/stacks` | `router.ex:591` |

Issue and comment creation run on `:agent_participation_api` with
`DualPrincipalAuth` (`router.ex:45`–`:49`); the rest run on `:forge_write_api`.

**Delegation, for handing work off.**

| Route | Line |
| --- | --- |
| `GET /api/v3/conversations/:conversation_id/delegation-targets` | `router.ex:420` |
| `POST /api/v3/conversations/:conversation_id/delegations` | `router.ex:421` |
| `GET /api/v3/conversations/:conversation_id/delegations/:id` | `router.ex:422` |
| `DELETE /api/v3/conversations/:conversation_id/delegations/:id` | `router.ex:423` |
| `GET /api/v3/computers` | `router.ex:429` |
| `POST /api/v3/computers/:computer_id/agent-jobs` | `router.ex:431` |
| `GET /api/v3/computer-agent-jobs/:id` | `router.ex:432` |
| `POST /api/v3/conversations/:conversation_id/boxes` | `router.ex:472` |
| `POST /api/v3/conversations/:conversation_id/boxes/:box_id/runs` | `router.ex:478` |

**Git transport.** `GET /:owner/:repo/info/refs` and the two pack routes at
`router.ex:318`–`:320`, reached through ordinary `git` with the CLI's
credential helper.

**Identity.** `GET /api/v3/user` (`router.ex:576`) for the status line, and the
two device-authorization routes at `router.ex:350`–`:351` that `auth login`
already uses.

### 6.2 What must be built

Four items, in dependency order. The first is the only one the first slice
needs.

**1. A route that mints a session-scoped inference grant to a user token.**

```text
POST   /api/v3/coder/sessions      →  {"session_id", "grant", "inference_url",
                                       "model", "expires_at", "max_calls",
                                       "max_total_tokens"}
GET    /api/v3/coder/sessions/:id  →  metered usage and status
DELETE /api/v3/coder/sessions/:id  →  revoked
```

Pipeline `:chat_account_api`, scope `chat:account`
(`lib/openagents_web/router.ex:57`). `OpenAgents.Inference.mint/1` needs
`owner_visitor_id`, `conversation_id`, and `machine_id`, and
`lib/openagents/work/coding.ex:64` already passes `machine_id: nil`, so the
schema takes a machine-less grant today. `conversation_id` resolves through
`Conversations.ensure_conversation(user)`, which keeps the grant
generation-fenced without creating a second conversation.

This route is where every abuse control lives and must not be a thin wrapper.
It needs ceilings independent of the delegation ceilings, a cap on concurrent
active grants per account, and revocation on `DELETE` and on process exit. It
also needs a decision about identity that section 11 records: a delegation
grant is fenced by a machine and a conversation, and a CLI grant has no
machine.

**2. Chunked delivery from the inference proxy.** The proxy builds the whole
SSE body and sends it once
(`lib/openagents_web/controllers/inference_proxy_controller.ex:155`–`:170`)
because its current consumer reads the full body before parsing. Sending each
event as a chunk as the provider produces it is additive, changes no contract,
and is what turns section 3.3's `waiting` into real streaming. The runtime's
JavaScript transport buffers too and would need the matching change in the
`probe` repository, where an incremental parse state already exists and is
unused by that path.

**3. A cursor on the chat event feed, if the coder ever reads it.** `GET
/api/v3/chat/events` returns every event for the account's conversation in one
unbounded array: the controller ignores its parameters and
`AccountTurns.list_events/1` has no bound. A `since` cursor over the `(run
inserted_at, run id, event sequence)` ordering the query already uses would make
the feed pollable. This is required only if the coder surfaces Sarah's
conversation, which section 11 argues against for the first slice.

**4. Checkpoint receipts and the commit trailer that links to them.** Both are
named as proposed in `docs/taxonomy.md`. This is Stage 4 and it is what makes a
coder-authored commit explicable. It is deliberately last, because designing a
receipt for work whose shape you have not observed produces a receipt nobody
writes.

Two things are **not** on this list, on purpose. There is no new tool-execution
endpoint: local tools run locally and delegated tools go through the delegation
routes that exist. And there is no `POST /api/v3/coder/turns`: a coder turn is
not a durable server record, for the reasons in section 4.2.

---

## 7. Tools and the approval policy

### 7.1 What runs locally

These execute in the runtime process, against the directory the client passed
as `cwd` on `session/new`, and never touch the network.

| Tool | ACP kind | Bound |
| --- | --- | --- |
| `read_file` | `read` | Offset and limit; 48 KiB output cap |
| `list_files` | `read` | 500 entries; `.git`, `node_modules`, `target`, `dist` skipped |
| `grep_files` | `search` | 200 lines |
| `write_file` | `edit` | Path confined to the workspace, never inside `.git` |
| `edit_file` | `edit` | Exact match, byte-order-mark and line-ending preserved, stale-content guard |
| `shell` | `execute` | `/bin/sh -c`, no standard input, 60-second default and 240-second ceiling, grant variables removed from the child environment |

Path resolution refuses a NUL byte, an absolute path, and any parent-directory
component; a mutation additionally refuses anything under `.git`. This is the
runtime's behavior today, not a proposal.

Two tools the client adds, because they are the client's business and not the
runtime's:

- **`git`**, in two shapes. Read-only invocations (`status`, `diff`, `log`) are
  routed like any read. `commit` and `push` are external effects and use the
  CLI's installed credential helper.
- **`delegate`**, described in section 8.

### 7.2 What runs on the server

Ordinary authenticated API calls the client makes with your token, carrying no
special local authority: reading and writing issues, reading pull requests and
stacks, and reading repository metadata, through the routes in section 6.1.
They are subject to the same ladder, because "open an issue" is an external
effect even though nothing on your disk changed.

### 7.3 The approval ladder

The runtime ships a default policy table: `read`, `edit`, `search`, and `think`
allow; `delete`, `move`, `execute`, `fetch`, and `other` require approval. The
`edit` choice is right for its original setting, where a delegated agent's
in-workspace edits are disclosed as tool-call frames under a controller's tier
policy. It is wrong for a terminal where the workspace is your own checkout and
you are watching. The client therefore configures the policy table it wants
rather than accepting the default, and `edit` moves to approval-required.

| Level | Applies to | Behavior |
| --- | --- | --- |
| Automatic | `read`, `search`, `think`; tracker reads | Runs, disclosed in the transcript |
| Ask once | `edit` inside the workspace | Prompts; `a` approves that kind for the session |
| Ask every time | `execute`, `fetch`, `delete`, `move`, `git push`, tracker writes, delegation | Prompts every call; `a` is unavailable |
| Refuse | Paths outside the workspace, unlisted tools, anything the token's scope does not cover | Typed refusal with the reason |

The rules underneath:

- **The model's request never widens the level.** This is the client-side
  mirror of TOOL-002: tool name, arguments, and prompt content grant no
  authority. The level comes from the configured policy table and the tool
  kind, decided before anything runs.
- **`a` is a client policy, not a wire option.** The runtime offers exactly
  `allow_once` and `reject_once` and never an "always", and the client must not
  add a third. `a` records a session-scoped, kind-scoped decision in the client
  and answers subsequent requests of that exact kind with `allow_once`. Every
  automatic approval is still disclosed in the transcript, and the decision is
  discarded when the process exits. There is no binding that means "stop
  asking".
- **Refusal is a bounded typed outcome the agent must handle**, never a silent
  substitution and never a fabricated success. That is DEGRADE-002 read as a
  client contract, and the runtime already implements the agent half.
- **`--approve <class>` exists for non-interactive use and names classes
  explicitly.** There is no `--yes`, no `--dangerously-*`, and no option whose
  id, name, or kind matches `/bypass/i` — the paired-computer controller
  already refuses such an option, and a command that offered one locally would
  be lying about what it can be trusted with.
- **Every outcome names its executor.** A tracker write the server performed
  and a file edit the runtime performed render differently, because TOOL-004's
  principle holds here: one interface must never imply OpenAgents performed
  hidden work.

---

## 8. Delegation: Box and connected Computer

`OpenAgents.Delegations` is the unified read-through facade over two
substrates: per-conversation Box VMs (`OpenAgents.Box`) and paired Computers
(`OpenAgents.Machines`, reached through `OpenAgents.ComputerAgentJobs`). It
stores no delegation state and derives every identifier and projection from
those substrate records, and IDENTITY-009 requires that it never widen what the
substrate allows. The coder consumes it and adds nothing.

**Outbound: the coder as a delegating client.** A `delegate` tool lists targets
through `GET /api/v3/conversations/:id/delegation-targets`
(`router.ex:420`), starts one through `POST .../delegations` (`router.ex:421`),
and polls `GET .../delegations/:id` (`router.ex:422`). Target identifiers are
opaque and kind-prefixed — `box:<uuid>` and `computer:<uuid>` — and the client
treats them as opaque. Delegation is an external effect and sits at "ask every
time". This is how a local session hands a twenty-minute build to a Box without
holding your terminal.

**Inbound: the same runtime, a different client.** This needs no new concept
and no new code in the CLI. `ComputerProjection.project/1` already publishes an
`acp_agents` array for each paired Computer from the machine's last probe
document, with `id`, `version`, `source`, `auth_ready`, `model`, and `mode`;
`ComputerAgentJobs.start/5` validates a requested `agent_id` against that
advertised list before creating a `work_jobs` row. The local computer
controller spawns the same runtime `openagents coder` spawns. The two paths
differ only in who holds the client end of the ACP connection: your terminal,
or the controller. Interactively, `session/request_permission` is answered by
your keystroke; under delegation, it is answered by the controller's tier
policy. Neither prompts inside the loop, which is exactly why section 2.2 is
not negotiable.

Two consequences worth stating.

- **This is the agent whose `auth_ready` can be honestly `true` on every paired
  computer.** Every other catalog entry needs its own credential on the
  machine. This one needs the account token the machine's owner already has,
  and the grant is minted per session.
- **The interface is the only thing the terminal adds.** If the OpenTUI layer
  is the differentiator, it is a differentiator over the same agent, which is
  the correct place for it to be.

Issue #127 covers the missing half of the inbound path: a delegation working a
repository issue on a connected Computer has no scoped push identity today.
`openagents coder` does not solve that and must not work around it. Where an
assignment credential is absent, the session reads, edits, and reports, and
says plainly that it cannot land the work.

---

## 9. Failure, offline, and expiry

**No network.** Local reads, `grep_files`, and read-only `git` keep working.
Every model call fails, the runtime reports a provider failure as a JSON-RPC
error on the prompt request, and the client renders it as a typed
`NetworkRefused` or `TransportError` — exit code 6 through the existing table.
The transcript is already on disk, so `--resume` recovers it.

**The token expires mid-session.** This is the sharpest gap the CLI has today.
`DeviceToken.expires_in` is decoded and then discarded
(`packages/openagents-cli/src/device-client.ts:21`, `:96`); nothing persists an
expiry, there is no refresh token, and no call site retries a `401`. For a
command that runs for seconds this is invisible. For a session that runs for
hours it is the common failure.

The behavior: the token is used only to mint and to revoke, so an expiry
mid-session does not interrupt the current grant, which keeps working until its
own budget or clock runs out. When the next mint returns `401`, the client
surfaces a typed `AuthenticationRequired` in the status line and suspends
rather than terminating. Any in-flight tool finishes and records its outcome.
You run `openagents auth login` in another terminal and press a key to retry.
Nothing is lost except elapsed time. Persisting the server-reported expiry
alongside the credential so the status line can warn before the wall arrives is
a small CLI change and belongs in Stage 2.

**The grant is exhausted, expired, or revoked.** `Inference.resolve/1` fails
closed with `grant_exhausted`, `grant_expired`, `grant_budget_reached`, or
`grant_revoked`, each distinct. The interface shows the reason, not a generic
failure, because "you are out of budget" and "your session expired" call for
different actions. Exhaustion offers to mint a new session grant; revocation
does not.

**The turn is interrupted.** The runtime treats cancellation as a state
transition and returns a `cancelled` stop reason with the partial text intact.
Tool outcomes already recorded stay recorded, and the next prompt carries the
honest history. That is TURN-004's principle applied locally: interrupted work
becomes explicit failure, never something left presented as in progress.

**The runtime dies.** The client detects the closed pipe, marks the turn
failed, drains and discards the child's standard error rather than rendering
it, and offers to restart. A restart is a new session identifier and a new
prompt, because nothing restores a transcript across runtime processes today.
The client's own transcript survives, which is why section 4.2 keeps it in the
client.

**The renderer cannot start.** Fall back to line-oriented mode, print one
notice on standard error, and continue.

**The process is killed.** `SIGINT` and `SIGTERM` exit 130 and terminate child
processes, which the package already proves against a live process
(`packages/openagents-cli/test/signals.test.ts:70`, `:151`). The coder adds two
obligations: send `SIGTERM` to the runtime with `SIGKILL` behind it, and revoke
the grant on the way out on a best-effort basis without blocking exit. A grant
that outlives its session is a budget another process can spend.

---

## 10. Delivery

Five stages. Each names the repository it touches. Stage 1 is usable on its
own, which is the test of whether the staging is honest.

**Stage 1 — a grant, a client, and read-only tools.**
*This repository:* `POST`, `GET`, and `DELETE /api/v3/coder/sessions` on
`:chat_account_api`, with ceilings, per-account concurrency limits, and
revocation, plus controller and context tests.
*The `openagents` monorepo:* `openagents coder [prompt]` registered at
`packages/openagents-cli/src/cli.ts:909`; a `CoderSession` service that mints
and revokes; an `AcpClient` service that spawns the runtime with the grant in
the child environment and speaks newline-delimited JSON-RPC over its standard
streams; line-oriented output only; the local transcript file.
*The `probe` repository:* nothing, if its published package already serves ACP
over standard input and output with the six tools; otherwise raise its
JavaScript host to parity with its native host, which today ships two of the
six.
*Done when:* `openagents coder "what does this repository do"` in a fresh
checkout answers from files it read, and `openagents api "coder/sessions/<id>"`
shows the metered calls.

**Stage 2 — the OpenTUI interface.**
*The `openagents` monorepo only.* `@opentui/core` as an optional dependency;
the renderer as a pure function from a session snapshot to a renderable tree,
fixture-tested; the split-footer layout; streaming Markdown; `CodeRenderable`
and `LineNumberRenderable` for tool output; the status line with grant budget;
double-escape interruption; the three-mode degradation table from section 3.6;
persisted token expiry so the status line can warn.
*Done when:* the interface renders on macOS and Linux and the fallback path is
a test rather than a claim.

**Stage 3 — writes, approvals, and Git.**
*The `openagents` monorepo:* the approval decision pane with `DiffRenderable`;
the configured policy table from section 7.3; the session-scoped `a` decision;
`--approve <class>`; the `git` tool through the existing credential helper.
*The `probe` repository:* whatever parity gaps Stage 1 exposed in the
JavaScript host's tools.
*Done when:* a session opens a pull request against this repository and every
mutation in it was approved through the pane.

**Stage 4 — tracker tools and checkpoint receipts.**
*This repository:* the checkpoint receipt family and the commit trailer that
links a commit to it, both currently proposed in `docs/taxonomy.md`; the
`INVARIANTS.md` entry and its executable proof.
*The `openagents` monorepo:* issue and pull-request tools over the routes in
section 6.1, and trailer emission on commit.
*Done when:* a forge commit page shows the session behind the change.

**Stage 5 — delegation, in both directions.**
*The `openagents` monorepo:* the `delegate` tool over the delegation routes.
*This repository:* nothing new, if the runtime is already advertised in probe
documents; otherwise the catalog work that puts it there.
*Done when:* a paired Computer advertises the runtime and Sarah delegates an
issue to it from the web surface while you drive the same runtime locally.

Chunked delivery from the inference proxy (section 6.2, item 2) is independent
of all five and can land whenever someone wants real streaming.

---

## 11. Open questions

**Is the runtime package installable today?** The whole architecture rests on
`openagents coder` spawning an already-built agent rather than reimplementing
one. Its WebAssembly artifact is checked in and its ABI is synchronous, which
removes the hard obstacles, but its JavaScript host ships two of the six tools
its native host has, and whether the package is published at all is not
settleable from this repository. *Settle it with:* `npm view @openagentsinc/probe`
and, in the `probe` repository, `git log --oneline -- packages/probe/src/tools.ts`.

**Does the client spawn the JavaScript host or a native binary?** The
JavaScript host runs anywhere Node runs and needs no platform matrix; the
native binary is faster and has the full tool set. Shipping both means a
platform matrix inside a global npm install. *Settle it with:* the tool-parity
answer above, plus a measurement of WebAssembly startup on a cold `npx`.

**What fences a CLI grant?** A delegation grant is fenced by a conversation and
a machine. A CLI grant has a conversation and no machine. Whether that is
sufficient, and what per-account concurrency ceiling replaces the missing
machine fence, is a policy decision this document proposes and does not settle.
*Settle it with:* the ceilings in `lib/openagents/inference.ex` and a decision
from the owner on what a signed-in account may spend without a paired computer.

**Does a coder session need an invariant of its own?** Every authority boundary
here has an `INVARIANTS.md` entry with a named executable proof, and an
invariant without a passing proof is a wish. A client-minted, machine-less
inference grant is a new authority shape. *Settle it with:* whether the Stage 1
route is covered by IDENTITY-005's and TOOL-002's existing proofs or needs a
`CODER-001`.

**Which package version is real?** The `openagents` monorepo at `df62c1fe353d`
has `packages/openagents-cli` at version `0.2.1` with three subcommand groups
and no `forum`; npm serves `0.3.0`, whose help output lists a `forum` group.
Separately, `packages/openagents-cli/src/cli.ts:31` declares
`VERSION = "0.1.7"` while `package.json` says `0.2.1`, which makes
`scripts/verify-packed-install.mjs` fail its own version assertion. Every CLI
citation here is against the monorepo tree, not against npm. *Settle it with:*
`npm view @openagentsinc/cli versions` and, in that monorepo,
`git log --oneline -- packages/openagents-cli`.

**Can the OpenTUI artifact ship through a global npm install?**
`@opentui/core` at `0.3.4` resolves one of eight platform-specific optional
native packages and peers `web-tree-sitter`. Whether `npm install --global`
gets a working renderer on macOS arm64, macOS x64, Linux x64, and Linux arm64
decides whether Stage 2's optional dependency is a convenience or a
requirement. *Settle it with:* `npm view @opentui/core` for the current
optional-dependency list, and one global install on each target.

**Where does the local transcript live, and for how long?** The CLI reads
`~/.config/openagents/config.json` and writes
`~/.config/openagents/device-authorizations.json`, and has never written a data
file of unbounded size. A session transcript is a different artifact and may
want its own root, a retention bound, and a `coder clean`. *Settle it with:*
`packages/openagents-cli/src/persisted-configuration.ts:39` for the current
directory rules, and a decision on retention.

**Do you want Sarah's conversation in the terminal at all?** `GET
/api/v3/chat/events` and `POST /api/v3/chat/turns` are reachable with a
`chat:account` token, so `openagents coder` could surface the same conversation
the web surface shows. It would also mean two authors writing into one
conversation under TURN-001's single-active-turn constraint. This document says
no for the first slice. *Settle it with:* whether the product wants one
conversation across surfaces, which is a question for the owner and not for the
router.

**What does the ratatui prior art already answer?** The `probe` repository's
`origin/codex/issue-142-coder-compat` branch carries
`docs/101-openagents-coder-runtime-adapter.md` and a contract test named for a
coder runtime adapter, plus design documents for a retained transcript, a typed
overlay stack, and a resumable approval broker. Some of section 3 may be
re-deciding what that lineage settled. *Settle it with:* `git show
origin/codex/issue-142-coder-compat:docs/101-openagents-coder-runtime-adapter.md`
in that repository, before Stage 1 starts.
