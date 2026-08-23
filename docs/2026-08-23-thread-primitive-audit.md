# Making Thread the primary agent interaction primitive

**Date:** 2026-08-23

**Commits measured:** `8664b6064343` on `openagents/main` for this repository,
with the uncommitted `docs/taxonomy.md` Threads section in the same working
tree; `56eaa4243210` in the `openagents` monorepo for `packages/openagents-cli`
(package version `0.2.1` in that tree); `bf2aee99c5` in the `openai/codex`
reference clone for the app-server protocol.

**Question:** What has to be true for a Thread to be the primary agent
interaction primitive in the web `/chat` surface and in the `openagents coder`
CLI? What already holds a thread, what refuses to, and what is the smallest
honest first slice?

**Method:** direct reading of every migration under `priv/repo/migrations/`
that creates a table whose name ends in `_runs`, `_jobs`, `_sessions`,
`_events`, or `_steps`; the Ecto schema and context for each; `INVARIANTS.md`;
`lib/openagents_web/router.ex` and `lib/openagents_web/api_route_authority.ex`;
and the CLI sources in the `openagents` monorepo. Nullability claims come from
migration text, never from an Ecto schema. Claims neither repository can settle
are in section 8 with the command that settles them.

---

## 0. Summary

**One thing is genuinely one-per-user, and it is smaller than it looks.** Two
unique indexes make a person's conversation singular. Nothing else in the
database says one-per-user. Everything else that looks singular is singular
*because* it hangs off that conversation.

**The defect is a coupling wall, not the conversation itself.** Three tables
declare `conversation_id` as `null: false`: `work_jobs`, `inference_grants`,
and `box_runs`. `inference_grants` is the one that decides the outcome, because
it is the only way a client gets model authority without a provider key. A
grant cannot exist without a conversation, so an execution outside the
canonical conversation cannot buy a token today. That is why the CLI's only
working path was `POST /api/v3/chat/turns`, and it is why coder prompts landed
where the person did not put them.

**The consequence is worse than a shared row.** `AccountTurns.provider_history/2`
replays *every completed run in the conversation* into the next request, with no
limit (`lib/openagents/chat/account_turns.ex:444`). A coder turn in one checkout
therefore becomes context for the next question you ask in the browser, and the
reverse. The two surfaces also contend for one slot: the partial unique index
`account_chat_runs_one_streaming_per_conversation` admits exactly one streaming
run per conversation, so the second `openagents coder` refuses with
`turn_in_progress`.

**One existing record already has the shape and no conversation.** `scv_runs`
carries no `conversation_id` at all, scopes by `driver_account_id`, holds
`driver_thread_id` and `driver_turn_id`, and owns an append-only event log in
`scv_run_events`. Nothing in production reaches it. The owner has ruled that it
cannot be the primary record, so this audit treats it as proof of shape and as
machinery worth borrowing, not as the answer.

**Recommended option: add a `threads` table beside `conversations`, and make
`inference_grants.conversation_id` nullable alongside a new nullable
`thread_id`.** It is additive. It touches no invariant's meaning: DATA-002 keeps
saying exactly what it says today, because a thread is not a conversation.
The one migration that is not purely additive is the grant column, and it is a
`DROP NOT NULL` with an added `CHECK` — the same shape as the migration that
already made `inference_grants.machine_id` nullable for coding jobs
(`priv/repo/migrations/20260819080000_allow_machineless_inference_grants.exs`).

**Smallest honest first slice: a `threads` table, a thread-scoped grant, and
`POST /api/v3/threads` behind `chat:account`.** That is enough for
`openagents coder` to stop writing into the conversation. The `/chat` surface
can keep its single conversation until threads have proven themselves.

---

## 1. What one-per-user actually is

### 1.1 Two unique indexes, not one

DATA-002 (`INVARIANTS.md:425`) says "Database uniqueness enforces one internal
storage owner per local user and one conversation per owner." That is two
indexes in one migration, `priv/repo/migrations/20260816214200_create_sarah_conversations.exs`:

```elixir
create unique_index(:visitors, [:browser_key_hash])
create unique_index(:visitors, [:user_id])          # line 13
...
create unique_index(:conversations, [:visitor_id])  # line 24
```

- `visitors_user_id_index` forbids a second visitor row for one `users` row.
- `conversations_visitor_id_index` forbids a second conversation for one
  visitor.

Composed, they forbid a second conversation per authenticated user. Neither
index mentions users and conversations together, so **there is no index named
"one conversation per user"** — the property is emergent from the pair. Relaxing
it means dropping one of them, and dropping either is a data-model change
rather than a policy edit.

A third constraint keeps browser rows and account rows from merging:
`visitors_identity_source_check` requires exactly one of `browser_key_hash` and
`user_id` to be set
(`priv/repo/migrations/20260820160000_reconcile_visitor_identity_constraint.exs:16`).

The proof is `test/openagents/accounts_test.exs:36`, "one account owns one
canonical conversation across browser sessions", which asserts that two calls
to `ensure_conversation/1` return the same id and that a second account gets a
different one.

### 1.2 The single resolver

`OpenAgents.Conversations.ensure_conversation/1` is the only constructor
(`lib/openagents/conversations.ex:36` for the account clause, `:44` for the
legacy browser-key clause). It inserts with
`on_conflict: :nothing, conflict_target: [:visitor_id]` and then reads the row
back, so a race produces one conversation and one greeting rather than two
(`lib/openagents/conversations.ex:1079`).

Every production caller in `lib/`:

