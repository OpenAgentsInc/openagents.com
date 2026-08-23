# Nested thread and delegation capability audit

**Date:** 2026-08-23

**Question:** What are the complete operational, lifecycle, permission, and
isolation properties of a nested thread / subagent delegation tool? Where does
the same capability already exist in OpenAgents, where is it only modeled, and
what invariant and Effect-shaped seams should own it?

**Method:** Cleanroom behavioral analysis of a reference agent runtime. The
observations below are translated into OpenAgents vocabulary. No source code,
internal identifiers, file paths, or implementation-specific names from the
reference system are reproduced here.

---

## 0. Verdict

A full delegation capability is more than a "run this prompt in the background"
surface. It is a family of execution shapes, each with a different contract for
context sharing, prompt-cache behavior, permission authority, transcript
ownership, and terminal cleanup. The reference runtime supports five distinct
shapes, and they are not interchangeable.

OpenAgents already owns the durable primitives that could support all five:

- `OpenAgents.Delegations` provides the target-kind dispatch and auth boundary
  for `box` and `computer` targets (`IDENTITY-009`).
- `OpenAgents.Work` provides `work_jobs` with `kind` values for `deep_work`,
  `delegation`, `coding`, and `scv`.
- `OpenAgents.Agents` provides agent identity and human-linked grants.
- The `threads` and `nested thread` concepts are reserved in
  `docs/taxonomy.md` but not yet implemented.

The gap is not a missing table. It is a missing **nested-thread ledger** and a
**delegation turn-contract** that records a child turn's authority snapshot,
budget, transcript link, and completion receipt independently of the parent
conversation. The reference runtime keeps all of that in a per-session
`subagents/` transcript tree and a task registry. OpenAgents should hold the
same evidence in durable PostgreSQL rows.

---

## 1. Vocabulary and scope

This audit uses the following OpenAgents-native terms. Terms that are
*proposed* in `docs/taxonomy.md` are treated as reserved vocabulary, not as
live features.

- **Parent turn** — the turn that calls the delegation tool.
- **Nested thread** — a child thread created when a parent turn spawns another
  agent during the same body of work.
- **Delegation target** — the execution substrate: a `box`, a `computer`, or
  an in-process worker.
- **Worker** — the agent runtime that executes the nested thread.
- **Directive** — the task prompt given to the worker.
- **Work job** — the durable `work_jobs` row that outlives the parent turn.
- **Receipt** — the append-only durable evidence that a delegation happened.
- **Sidechain transcript** — a transcript that belongs to the worker, not the
  main conversation.
- **Effect contract** — the OpenAgents Effect Schema that authorizes and
  records the delegation.

---

## 2. What the tool does

The delegation tool lets a parent turn spawn a worker to perform a complex,
multi-step task. The worker receives a directive, a scoped tool pool, and a
selected execution mode. When the worker finishes, the parent receives a result,
a terminal receipt, and optionally a notification.

A cleanroom analysis of the reference runtime reveals five execution shapes:

1. **Synchronous worker** — the parent turn blocks until the worker completes.
2. **Background worker** — the worker runs independently; the parent receives a
   notification later.
3. **Forked worker** — the worker inherits the parent's full conversation
   context and prompt-cache prefix.
4. **Isolated worker** — the worker runs in a separate worktree or working
   directory.
5. **Remote worker** — the worker runs in a cloud environment, polled by the
   local runtime.
6. **Teammate** — a named, addressable worker that can send and receive
   messages and coordinate with other workers.

---

## 3. Invocation shape

The tool accepts a common input set. The fields below are translated to
OpenAgents parameter names. Optional fields are omitted in some contexts (for
example, a teammate context removes `run_in_background` and `name` is not
available to a worker that is already a teammate).

### Core parameters

- `description` — short summary (3–5 words) used for the work-job label and
  notifications.
- `prompt` — the directive the worker follows.
- `worker_type` — which worker definition to use. In OpenAgents, this is the
  `agent_type` or `role` selector.
- `model` — optional model override; takes precedence over the worker
  definition and the parent.
- `run_in_background` — force background execution.

### Multi-agent parameters

