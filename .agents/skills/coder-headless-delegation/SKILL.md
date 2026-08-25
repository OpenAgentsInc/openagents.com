---
name: coder-headless-delegation
description: Drive `openagents coder` headlessly from an agent session to delegate real coding work to child agents (Devin, Claude Code, Codex), then monitor, steer, and verify.
allowed-tools:
  - read
  - exec
  - grep
---

Use this skill when you need to delegate coding work through the OpenAgents
coder rather than doing it yourself or spawning your own subagents. The chain
is: you (headless client) → `openagents coder` (thread lane on the forge) →
its `delegate` tool → a child harness such as Devin. You stay in the
monitor/steer/verify role; the coder composes the child prompt, supervises the
child, and reviews its output; the child writes the code.

This was proven end to end on 2026-08-24 (Gym suite runner built by Devin
through the coder). Everything below is what that run taught.

## When to use it

- The user asks for coding work to be delegated "through the coder" or "to
  Devin" — this channel, not the Agent tool.
- You want the work recorded on the forge's thread plane (thread events,
  delegation receipts) instead of invisible subagent context.

Do not use it for Terminal-Bench or other benchmark tasks unless the user
explicitly says so. When the user says "delegate the coding work," they mean
real development tasks (scripts, features, plugins), not graded gym tasks.

## Launch recipe

The dev build lives in the monorepo. The `coder` shell function in
`~/.zshrc` builds and runs it; headless, call node directly:

```sh
SCRATCH=<your scratchpad>
cd <workspace the child should code in>          # cwd at launch = coder workspace
mkfifo $SCRATCH/coder-stdin 2>/dev/null || true
( tail -f $SCRATCH/coder-stdin | \
  OPENAGENTS_TOKEN=$(cat <token file>) \
  node /Users/christopherdavid/work/openagents/packages/openagents-cli/dist/main.js \
    coder --plain --dev > $SCRATCH/coder-session.log 2>&1 & )
```

- `--dev` selects the local profile (`http://localhost:4000`) and auto-starts
  the Phoenix dev server if it is not running. Without a local forge, drop
  `--dev` to talk to production.
- Build first if `dist/` may be stale: `pnpm build` in
  `packages/openagents-cli` (pnpm, never npm — the workspace uses `catalog:`
  versions).
- The token needs `chat:account` scope. Never print it; read it from a file.
- Use a clean git worktree as the workspace. Never launch from a checkout
  another session is using, and never rebase or reset the worktree while a
  child is working in it.

## Talking to it: `--plain` is line-oriented

**Every stdin line is a separate message.** A heredoc or multi-line brief
fragments into many messages, which confuses the coder and can trigger the
delegate tool more than once. Always send a brief as one physical line:

```sh
tr '\n' ' ' < brief.txt > brief-oneline.txt   # or compose it single-line
cat brief-oneline.txt > $SCRATCH/coder-stdin
```

Steering works the same way mid-turn: write another line into the FIFO and it
arrives as a steering message.

## Composing the delegation brief

Tell the coder, in one message:

1. **Delegate, don't do.** "Use your delegate tool with model `devin`,
   count 1. Do not write the code yourself."
2. **The child has zero context.** The prompt the coder passes must be fully
   self-contained: repository layout, existing files to read, exact
   requirements, examples, and acceptance checks. Spell these out in your
   brief so the coder can relay them.
3. **No git side effects.** "Tell the child not to commit or push." You
   commit yourself after verifying, via the owning repo's flow (forge remote,
   assure-repo artifacts for the monorepo).
4. **Review before reporting.** "When the child finishes, review its work
   with your shell tool (run `--help`, a dry-run, the tests) and report a
   verdict."

## Monitoring

- `tail`/`grep` `$SCRATCH/coder-session.log` for `[tool] delegate` and the
  coder's prose. Poll with an `until` loop in a background Bash rather than
  sleeping in the foreground.
- Child liveness: `pgrep -fl "devin -p"` (or the child harness's CLI name).
  The full child prompt is visible in the process args — a quick check that
  the coder relayed your requirements.
- **Verify exactly one child.** A fragmented brief can fire delegate twice.
- Delegation ledger: JSONL per child under
  `$TMPDIR/openagents-coder-delegations/`. Caution: that directory is shared
  by every coder on the machine, including other agent sessions' children.
  Match a ledger file to your child by the paths in its events, not by
  recency.
- Watch for the artifact itself (file existence) as the ground-truth signal;
  log patterns produce false positives.

## Failure modes seen in practice

- **Thread quota (422, "8 open threads maximum").** Killed or crashed coder
  processes leave threads open. Clean up: `GET /api/v3/threads`, then
  `DELETE /api/v3/threads/{id}` for each open one (bearer token). Lifecycle
  fix is tracked in openagents.com#209.
- **Dev-server hard 500s after config changes.** The Phoenix code reloader
  fails all requests if `config/*.exs` changed on disk; the server needs a
  restart. Also check for two beams fighting over port 4000.
- **Stale build.** The coder runs `dist/main.js`; a source edit does nothing
  until `pnpm build`.

## Verification stance

The coder's verdict is input, not proof. After it reports, run the artifact
yourself (help text, dry-run, tests) in the worktree, then commit and push
through the owning repo's normal flow. Report the child's work, the coder's
review, and your own check separately.

## Known gaps worth filing or fixing

- No single-shot flag (`--prompt-file` / `-p`) for `coder --plain`; the FIFO
  dance stands in for it.
- Delegation ledgers carry no owning-session marker, so attribution requires
  reading event paths.