| Caller | Line |
| --- | --- |
| `OpenAgents.Chat.AccountTurns.submit/3` | `lib/openagents/chat/account_turns.ex:32` |
| `OpenAgentsWeb.ChatLive.mount/3` | `lib/openagents_web/live/chat_live.ex:74` |
| `OpenAgentsWeb.ChatConsoleLive.mount/3` | `lib/openagents_web/live/chat_console_live.ex:82` |
| `OpenAgentsWeb.MemoryLive.mount/3` | `lib/openagents_web/live/memory_live.ex:31` |
| `OpenAgentsWeb.VoiceCallController` | `lib/openagents_web/controllers/voice_call_controller.ex:19`, `:78`, `:97` |
| `OpenAgentsWeb.ComputerAgentJobsController.create/2` | `lib/openagents_web/controllers/computer_agent_jobs_controller.ex:17` |
| `Mix.Tasks.Openagents.BackfillVisitors` | `lib/mix/tasks/openagents.backfill_visitors.ex:29` |

Seven entry points, one row. There is no path that takes a conversation
identifier from a client and creates something: `get_conversation_for_user/2`
(`lib/openagents/conversations.ex:87`) casts the UUID and joins through the
visitor, so a foreign id returns `nil` rather than another person's
conversation. That is IDENTITY-002 (`INVARIANTS.md:200`), and it stays true
under every option in section 6.

### 1.3 TURN-001 is about turns, and it has a namesake

TURN-001 (`INVARIANTS.md:739`) says at most one active turn per conversation,
where active is `queued` or `streaming`, and names its arbiter:

```elixir
create unique_index(:turns, [:conversation_id],
         where: "status IN ('queued', 'streaming')",
         name: :turns_one_active_per_conversation_index
       )
```

(`priv/repo/migrations/20260816214200_create_sarah_conversations.exs:74`).

**That index does not govern the `/chat` surface or the CLI.** The `turns` table
is written from exactly one place, `OpenAgentsWeb.ChatLive`
(`lib/openagents_web/live/chat_live.ex:425` calling
`Conversations.create_turn/2`), which serves `/sarah`
(`lib/openagents_web/router.ex:209`). No API route creates a `turns` row.

`/chat` and the CLI use a second, younger lane with its own near-identical
index:

```elixir
create unique_index(:account_chat_runs, [:conversation_id],
         where: "status = 'streaming'",
         name: :account_chat_runs_one_streaming_per_conversation
       )
```

(`priv/repo/migrations/20260822234211_create_account_chat_runs_and_events.exs:24`).

So `POST /api/v3/chat/turns` does not create a turn. It creates an
`account_chat_runs` row (`lib/openagents/chat/account_turns.ex:153`), and the
refusal you see when two coder sessions collide comes from that index, mapped to
`:turn_in_progress` at `lib/openagents/chat/account_turns.ex:177` and rendered
as HTTP `409` at
`lib/openagents_web/controllers/chat_turn_controller.ex:31`. The name is the
first thing to fix in any surface that says thread.

DATA-003 (`INVARIANTS.md:440`) bounds `Conversations.list_messages/2` and is
untouched by any option here, because it governs the `messages` table, which the
account chat lane does not write.

---

## 2. The coupling wall

### 2.1 Three tables refuse a null conversation

| Table | Migration | Column declaration |
| --- | --- | --- |
| `work_jobs` | `priv/repo/migrations/20260818003358_create_work_jobs.exs:8` | `references(:conversations, ...), null: false` |
| `inference_grants` | `priv/repo/migrations/20260818234500_create_inference_grants.exs:20` | `references(:conversations, ...), null: false` |
| `box_runs` | `priv/repo/migrations/20260823133243_create_box_runs.exs:8` | `references(:conversations, ...), null: false` |
| `conversation_boxes` | `priv/repo/migrations/20260823034851_create_conversation_boxes.exs:8` | `references(:conversations, ...), null: false` |
| `voice_sessions` | `priv/repo/migrations/20260816214735_create_voice_runtime.exs:8` | `references(:conversations, ...), null: false` |
| `account_chat_runs` | `priv/repo/migrations/20260822234211_create_account_chat_runs_and_events.exs:8` | `references(:conversations, ...), null: false` |

Two tables carry a **nullable** `conversation_id`:

- `forge_assignments`, added when assignments were generalized from a Box to a
  Computer:
  `add :conversation_id, references(:conversations, type: :binary_id, on_delete: :restrict)`
  (`priv/repo/migrations/20260823165145_generalize_assignments_for_computers.exs:11`),
  with no `null: false`.
- `repository_publications` and `pull_requests` carry a bare
  `:binary_id` conversation pointer with no foreign key
  (`priv/repo/migrations/20260823010819_create_repository_publications.exs:13`,
  `priv/repo/migrations/20260823021021_add_workspace_publication_to_pull_requests.exs:12`).

`work_jobs` goes further than a `NOT NULL`. A trigger function,
`enforce_work_job_scope`, refuses any row whose conversation does not belong to
its `owner_visitor_id`
(`priv/repo/migrations/20260820085203_harden_async_runtime_boundaries.exs:74`),
and `enforce_work_job_transition` makes `conversation_id` immutable after
insert (`priv/repo/migrations/20260818003358_create_work_jobs.exs:63`).

### 2.2 Model authority is the binding constraint