- `name` — human-readable name for the worker, used for message routing.
- `team_name` — the team context for coordinated workers.
- `mode` — permission mode for a teammate (for example, `plan` requires plan
  approval).

### Isolation parameters

- `isolation` — `worktree` or `remote`.
- `cwd` — absolute working-directory override. Mutually exclusive with
  `isolation: "worktree"`.

### Output

The tool can return one of the following, depending on mode:

- `completed` — the worker result and metadata.
- `async_launched` — the work-job id, the output artifact path, and a flag
  indicating whether the parent can read the output.
- `teammate_spawned` — the teammate id, name, color, and routing address.
- `remote_launched` — the remote session id, session URL, and output path.

---

## 4. Worker catalog and selection

### Definition sources

The worker catalog is built from overlapping sources. Later sources win on type
name conflicts. This is the reference runtime's discovery order, translated to
OpenAgents:

1. **Built-in workers** — packaged with the runtime and always available.
2. **Plugin workers** — provided by installed plugins.
3. **User workers** — defined by the account owner in user settings.
4. **Project workers** — defined in the repository under a project-scoped
   directory.
5. **Policy workers** — organization-managed definitions from policy settings.
6. **Flag workers** — definitions injected through feature flags or CLI flags.

### Filtering pipeline

Before a worker is selectable, it passes a pipeline:

1. **External dependency requirement** — if a worker declares a required
   external tool provider, it is hidden until that provider is connected.
2. **Permission-deny rules** — workers denied by `Worker(type)` permission
   rules are removed.
3. **Worker-type restriction** — a parent can declare a restricted allowlist
   (for example, `Worker(explorer, reviewer)`); only those types appear.
4. **Feature gating** — some built-in workers are hidden behind feature flags.

### Selection logic

- If `worker_type` is present, the catalog is searched. A missing type returns
  the available list. A denied type returns the denying rule and source.
- If `worker_type` is omitted and fork mode is enabled, the worker is treated as
  a fork of the parent.
- If `worker_type` is omitted and fork mode is disabled, the default
  general-purpose worker is used.

### Worker definition fields

A worker definition carries the following fields:

- `worker_type` — the selector.
- `when_to_use` — one-line guidance for the model.
- `tools` — allowed tools, or `*` for all after filtering.
- `disallowed_tools` — explicit denylist.
- `model` — preferred model, or `inherit` to use the parent's.
- `permission_mode` — default permission mode for the worker.
- `max_turns` — upper bound on worker turns.
- `isolation` — default isolation mode.
- `background` — whether the worker always runs in the background.
- `skills` — skills to preload into the worker's initial context.
- `memory` — persistent memory scope: `user`, `project`, or `local`.
- `required_providers` — required external tool providers.
- `hooks` — lifecycle hooks to register while the worker runs.

---

## 5. Execution modes

The mode is decided at call time from the parameters and the worker definition.

### Synchronous worker

- The parent turn blocks.
- The worker shares the parent's abort controller, so a parent abort kills the
  worker.
- Permission prompts can surface in the parent's UI.
- The result is returned directly to the parent.

### Background worker

- The worker gets its own unlinked abort controller.
- The parent receives an `async_launched` result immediately.
- A work job is registered and tracks progress.
- On terminal state, a notification is enqueued for the parent.
- Permission prompts are auto-denied or awaited through automated checks.

### Forked worker

- Enabled only when the fork experiment is active and `worker_type` is omitted.
- Always runs in the background.
- Inherits the parent's full conversation and rendered system prompt bytes.
- The parent's prompt-cache prefix is preserved for cache sharing.
- Recursive forking is blocked: a fork child cannot spawn another fork.

### Worktree-isolated worker

- A temporary worktree is created.
- The worker receives a notice to translate paths from the parent context and
  to re-read potentially stale files.
- If the worker makes no changes, the worktree is automatically removed.
- If the worker makes changes, the worktree path and branch are returned in the
  result.

### Remote worker

- Always a background task.
- Precondition checks include authentication, cloud environment availability,
  a git repository, a forge remote, and an installed GitHub app.
- The remote session is launched; the local side polls for status and output.