`OpenAgents.Inference` mints the only credential a coding agent can hold. The
plaintext exists once, at mint, and the provider key never leaves the server
(`lib/openagents/inference.ex:35`; RELEASE-002, `INVARIANTS.md:2131`). The proxy
that redeems it is `POST /api/inference/proxy`
(`lib/openagents_web/router.ex:391`), which authenticates a grant bearer and
pins the model from the grant so a request body cannot select another
(`lib/openagents_web/controllers/inference_proxy_controller.ex:40`).

The grant's `conversation_id` is `NOT NULL`, required in the changeset
(`lib/openagents/inference/grant.ex:63`), and frozen by a trigger that raises if
any update changes it
(`priv/repo/migrations/20260819080000_allow_machineless_inference_grants.exs:25`).

Three call sites mint, and every one is server-initiated:

| Site | Line | `machine_id` |
| --- | --- | --- |
| `OpenAgents.Work.Coding.on_start/1` | `lib/openagents/work/coding.ex:64` | `nil` (`:67`) |
| `OpenAgents.Work.Scv.on_start/1` | `lib/openagents/work/scv.ex:133` | `nil` (`:136`) |
| `OpenAgents.Work.DelegationServer` | `lib/openagents/work/delegation_server.ex:179` | the paired computer |

**The reported `machine_id: nil` is real, and it is precedent.** It exists
because a coding job has no paired machine, and the migration that permitted it
says so in its own moduledoc: "A coding job (#122) meters its own inference
usage into the same grant ledger as probe delegations, but it has no paired
machine"
(`priv/repo/migrations/20260819080000_allow_machineless_inference_grants.exs:3`).
That migration is the exact template a thread-scoped grant should follow: drop
one `NOT NULL`, and tighten the immutability trigger to be null-safe so the
column cannot be acquired later.

**"Generation-fenced by conversation" is a design intent, not a running
behavior.** `Inference.revoke_active_for_conversation/1`
(`lib/openagents/inference.ex:148`) exists and is documented as "generation
fence on a new turn/delegation", but **it has no caller in `lib/`**. Its only
reference outside its own module is
`test/openagents/inference_test.exs:124`. The fence today is therefore the
`conversation_id` column plus the immutability trigger, not an active
revocation sweep. Nothing caps concurrent active grants per account either:
`Inference.mint/1` inserts unconditionally, and the budgets are per-grant —
`inference_grant_max_calls: 64`, `inference_grant_max_total_tokens: 2_000_000`,
`inference_grant_ttl_seconds: 900` (`config/config.exs:262` to `:265`).

### 2.3 Why the CLI landed in the conversation

`packages/openagents-cli/src/coder-ox.ts` in the `openagents` monorepo declares
its two paths at lines 21 and 22:

```ts
const SUBMIT_PATH = "/api/v3/chat/turns";
const EVENTS_PATH = "/api/v3/chat/events";
```

Its header comment states the consequence plainly: "A coder session therefore
shares the account's conversation rather than opening its own" (line 12). That
was the only route that could reach a model with a user token, because
`POST /api/v3/coder/sessions` — the grant-minting route that
`docs/2026-08-23-openagents-coder-cli-spec.md` section 6.2 specifies — does not
exist. A grep of `lib/openagents_web/router.ex` for `coder` returns nothing.

`ChatTurnController.create/2` takes only `message` and `reasoning`
(`lib/openagents_web/controllers/chat_turn_controller.ex:12`). There is no
conversation parameter to pass, so the caller could not have chosen otherwise.

### 2.4 The three costs of sharing one conversation

1. **Shared provider context, unbounded.**
   `AccountTurns.provider_history/2` selects every `completed` run for the
   conversation, ordered, with no `limit`
   (`lib/openagents/chat/account_turns.ex:444`), and prepends it to the next
   request. Terminal coder work becomes browser context and the reverse, and
   the payload grows for the life of the account.
2. **One streaming slot.** The partial unique index means a second concurrent
   coder invocation, or a coder running while you type in `/chat`, is refused.
3. **Shared transcript.** `ChatConsoleLive.mount/3` renders
   `AccountTurns.list_messages/1` (`lib/openagents_web/live/chat_console_live.ex:83`),
   which reads the same `account_chat_runs` rows
   (`lib/openagents/chat/account_turns.ex:482`). Coder prompts are visible in
   the web console. `GET /api/v3/chat/events` is likewise unbounded
   (`lib/openagents/chat/account_turns.ex:472`), and the CLI polls it every
   250 ms (`packages/openagents-cli/src/coder-ox.ts:24`), so each poll
   re-downloads the account's entire event history.

A fourth cost is quieter: `account_chat_runs` and `account_chat_events` are
**not in the DATA-004 export**. `OpenAgents.DataRights.export/3` returns
messages, profile memory, voice sessions, and tool steps
(`lib/openagents/data_rights.ex:69`), and names no chat run. Deletion still
reaches them through the conversation cascade, but the export ledger does not.
Any thread record should be added to that export when it lands, or DATA-004
inherits the same gap.

---

## 3. What already exists that is thread-shaped

`scv_runs` is the only durable execution record in the repository with no
conversation. Its single migration is
`priv/repo/migrations/20260821082652_create_scv_runs.exs`; no later migration
alters it.

**What it scopes by.** `driver_account_id`, `null: false`, referencing
`scv_driver_accounts` with `on_delete: :restrict` (line 8). That account is
owned by a user: `operator_id`, `null: false`, referencing `users`
(`priv/repo/migrations/20260820161342_create_scv_codex_driver_accounts.exs:7`).
Ownership therefore reaches a person without passing through a conversation.

**What it already carries that a thread needs.**