### Teammate

- Triggered when both `name` and `team_name` are provided.
- Two substrate variants exist:
  - **In-process teammate** — runs in the same runtime with context isolation.
  - **Pane-based teammate** — runs in a separate terminal multiplexer pane.
- Teammates can send and receive messages and share a task list.
- A teammate cannot spawn another teammate; the team roster is flat.

---

## 6. Lifecycle

### Spawn phase

1. Validate parameter combinations.
2. Resolve the worker definition.
3. Check permission-deny rules.
4. Create an isolated `ToolUseContext` with cloned mutable state.
5. Assemble the worker's tool pool.
6. Register a `work_jobs` row or task state.
7. Create the abort controller.
8. Initialize the sidechain transcript.

### Execution phase

1. Execute `SubagentStart` hooks.
2. Connect worker-specific external tool providers and merge their tools.
3. Compose the worker's system prompt and initial messages.
4. Run the worker's query loop.
5. Track token counts, tool uses, and activity descriptions.
6. Record every message to the sidechain transcript.

### Completion phase

1. Execute `SubagentStop` hooks.
2. Finalize the result: extract text, count tool uses, compute usage.
3. Mark the work job as completed.
4. Enqueue a notification to the parent.
5. Emit cache-eviction hints for the worker's prompt-cache prefix.
6. Disconnect external tool providers and clean up the worktree if unchanged.
7. Schedule output artifact eviction.

### Cancellation phase

1. Signal the worker's abort controller.
2. Cancel in-flight inference requests.
3. Mark the work job as killed.
4. Extract any partial result from the sidechain transcript.
5. Enqueue a killed notification.
6. Disconnect external tool providers and remove the worktree if applicable.

---

## 7. Context model

The worker's context is a controlled subset of the parent context. The exact
subset depends on the mode.

### Message context

- **Synchronous worker** — starts fresh, with only the directive.
- **Forked worker** — receives the parent's full conversation, including the
  assistant message that triggered the tool use.
- **Teammate** — starts with empty messages to avoid pinning the parent's
  conversation for the teammate's lifetime.
- **Resumed worker** — receives the prior sidechain transcript.

### File-state cache

The parent's file-state cache is cloned for all workers. This keeps read
budgets, tool-result replacement state, and path containment coherent without
letting the worker mutate the parent cache.

### Tool pool

The worker's tool pool is assembled independently of the parent's. The process:

1. Start from the global tool catalog.
2. Apply permission-deny rules.
3. Apply the worker's `tools` and `disallowed_tools`.
4. Apply async-worker restrictions when the worker is in the background.
5. Merge tools from worker-specific external tool providers.
6. Deduplicate by tool name; built-in tools win over provider tools.

### Permissions

- The worker's `permission_mode` can override the parent's, except when the
  parent is in `bypassPermissions`, `acceptEdits`, or `auto` mode.
- Synchronous workers can surface permission prompts in the parent's UI.
- Background workers cannot show prompts; they either auto-deny or await
  automated checks (classifier, hooks).
- Teammates route permission requests to the team leader's UI.
- SDK-level `alwaysAllowRules` are preserved across all workers.

### Model

Resolution order:

1. Explicit `model` parameter.
2. Worker definition's `model`.
3. Parent's model.

Forked workers inherit the parent's model to preserve context-length parity
and prompt-cache compatibility.

### Prompt cache

Forked workers maximize cache sharing by using the parent's exact rendered
system prompt bytes and the same tool-pool ordering. Any change to model,
`max_tokens`, `thinking` configuration, or tool order can break the cache.

---

## 8. Prompt and system context composition

The worker's system prompt is built from several layers:

1. **Worker prompt** — the definition's system prompt.
2. **User context** — project-specific guidelines, scope notes, and persistent
   memory.
3. **System context** — environment details such as working directory and git
   status.
4. **Hook output** — additional context from `SubagentStart` hooks.
5. **Memory injection** — persistent worker memory if `memory` is enabled.
6. **Teammate addendum** — extra instructions for in-process teammates.

For forked workers, the system prompt is replaced by the parent's rendered
bytes. This avoids recomputing a prompt that may diverge and break cache.

### Prompt style

- For fresh workers, the directive should be a complete briefing.
- For forked workers, the directive is a narrow scope statement because the
  worker already has the parent's context.
- The prompt should not push synthesis back onto the worker. It must be
  specific about file paths, line numbers, and expected changes.

---

## 9. Permission and tool scoping

### Worker allow/deny lists

- `tools` — explicit allowlist or `*` for all after filtering.
- `disallowed_tools` — explicit denylist.
- Global disallow lists — for example, the worker tool is denied to subagents
  to prevent unbounded recursion.
- Async restrictions — only a safe subset of tools is available to background
  workers.

### Tool-spec restrictions

A parent tool can declare a restricted worker set:

- `Worker(explorer,reviewer)` — only those worker types may be spawned.
- `Worker(code-reviewer)` — denies all worker types except the named one.

### External tool providers

- Workers can declare their own external tool providers in their definition.
- Inline provider definitions are created and destroyed with the worker.
- Provider references are shared with the parent and are not destroyed.
- A plugin-only policy can restrict provider access to admin-trusted sources.

---

## 10. Transcripts and artifacts

### Sidechain transcript

- Stored as a JSONL file in a per-session `subagents/` directory.
- One message per line.
- Includes assistant, user, progress, and compact-boundary messages.
- Optional subdirectories group related workers.

### Output artifact

- A stable path for the parent to read worker progress.
- The parent's access depends on whether the parent has read or shell tools.
- Evicted after a grace period on terminal state.

### Resume support

- The prior transcript is loaded and filtered.
- Incomplete tool calls, orphaned thinking, and whitespace-only messages are
  removed.
- Tool-result replacement state is reconstructed from sidechain records.
- The worktree path is validated; if it no longer exists, the parent working
  directory is used.
- Worker metadata is persisted across resume.

---

## 11. Work-job registry and progress

### Registration

- Each worker is a task with a type-prefixed id.
- State includes status (`pending`, `running`, `completed`, `failed`, `killed`),
  description, start and end times, and an output artifact pointer.
- A cleanup handler is registered for process exit.

### Foreground to background promotion

- A foreground worker can be auto-backgrounded after a threshold of elapsed
  time.
- A `background_signal` promise resolves when the user confirms the promotion.
- The message buffer is retained during promotion.

### Progress tracking

- Tool use count.
- Cumulative input and output tokens.
- Recent activity list with tool-specific descriptions.
- Optional 1–2 sentence summary generated by a periodic summarizer.

### Terminal state

- `completed` — result stored, notification enqueued.
- `failed` — error stored, notification enqueued.
- `killed` — partial result extracted, notification enqueued.
- The `notified` flag prevents duplicate notifications.

---

## 12. Termination, resume, and restart

### Termination

- `kill` marks the task as killed, aborts the controller, and triggers cleanup.
- `kill_all` stops every running worker of the current session.
- For teammates, a shutdown request is sent first; a force kill uses the
  abort controller.

### Resume

- Load the sidechain transcript.
- Resolve the worker definition from persisted metadata.
- Reconstruct the system prompt for forked workers.
- Re-register the task under the same id.
- Append the new directive to the resumed messages and continue.

### Restart

- A full restart is not provided as a single operation.
- The equivalent is a fresh invocation with a new work-job id.

---

## 13. Nesting and safety

### Recursive fork guard

- A forked worker cannot spawn another forked worker.
- Detection uses a synthetic marker in the forked worker's messages.
- Attempts are rejected at call time.

### Teammate nesting

- A teammate cannot spawn another teammate.
- The team roster is flat.
- In-process teammates cannot spawn background workers.

### Depth tracking

- Each worker increments a query-chain depth counter.
- No hard depth limit is enforced, but recursion is prevented by tool-pool and
  fork guards.

### Isolation and safety properties

- **Worktree isolation** — worker filesystem changes are isolated and
  discarded if unused.
- **Working-directory containment** — `cwd` and worktree paths are validated.
- **Abort unidirectionality** — parent abort can kill child; child abort does
  not propagate to parent.