| Column | Line | Why a thread wants it |
| --- | --- | --- |
| `driver_thread_id`, `driver_turn_id` | `:24`, `:25` | the executor's own identifiers, held opaquely |
| `objective` | `:16` | the bounded goal, capped at 32 KB by `:scv_runs_objective_bound_check` |
| `model`, `reasoning_effort`, `permission_profile` | `:18`, `:19`, `:17` | the admitted execution shape, each with a check constraint |
| `status` | `:20` | `running`, `succeeded`, `failed`, `cancelled`, `uncertain` |
| `owner_node`, `generation`, `lease_expires_at` | `:21`, `:22`, `:23` | the cluster fence that survives a node moving |
| `report`, `report_digest` | `:26`, `:27` | the terminal receipt, digest-verified |
| `event_count`, `usage`, `resources` | `:28`, `:29`, `:30` | metering without reading the transcript |
| `repository_revision` | `:15` | pinned to an exact 40-hex commit by `:scv_runs_repository_revision_check` |

**What enforces one at a time.**

```elixir
create unique_index(:scv_runs, [:driver_account_id],
         where: "status = 'running'",
         name: :scv_runs_one_active_account_index
       )
```

(line 41), plus `unique_index(:scv_runs, [:driver_account_id, :generation])`
(line 46) as the monotonic fence.

**Its event log.** `scv_run_events` (line 74) is append-only —
`timestamps(type: :utc_datetime_usec, updated_at: false)` — with
`run_id` cascading on delete, a pinned `schema` string enforced by
`:scv_run_events_schema_check` (`schema = 'openagents.scv.event.v1'`, line 85),
and a 16 KB payload ceiling (line 89).

**Its model authority is its own.** An `scv_runs` execution authenticates as a
managed ChatGPT account through `OpenAgents.SCV.Executor.CodexAppServer`, not
through an inference grant. This is the existence proof that model authority
without a conversation is already reachable in this codebase — through a
different credential family.

**Nothing reaches it.** `OpenAgents.SCV.CodexRuns.start/5`
(`lib/openagents/scv/codex_runs.ex:13`) is the only wrapper over
`Executions.claim/4`, and

```sh
rg -n 'CodexRuns' lib/ | grep -v 'lib/openagents/scv/'
```

returns nothing. Its only callers are `test/openagents/scv/codex_runs_test.exs`.
The lane is also feature-flagged off by default (`config/config.exs:62`).
`scv_runs.issue_id` (line 12) is nullable, indexed, cast at
`lib/openagents/scv/execution.ex:54`, and set by no caller at all — issue #152
is open against exactly that, and this audit confirms it.

**What a `threads` table should borrow.** The generation fence, the lease, the
`owner_node` column, the terminal report plus digest, the bounded-objective
check constraint, the partial unique index on live status, and the pinned event
schema with a payload ceiling. What it should not borrow is the coupling to a
driver account: a thread's owner is the account, and its executor is a
property, not its identity.

**Two names to keep straight.** `scv_runs` is the Codex app-server lane. A
`work_jobs` row of kind `scv` is a different system with the same word,
admitted by `OpenAgents.SCV.Deployments.start/2`, conversation-bound, and
operator-only under SCV-001 (`INVARIANTS.md:1301`). `docs/taxonomy.md` already
warns about this; the audit repeats it because the two records answer the
coupling question in opposite directions.

---

## 4. Every other candidate

### 4.1 `work_jobs`

One table, five kinds — `deep_work`, `delegation`, `coding`, `scv`,
`continual_learning` — validated in Elixir only
(`lib/openagents/work/job.ex:18`), with **no database check constraint on
`kind`**. Adding a sixth kind is a one-line change with no migration.

- **Scoped by** conversation and owner, both `null: false`, both immutable, and
  cross-checked by the `enforce_work_job_scope` trigger described in 2.1.
- **Transcript.** `work_job_steps` is a real ordered tool-step log with digests,
  a lifecycle-shape check constraint, and an immutability trigger
  (`priv/repo/migrations/20260818003358_create_work_jobs.exs:107`). It records
  tool calls, not assistant prose. Prose accumulates in one `report` column,
  which a check constraint requires to be non-empty on every terminal status
  (line 53).
- **Concurrent siblings.** Yes. There is no partial unique index on
  `work_jobs`; concurrency is bounded by budget, not by row uniqueness.
- **Lifecycle.** `queued`, `running`, `completed`, `failed`, `interrupted`,
  `budget_exhausted`, plus `cancelled` added later. Transitions are enforced by
  the `enforce_work_job_transition` trigger, and terminal rows are immutable.

**The disqualifier.** `Work.finish_job/3` inserts an assistant `Message` into
the job's conversation on **every** terminal path, inside the same transaction
that writes the terminal row (`lib/openagents/work.ex:527`). WORK-001 states
this as a contract: "On terminal state the bounded report becomes a durable
assistant conversation message linked to the job" (`INVARIANTS.md:1217`). A
work job cannot host a thread without writing into the conversation, which is
the behavior this audit exists to stop.

### 4.2 `computer_agent_jobs`

**There is no such table.** `OpenAgents.ComputerAgentJobs` is a context module
that builds a `work_jobs` row of kind `delegation`
(`lib/openagents/computer_agent_jobs.ex:1`). Its HTTP entry point calls
`Conversations.ensure_conversation(user)` directly
(`lib/openagents_web/controllers/computer_agent_jobs_controller.ex:17`), so it
converges on the canonical conversation like everything else. The
`work_jobs_delegation_identity` check constraint additionally requires
`machine_id IS NOT NULL` for this kind
(`priv/repo/migrations/20260820085203_harden_async_runtime_boundaries.exs:68`),
so it cannot host a machine-less local session.