- **Model scoping** — model resolution is explicit and bounded.
- **Provider scoping** — worker-specific external providers are created and
  destroyed with the worker.
- **Permission scoping** — worker permission mode and tool pool are computed
  independently of the parent.

---

## 14. Events and notifications

### Lifecycle hooks

- `SubagentStart` — fired when the worker starts.
- `SubagentStop` — fired when the worker stops, with transcript and last
  message metadata.
- `TaskCreated`, `TaskCompleted` — task registry events.
- `TeammateIdle` — fired when a teammate finishes and is ready for new work.

### Notifications

- A structured notification is enqueued for the parent on terminal state.
- Fields include work-job id, status, summary, output path, usage, and
  worktree path/branch if applicable.
- The `notified` flag deduplicates.

### Event consumers

- The parent agent receives notifications as system messages.
- The UI consumes task state for progress displays.
- The analytics system receives usage and completion events.
- External SDK consumers receive lifecycle and progress events.

---

## 15. OpenAgents mapping

### What is already live

- `OpenAgents.Delegations` is the unified delegation surface.
- `OpenAgents.Work` owns durable `work_jobs` rows.
- `OpenAgents.Box` and `OpenAgents.ComputerAgentJobs` are the two substrate
  authorities (`IDENTITY-009`).
- `OpenAgents.Agents` provides agent identity and grants.
- `OpenAgents.Turns` and `OpenAgents.Conversations` own the canonical turn
  ledger.

### What is modeled but not wired

- `nested thread` is defined in `docs/taxonomy.md` but has no schema.
- `threads` table is proposed in `docs/2026-08-23-thread-primitive-audit.md`.
- `work_jobs` already supports `delegation` and `coding` kinds; a nested
  thread kind would be additive.

### What is open in the issue tracker

This audit does not claim an issue number. The nested-thread primitive and a
thread-scoped `inference_grants` column are the adjacent open work described in
`docs/2026-08-23-thread-primitive-audit.md`.

### Invariant boundaries

The following existing invariants should constrain any nested-thread
implementation:

- `IDENTITY-009` — the unified delegation surface must not widen the reach
  available through the underlying `box` or `computer` substrate.
- `WORK-001` — a `work_jobs` row is bounded; no job may start another SCV.
- `TURN-001..005` — every turn is an immutable provenance receipt.
- `DATA-002` — one conversation per visitor; a thread is not a conversation.

### Effect-shaped contract

A new delegation Effect should own the spawn-to-completion lifecycle:

- `effect: thread.spawn` — record the parent turn, worker type, authority
  snapshot, budget, and target kind.
- `effect: thread.resume` — re-attach to an existing sidechain transcript.
- `effect: thread.cancel` — abort and record the terminal reason.
- `effect: thread.complete` — record the outcome receipt and link it to the
  parent turn.

These Effects are not a replacement for `OpenAgents.Delegations`; they sit
above it, adding the nested-thread identity and transcript-link concerns that
`work_jobs` does not currently carry.

### Tests, smokes, and receipts needed

- A test that a forked worker cannot spawn another forked worker.
- A test that a teammate cannot spawn another teammate.
- A test that worktree isolation leaves no changes when the worker made no
  edits.
- A smoke that a background worker outlives its parent turn and that the
  notification is delivered on the next parent turn.
- A receipt schema for nested-thread outcomes bound to the parent turn.
- A projection-freshness check that the UI does not show stale worker state
  after a node restart.

---

## 16. Gaps and recommendations

1. Add a `threads` table and make `inference_grants.conversation_id` nullable
   with a new `thread_id`, as recommended in
   `docs/2026-08-23-thread-primitive-audit.md`.
2. Extend `work_jobs` with a `nested_thread` kind or add a separate
   `nested_threads` table that links to `turn_receipts`.
3. Define an Effect contract for thread spawn, resume, cancel, and complete.
4. Store sidechain transcripts in a durable, public-safe form so they survive
   node restarts and can be audited.
5. Implement the fork and teammate recursion guards before enabling nested
   thread delegation in production.
6. Add a thread-scoped capability ref so a worker's tool pool and permission
   mode are recorded as an authority snapshot, not inferred from the parent.