### 4.3 `forge_assignments`

- **Scoped by** issue and repository, both `null: false`, `on_delete: :restrict`
  (`priv/repo/migrations/20260823141005_create_box_assignments_and_scoped_credentials.exs:11`,
  `:14`). Its `conversation_id` is **nullable** (2.1), and its `target_kind` is
  `box` or `computer`.
- **Transcript.** None of its own. It points at the substrate that has one:
  `run_id` to `box_runs`, and `work_job_id`, added by
  `priv/repo/migrations/20260823180051_link_forge_assignments_to_work_jobs.exs:13`.
- **Concurrent siblings.** Constrained hard: `forge_assignments_one_active_issue_index`,
  `forge_assignments_one_active_box_index`, and
  `forge_assignments_one_active_machine_index` each admit one live row per
  issue, per box, and per computer.
- **Lifecycle.** `admitted`, `running`, `completed`, `failed`, `cancelled`.

It is the right record for "who is working this issue", and the wrong one for
"what did the agent and I say to each other". It is issue-shaped, and a thread
does not require an issue.

### 4.4 `box_runs` and `conversation_boxes`

`box_runs` is one shell command and its output, not an agent exchange. Its
`conversation_id` is `NOT NULL`, its `conversation_box_id` is `NOT NULL`
(`priv/repo/migrations/20260823133243_create_box_runs.exs:8`, `:12`), and
`box_runs_one_active_per_box_index` admits one live run per Box.
There is no `box_run_events` table: the transcript is a single mutable `output`
column bounded to a 24 KB tail
(`lib/openagents/tools/box_output.ex`), so earlier output is overwritten rather
than retained. `conversation_boxes` is the Box ledger, also conversation-bound
and `NOT NULL`.

Concurrency for a person is capped at four active Boxes by
`maximum_active_boxes_per_owner` (`config/config.exs:112`), with a
per-conversation cap of two (`:111`) and a global cap of twenty (`:113`).

### 4.5 Voice sessions

`voice_sessions.conversation_id` is `NOT NULL`
(`priv/repo/migrations/20260816214735_create_voice_runtime.exs:8`), with
`voice_sessions_one_active_per_conversation_index` admitting one live
generation and `unique_index(:voice_sessions, [:conversation_id, :generation])`
providing the fence (lines 34–38). Its transcript projects into `messages`
(VOICE-009, `INVARIANTS.md:1748`). This is the closest existing analogue to a
correctly built generation fence, and it is the strongest argument for keeping
the word "session" reserved for transport: this record already owns it.

### 4.6 `continual_learning_jobs`

No `conversation_id`. Scoped by `buyer_ref` and `buyer_class` as text, with an
optional `work_job_id` pointing at the conversation-bound job that drives it
(`priv/repo/migrations/20260823074000_create_continual_learning_jobs.exs:28`).
Its durable children are `continual_learning_checkpoints`,
`continual_learning_artifacts`, and `continual_learning_receipts`. It is a
training job, not an interaction; it has no turns.

### 4.7 `shadow_program_runs`

Bound to `turn_receipt_id`, `null: false`
(`priv/repo/migrations/20260816230000_create_shadow_program_runs.exs:8`). It is
a candidate-versus-baseline comparison artifact under PROGRAM-002
(`INVARIANTS.md:135`), with no live effect. Not a session of any kind.

### 4.8 `stack_check_runs`

Scoped by `repository_id`, `stack_id`, and `pull_request_id`, all `null: false`
(`priv/repo/migrations/20260823122038_create_stack_check_runs.exs:8`). It is
continuous integration for a pull-request stack. No transcript, no turns.

### 4.9 `OpenAgents.Cluster.Sessions`

Worth naming because of the word: this is a facade over a Raft registry that
publishes "who owns this session" for the Work servers
(`lib/openagents/cluster/sessions.ex:1`). It is in-flight state only, and it
returns `{:ok, :local}` when the cluster is not formed. It stores nothing
durable and is not a candidate.

### 4.10 The inventory in one table

| Record | Scoped by | `conversation_id` | Nullable | Own event log | Concurrent siblings |
| --- | --- | --- | --- | --- | --- |
| `turns` | conversation | yes | no | `turn_tool_steps`, `turn_provider_steps` | no — `turns_one_active_per_conversation_index` |
| `account_chat_runs` | conversation | yes | no | `account_chat_events` | no — one `streaming` per conversation |
| `work_jobs` | conversation + owner | yes | no | `work_job_steps` | yes |
| `box_runs` | conversation + box | yes | no | no — one `output` column | one per Box |
| `conversation_boxes` | conversation | yes | no | `box_reconciliation_events` | 2 per conversation, 4 per owner |
| `voice_sessions` | conversation | yes | no | `voice_events`, `voice_transcript_items` | no — one live generation |
| `forge_assignments` | issue + repository | yes | **yes** | no — points at substrate | one per issue, box, or computer |
| `scv_runs` | driver account | **no** | — | `scv_run_events` | one per driver account |
| `continual_learning_jobs` | buyer ref | **no** | — | checkpoints, receipts | yes |
| `shadow_program_runs` | turn receipt | **no** | — | no | yes |
| `stack_check_runs` | repository + stack + pull request | **no** | — | no | yes |

Read the third and fourth columns together: **every record that can hold an
agent exchange today requires a conversation, and the one record that does not
holds no exchange the product can reach.**

---

## 5. The two surfaces

### 5.1 The web `/chat` surface

`/chat` is `OpenAgentsWeb.ChatConsoleLive` (`lib/openagents_web/router.ex:263`),
which is distinct from `/sarah`, the `OpenAgentsWeb.ChatLive` surface at
`lib/openagents_web/router.ex:209`. They share a conversation row and share
nothing else: `/sarah` writes `turns` and `messages`; `/chat` writes
`account_chat_runs` and `account_chat_events` and never touches `messages`.

To let a person hold several threads in `/chat`, four things change.

1. **`ChatConsoleLive` gains a thread in its assigns.** `mount/3` currently
   resolves the conversation and immediately loads every message for it
   (`lib/openagents_web/live/chat_console_live.ex:82`). It would resolve or
   create a thread instead, and `handle_params/3` would carry a thread id.
2. **`AccountTurns` changes its scope key.** Six functions take a `%User{}` and
   resolve the conversation internally — `submit/3` (`:25`), `cancel/1`
   (`:56`), `list_events/1` (`:78`), `list_messages/1` (`:85`), `active?/1`
   (`:92`), and the private `provider_history/2` (`:444`). Each would take a
   thread. `provider_history/2` also needs a bound while it is being touched;
   its absence today is a live defect independent of threads.
3. **The `chat:account` API gains thread-addressed routes.**
   `GET /api/v3/chat/events` and `POST /api/v3/chat/turns` are registered in
   `lib/openagents_web/router.ex:523` and `:524` and classified in
   `lib/openagents_web/api_route_authority.ex:184`. Adding routes there is
   cheap but not free: FORGEAPI-001 (`INVARIANTS.md:2977`) makes
   `OpenAgentsWeb.ApiRouteAuthority` mandatory, so a route without a principal,
   a family, and an error contract fails CI. `lib/openagents_web/route_authority.ex:520`
   also carries a per-path policy for `/api/v3/chat/turns` that a new path
   needs a sibling of.
4. **UI-001 needs a decision, not an edit.** UI-001 (`INVARIANTS.md:1946`) says
   the interface "contains no conversation list" and that the sidebar "may never
   list or switch conversations." A thread list is not a conversation list, and
   the distinction is exactly what the taxonomy change establishes. Still, the
   invariant text should say so explicitly before a thread switcher ships, or
   the next reader will read the switcher as a violation.

**Does Sarah's conversation become thread zero?** The evidence says no, and the
cost of saying yes is high. The conversation is load-bearing for five memory
planes: MEMORY-001 binds recall to "one canonical conversation resolved from the
authenticated local user" (`INVARIANTS.md:452`), and profile memory, preferences,
experience memory, and graph memory all cascade from the visitor root through
it (DATA-004, `INVARIANTS.md:1903`). Folding it into a thread table means every
one of those planes needs a new scope predicate, and MEMORY-004 makes those
predicates database-level (`INVARIANTS.md:509`). Keeping the conversation as a
distinct thing beside threads costs one nullable pointer if a thread ever wants
to cite it.

The honest framing is the one the taxonomy now uses: a conversation is a
persistent relationship with one persona; a thread is a bounded piece of work.
They are different records because they have different lifetimes.

### 5.2 The `openagents coder` CLI

What it does today, at `56eaa4243210`:

- `openagents coder` is wired in `packages/openagents-cli/src/cli.ts:1135`, with
  `--plain`, `--offline`, and `--reasoning` flags.
- Its reply source is `OxAlphaReplySource` in
  `packages/openagents-cli/src/coder-ox.ts`, which posts to
  `/api/v3/chat/turns` (line 21) and polls `/api/v3/chat/events` (line 22)
  every 250 ms (line 24), giving up after 300 seconds (line 26).
- It terminates on the two event kinds the server writes,
  `response_completed` and `response_failed`
  (`lib/openagents/chat/account_turns.ex:379`, `:391`).
- Authentication is `resolveApiSession` in
  `packages/openagents-cli/src/session.ts`, the same call every other command
  makes, so the token is whatever `openagents auth login` stored. The scope it
  needs is `chat:account`, admitted by the check constraint at
  `priv/repo/migrations/20260823000143_allow_chat_account_api_token_scope.exs:8`.

What it needs to hold a thread:

1. **A route that mints a thread-scoped grant to a user token.** This is the
   single blocking item, and `docs/2026-08-23-openagents-coder-cli-spec.md`
   section 6.2 already specifies its shape. Everything else the CLI needs
   already exists: `POST /api/inference/proxy` accepts a grant bearer, and the
   `probe` runtime already reads `PROBE_INFERENCE_GRANT` and
   `PROBE_INFERENCE_URL` from its environment.
2. **A thread identifier in the local transcript.** The CLI writes its own
   append-only JSON Lines file for `--resume`; that file keys on a thread id
   rather than on nothing.
3. **Nothing else.** In particular the CLI should stop calling
   `/api/v3/chat/turns` entirely rather than gaining a thread parameter there.
   That route serves Sarah's conversation, and it should keep serving only that.

The spec document is worth reading against this audit, because it reached the
same conclusion from the client side and stated it as a rule: "Do not create a
second work record" and "a coder turn is not a durable server record"
(`docs/2026-08-23-openagents-coder-cli-spec.md`, section 4.3). This audit
disagrees on one point, and the disagreement is the reason it exists. The spec
proposed anchoring a coder session on an `inference_grants` row, on the grounds
that the grant already carries owner, model, budget, call count, usage, and
terminal status. That works only while the grant is fenced by the account's one
conversation — which is precisely the coupling that put coder prompts in the
browser. A grant is a budget, not a transcript, and it expires in 15 minutes by
default. A thread outlives its grants.

---

## 6. The options, with true cost

### 6.1 Relax DATA-002 to allow several conversations per user

**Migration.** Drop `conversations_visitor_id_index`. Existing rows survive
untouched, so the data migration is empty.

**What breaks.** More than the index.

- `Conversations.get_conversation_for_user/1` (`lib/openagents/conversations.ex:77`)
  calls `Repo.one/1` on a query that would now return several rows, and raises
  when it does. Ten call sites use the arity-1 form and each becomes ambiguous:
  `lib/openagents/staging_cleanup.ex:369`, `lib/openagents/box/fleet.ex:79`,
  `lib/openagents/chat/account_turns.ex:57`, `:79`, `:86`, `:93`,
  `lib/openagents_web/controllers/data_controller.ex:88`,
  `lib/openagents_web/controllers/voice_telemetry_controller.ex:11`,
  `lib/openagents_web/controllers/voice_recording_controller.ex:70`, and
  `lib/openagents_web/controllers/memory_export_controller.ex:9`.
- `ensure_conversation/1` loses its meaning. Its `on_conflict` clause targets
  `[:visitor_id]` (`lib/openagents/conversations.ex:1079`), which is the index
  being dropped.
- DATA-004's export and delete take one conversation as an argument
  (`lib/openagents/data_rights.ex:42`) and would need to iterate.
- MEMORY-001 is stated as "recall is confined to the current account
  conversation" and would have to define which one.
- UI-001 forbids a conversation list outright.

**Invariants touched.** DATA-002 (rewritten), MEMORY-001 (rescoped), UI-001
(rewritten), DATA-004 (rescoped), IDENTITY-003 (which says one user "resolves
the same canonical OpenAgents owner"). Proofs that change:
`test/openagents/accounts_test.exs`, `test/openagents/conversations_test.exs`,
`test/openagents/memory/lexical_recall_test.exs`, and
`test/openagents_web/controllers/data_controller_test.exs`.

**Verdict: breaking, and it buys the wrong thing.** It makes Sarah plural, which
nobody asked for, and it still leaves a coder session indistinguishable from a
chat.

### 6.2 Add a `threads` table beside conversations — recommended

**Migration.** One additive `create table(:threads, ...)`, one additive
`create table(:thread_events, ...)`, and one `ALTER TABLE inference_grants
ALTER COLUMN conversation_id DROP NOT NULL` with an added nullable `thread_id`
and a `CHECK` requiring exactly one of the two. Existing grant rows already
satisfy that check, so the data migration is empty. The immutability trigger
gains `IS DISTINCT FROM` for both columns, copying
`priv/repo/migrations/20260819080000_allow_machineless_inference_grants.exs`
verbatim in shape.

**What it owns.** Owner (the visitor root, so DATA-004 cascade works without a
new rule), title or objective, status, the generation and lease fence borrowed
from `scv_runs`, budget snapshot, usage, terminal report and digest, and a
partial unique index admitting one live turn per thread — the TURN-001 pattern,
applied per thread instead of per conversation.

**What it reuses.** The `Inference` grant machinery and the proxy, unchanged
except for the fence column. The `api_tokens` scope ladder, unchanged:
`chat:account` already exists. The `work_jobs` delegation path, unchanged, if a
thread delegates. `OpenAgents.Transparency` tiers, once issue #149 adds the
artifact type. The `probe` runtime contract, unchanged.

**Invariants touched.** All additive:

- A new `THREAD-001` stating what a thread is, what bounds it, and what
  enforces one live turn per thread. DATA-002 gains one sentence saying a
  thread is not a conversation.
- `PROVENANCE-001` and `TURN-002` are untouched, because a thread turn is not a
  `turns` row.
- `FORGEAPI-001` requires the new routes in `OpenAgentsWeb.ApiRouteAuthority`;
  that is a build gate, not a redesign.
- `DATA-004` needs the new tables in the export and in the cascade proof.
- `UI-001` needs one clarifying sentence before a thread switcher ships.

**Verdict: additive, and it is the only option that makes the word mean
something.**

### 6.3 Reuse an existing record

**A new `work_jobs` kind.** Cheapest on paper: `kind` has no database
constraint, so a `thread` kind is a one-line change to
`lib/openagents/work/job.ex:18`. It fails on three counts. The conversation is
`NOT NULL`, immutable, and trigger-checked against the owner. Every terminal
job writes an assistant message into that conversation
(`lib/openagents/work.ex:527`), which is the exact defect. And `work_job_steps`
records tool calls with digests, not an interactive exchange — there is no
place for a user prompt after the first.

**`scv_runs`.** It has the right shape and the owner has ruled it out as the
primary record. The ruling is well founded independently: it is scoped by a
Codex driver account rather than by a person, its `permission_profile` is
constrained to `read_only` in the database
(`priv/repo/migrations/20260821082652_create_scv_runs.exs:50`), its `driver` is
constrained to `codex_app_server` (line 48), and its event payloads are
scrubbed of text by design. Widening any of those is a bigger migration than
creating a table.

**`forge_assignments`.** Requires an issue (`null: false`) and admits one live
assignment per issue. A thread that must name an issue is not a thread.

**Verdict: none of them.** The closest, `scv_runs`, is closest because it was
built for the same shape — which is the argument for borrowing its columns, not
its table.

---

## 7. A staged path

Each stage names its repository, its seam, and what is true when it is done.

### Stage 1 — The `threads` table and a thread-scoped grant (this repository, medium)

**Seam:** `priv/repo/migrations`, a new `OpenAgents.Threads` context, and
`lib/openagents/inference.ex`.

Create `threads` and `thread_events`. Make `inference_grants.conversation_id`
nullable, add `thread_id`, and add the check requiring exactly one. Teach
`Inference.mint/1` to accept either fence. Add `THREAD-001` with its proof.

**Done when** a thread row exists, a grant can be minted against it, and
`mix precommit` is green with no change to any existing invariant's meaning.

### Stage 2 — `POST /api/v3/threads` behind `chat:account` (this repository, small)

**Seam:** `lib/openagents_web/router.ex`,
`lib/openagents_web/api_route_authority.ex`,
`lib/openagents_web/route_authority.ex`.

Three routes: create a thread and return its grant; read its status and metered
usage; revoke it. This is where the abuse controls live, and it must not be a
thin wrapper. It needs a cap on concurrent active grants per account, which
does not exist today (2.2), ceilings independent of the delegation ceilings, and
revocation on delete and on expiry.

**Done when** a user token can obtain model authority that names no
conversation, and `OpenAgentsWeb.ApiRouteAuthorityTest` passes with the new
entries.

### Stage 3 — `openagents coder` stops writing to the conversation (`openagents` monorepo, small)

**Seam:** `packages/openagents-cli/src/coder-ox.ts`, replaced by a grant-backed
source.

Exchange the token for a thread and a grant, spawn the runtime with
`PROBE_INFERENCE_GRANT` and `PROBE_INFERENCE_URL`, and delete the two chat
paths. Key the local transcript on the thread id.

**Done when** running `openagents coder` twice in two checkouts works, and
neither prompt appears in `/chat`.

### Stage 4 — Chunked delivery from the inference proxy (both repositories, small)

**Seam:** `lib/openagents_web/controllers/inference_proxy_controller.ex`, and
the matching transport in `probe`.

The proxy builds the whole SSE body and sends it once. Sending each event as the
provider produces it is additive and changes no contract.

**Done when** the terminal shows tokens as they arrive rather than in one
block.

### Stage 5 — Threads in `/chat` (this repository, medium)

**Seam:** `lib/openagents_web/live/chat_console_live.ex`,
`lib/openagents/chat/account_turns.ex`.

Rescope `AccountTurns` from conversation to thread, bound `provider_history/2`,
and add a thread list to the console. Amend UI-001 first.

**Done when** a person holds several threads in the browser, each with its own
context, and Sarah's conversation is unchanged.

### Stage 6 — Threads in the export and under transparency tiers (this repository, medium)

**Seam:** `lib/openagents/data_rights.ex`, `lib/openagents/transparency.ex`.

Add threads and thread events to the DATA-004 export, and add a `thread`
artifact type once issue #149 lands. Close the gap in 2.4 for
`account_chat_runs` at the same time.

**Done when** the export ledger matches the surface in both directions for
threads, as EXIT-001 requires for repositories.

---

## 8. Open questions

- **How many `thread/` methods does the Codex protocol actually name?** The
  taxonomy claims 131 under `thread` and zero under `session`. Measured against
  the `openai/codex` clone at `bf2aee99c5`, the v2 schema
  `codex-rs/app-server-protocol/schema/json/codex_app_server_protocol.v2.schemas.json`
  contains **45** distinct `thread/*` strings and **zero** `session/*`; a
  repository-wide scan finds 69 distinct `thread/*` and 7 distinct `session/*`,
  and the seven are shell-session names — `session/open`, `session/execute`,
  `session/wait`, `session/terminate`, `session/shutdown`, `session/ready`,
  `session/closed` — not conversation names. The direction of the claim holds
  and the count does not. Settle it by running
  `rg -o '"thread/[A-Za-z/]+"' | sort -u | wc -l` against the pinned clone and
  correcting the number in `docs/taxonomy.md`, or by citing the method that
  produced 131.
- **Does any account in production already have more than one conversation?**
  The index forbids it, but a pre-index row could exist. Settle it with
  `SELECT visitor_id, count(*) FROM conversations GROUP BY 1 HAVING count(*) > 1`
  against production.
- **Should a thread be able to cite a conversation?** A coder thread that
  answers "as we discussed in chat" needs a pointer; a thread that never does
  needs none. Settle it by deciding whether recall (MEMORY-001) may read across
  the boundary, which is a policy decision, not a schema one.
- **Which record does a nested thread hang from?** `docs/taxonomy.md` reserves
  the term. A parent thread id on `threads` is the obvious answer, and it
  interacts with the delegation-depth rule in WORK-001, which caps depth at one.
  Settle it by reading WORK-001 against the nested-thread definition before
  stage 1 writes the table.
- **What caps concurrent threads per account?** Nothing caps concurrent grants
  today (2.2), and `work_jobs` has no concurrency index. The Box lane's
  per-owner cap of four is the only precedent. Settle it by choosing a number
  in `config/config.exs` before stage 2 exposes the route.
- **Does `scv_runs` become an executor behind a thread, or does it go?** Issue
  #152 asks the narrower version of this about `scv_runs.issue_id`. If a thread
  can name an executor, the Codex lane becomes one and the column question
  answers itself. Settle it with #152 before stage 1.
- **Which invariant identifier does a thread take?** `THREAD-001` is free.
  Confirm with `grep -n "^### THREAD" INVARIANTS.md`, which returns nothing
  today.
