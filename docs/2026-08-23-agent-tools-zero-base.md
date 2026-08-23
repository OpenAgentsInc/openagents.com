# Agent tools: what we had, and the zero base

**Date:** 2026-08-23
**Commit measured:** `7b980b2589ce` on `openagents/main`, the forge
**Status:** The cut in section 5 shipped with this document. Sections 1 to 4 are the historical record of the 37-tool catalog it replaced.
**Question:** Why does asking the agent to list its tools produce a wall of modules that mostly refuse, what did each of those tools actually do, and what has to be true before any of them comes back?
**Method:** direct reading of the `:tools` list in `config/config.exs`, all 37 registered modules under `lib/openagents/tools/`, the eight context resolvers they share, every `ExecutionContext` construction site in `lib/`, `OpenAgents.Tools.Registry`, `OpenAgents.Tools.Selector`, `OpenAgents.Tools.AdmittedCatalog`, `OpenAgents.Tools.Runner`, `OpenAgents.Modules.SurfacePolicy`, `INVARIANTS.md`, and the tests that read the installed catalog. Prompt-budget figures in section 8 come from building the real registry and measuring the encoded provider definitions; the script and its output are described there. Claims this repository cannot settle are in section 10.

---

## 0. Summary

The catalog held **37 tool modules** in one flat list at `config/config.exs:176`,
installed at boot by `lib/openagents/application.ex:41` and gated only by the
`:tools` feature flag. It is now **6**.

Three findings drove the size of the cut, and each is stronger than "too many
tools".

1. **Most of the catalog could not execute for the caller who complained.**
   `lib/openagents/chat/account_turns.ex:273` passes `owner_visitor_id: user.id`
   — a `User` id where a `Visitor` id belongs. `OpenAgents.Tools.OwnerContext.resolve/1`
   does `Repo.get(Visitor, visitor_id)` with it (`lib/openagents/tools/owner_context.ex:12`),
   finds nothing, and returns `:owner_not_signed_in`. That one line refuses the
   five computer tools, `incident_lookup`, `scv_deploy`, both GitHub tools, and
   every memory tool for the `/chat` console, the JSON turn API, and anything
   built on them. This is issue #156 and another lane owns the fix. It is not
   fixed here.
2. **Five registered tools could not execute for *any* caller.** `read`,
   `write`, `edit`, `bash`, and `publish_changes` resolve through
   `OpenAgents.Tools.WorkspaceFiles`, which admits only workspaces of type
   `repository_workspace` or `computer_workspace`
   (`lib/openagents/tools/workspace_files.ex:6`). **No production code
   constructs either type.** The only workspace any caller supplies is the
   placeholder `connected_forge_repository` map at
   `lib/openagents/tools/conversation_execution_context.ex:77`, which fails
   that check. The four files that build a real workspace are all tests. A
   sixth tool, `open_pull_request`, consumes a publication receipt that only
   `publish_changes` can mint, so it was unreachable by construction.
3. **A seventh tool required an authority nobody granted.** `code_check`
   requires `code.execute` (`lib/openagents/tools/code_check.ex:38`). The
   conversation authority set does not contain it
   (`lib/openagents/tools/conversation_execution_context.ex:18`); only a
   *coding* work job does, through `OpenAgents.Work.Coding.authorities/0`
   (`lib/openagents/work/coding.ex:33`). On every chat surface it was offered
   and always refused with `:authority_refused`.

So of 37 registered tools, **7 could not run anywhere a person types**, and a
further **11 could not run for the caller who filed the complaint**. The wall
was not a policy. It was an inventory that nothing kept honest.

The zero base is **6 read-only tools** (section 5). Everything else stays in
`lib/openagents/tools/` and stays under test through the broader fixture
catalog in `config/test.exs`. Nothing is deleted. Re-admission runs through
the criteria in section 6, and `test/openagents/tools/shipped_catalog_test.exs`
enforces the mechanical half of them, so the next addition is a policy change
rather than a one-line edit.

---

## 1. What we had

All 37 modules, in the order the config listed them, grouped by what they did.
`Bytes` is the encoded provider definition — name, description, and input
schema — measured in section 8. `Authority` is the tool's `required_authority`,
the string `OpenAgents.Tools.Runner` checks against the caller's authority set
at `lib/openagents/tools/runner.ex:158`.

### 1.1 Discovery — 1 tool

| Tool | Module | Effect | Authority | Bytes |
| --- | --- | --- | --- | --- |
| `module_discover` | `ModuleDiscover` | read-only | `module.discover` | 931 |

Searches the captured registry by relevance or tags without granting
execution. It needs nothing from the caller but the snapshot the turn already
holds, so it is the one tool that never refuses.

### 1.2 GitHub — 2 tools

| Tool | Module | Effect | Authority | Bytes |
| --- | --- | --- | --- | --- |
| `github_repo_list` | `GitHubRepoList` | read-only | `github.read` | 423 |
| `github_repo_read` | `GitHubRepoRead` | read-only | `github.read` | 543 |

List the signed-in person's GitHub repositories, and read a file or directory
inside one. Both resolve the person's delegated GitHub token through
`OpenAgents.Tools.GitHubContext`, which keys off `owner_visitor_id`
(`lib/openagents/tools/github_context.ex:11`). The token never reaches the
browser.

### 1.3 Forge repositories — 2 tools

| Tool | Module | Effect | Authority | Bytes |
| --- | --- | --- | --- | --- |
| `read_repository_file` | `ConnectedRepositoryRead` | read-only | `repository.read` | 553 |
| `list_repository_directory` | `ConnectedRepositoryList` | read-only | `repository.read` | 484 |

Read a text file and list a directory in a forge repository the signed-in
person can see. Alone among the owner-scoped families these resolve through
`owner_user_id` rather than `owner_visitor_id`
(`lib/openagents/tools/connected_repository.ex:25`), which is why they survived
the cut.

### 1.4 Agent workspace — 5 tools

| Tool | Module | Effect | Authority | Bytes |
| --- | --- | --- | --- | --- |
| `read` | `WorkspaceRead` | read-only | `repository.read` | 405 |
| `write` | `WorkspaceWrite` | reversible write | `repository.write` | 295 |
| `edit` | `WorkspaceEdit` | reversible write | `repository.write` | 645 |
| `bash` | `WorkspaceBash` | reversible write | `command.execute` | 360 |
| `publish_changes` | `PublishChanges` | external effect | `repository.write` | 435 |

A bounded file and shell surface over an assigned agent workspace, with
`publish_changes` committing that workspace to the run's forge branch. All
five are dead code from the product's point of view: see summary finding 2.

### 1.5 Pull requests — 1 tool

| Tool | Module | Effect | Authority | Bytes |
| --- | --- | --- | --- | --- |
| `open_pull_request` | `OpenPullRequest` | external effect | `pull_request.write` | 601 |

Opens or refreshes a draft pull request from an accepted publication receipt.
Since no caller can produce that receipt, it was unreachable.

### 1.6 Conversation recall — 2 tools

| Tool | Module | Effect | Authority | Bytes |
| --- | --- | --- | --- | --- |
| `conversation_search` | `ConversationSearch` | read-only | `conversation.read` | 505 |
| `conversation_read` | `ConversationRead` | read-only | `conversation.read` | 459 |

Find and then read exact bounded context from the current conversation,
including durable tool steps. Both resolve through
`OpenAgents.Tools.RecallContext`, which requires `memory_snapshot_ref`
(`lib/openagents/tools/recall_context.ex:13`).

### 1.7 Profile memory — 5 tools

| Tool | Module | Effect | Authority | Bytes |
| --- | --- | --- | --- | --- |
| `memory_list` | `MemoryList` | read-only | `memory.read` | 441 |
| `memory_search` | `MemorySearch` | read-only | `memory.read` | 506 |
| `memory_remember` | `MemoryRemember` | reversible write | `memory.write` | 714 |
| `memory_correct` | `MemoryCorrect` | reversible write | `memory.write` | 691 |
| `memory_forget` | `MemoryForget` | reversible write | `memory.write` | 838 |

List, search, store, correct, and forget durable profile facts, each under the
consent and generation gates in the MEMORY invariants. All five resolve
through `OpenAgents.Tools.MemoryContext`, the strictest resolver in the tree:
it wants a valid `owner_visitor_id`, `conversation_id`, **and**
`current_user_message_id`, plus a loadable profile snapshot
(`lib/openagents/tools/memory_context.ex:11`).

`memory_remember`'s description instructs the model to "call this automatically
whenever the user shares durable information; no explicit request to remember
is needed" (`lib/openagents/tools/memory_remember.ex:16`). On a surface where
its resolver fails, that is an instruction to refuse on most turns. It is the
single largest contributor to the wall the owner saw.

### 1.8 Paired computers — 5 tools

| Tool | Module | Effect | Authority | Bytes |
| --- | --- | --- | --- | --- |
| `computer_list` | `ComputerList` | read-only | `computer.control` | 325 |
| `computer_probe` | `ComputerProbe` | read-only | `computer.control` | 572 |
| `computer_run` | `ComputerRun` | external effect | `computer.control` | 798 |
| `computer_devin` | `ComputerDevin` | external effect | `computer.control` | 986 |
| `computer_agent` | `ComputerAgent` | external effect | `computer.control` | 1,360 |

List paired computers, discover what is installed on one, run one command, and
delegate a coding task over the Agent Client Protocol. `computer_devin` is
already marked deprecated in its own description in favour of `computer_agent`
with `agent_id: "devin"` (`lib/openagents/tools/computer_devin.ex:35`), and was
still registered. All five resolve through `OwnerContext`, and the three
external-effect ones additionally need a machine approval receipt bound to the
exact module, version, and scope (`lib/openagents/modules/surface_policy.ex:108`).

`computer_agent` carried the largest definition in the catalog at 1,360 bytes,
6.4 percent of the whole prompt budget for tools.

### 1.9 Delegated work and incidents — 2 tools

| Tool | Module | Effect | Authority | Bytes |
| --- | --- | --- | --- | --- |
| `deep_work` | `DeepWork` | read-only | `work.delegate` | 874 |
| `incident_lookup` | `IncidentLookup` | read-only | `conversation.read` | 873 |

`deep_work` starts a durable background job that runs the same governed tools
and reports back. `incident_lookup` reads durable failure evidence so the agent
can explain a failure instead of guessing.

`deep_work` is classified `read_only` while its effect is to start a durable
job that can itself make external effects. That is a real gap in the effect
taxonomy, not a clerical one, and section 6 makes it a re-admission blocker.

### 1.10 This application's own source — 4 tools

| Tool | Module | Effect | Authority | Bytes |
| --- | --- | --- | --- | --- |
| `repo_read` | `RepoRead` | read-only | `repository.read` | 453 |
| `repo_grep` | `RepoGrep` | read-only | `repository.read` | 577 |
| `repo_list` | `RepoList` | read-only | `repository.read` | 412 |
| `code_check` | `CodeCheck` | read-only | `code.execute` | 439 |

The three read tools resolve a root through
`OpenAgents.Tools.Repository.tool_root/2` (`lib/openagents/tools/repository.ex:85`).
With the default `from: "image"` that root is the baked source of the running
code and needs no owner, workspace, or job — the only owner-free reads in the
catalog. With `from: "workspace"` they need a `job_ref`.

`code_check` parses Elixir source and, when the modules are not already loaded,
runs a compile probe **inside the running system**
(`lib/openagents/tools/code_check.ex:68`). It is classified `read_only`. Its
`code.execute` authority made it inert on every chat surface, which is the only
reason that combination never mattered.

### 1.11 Self-edit — 3 tools

| Tool | Module | Effect | Authority | Bytes |
| --- | --- | --- | --- | --- |
| `repo_edit` | `RepoEdit` | reversible write | `repository.write` | 550 |
| `repo_write` | `RepoWrite` | reversible write | `repository.write` | 379 |
| `repo_commit_push` | `RepoCommitPush` | external effect | `repository.write` | 471 |

Edit, create, and push files in a coding job's own clone, to that job's own
branch on the forge. They require `job_ref`, so only the coding work lane could
ever reach them — but they were offered on every chat surface, where they
refuse `:repository_workspace_unavailable`.

### 1.12 SCV — 1 tool

| Tool | Module | Effect | Authority | Bytes |
| --- | --- | --- | --- | --- |
| `scv_deploy` | `ScvDeploy` | external effect | `scv.deploy` | 1,034 |

Deploys a bounded OpenCode coding agent on OpenAgents capacity. Its own
description says "OPERATOR ONLY: a request from anyone who is not an
OpenAgents operator is refused" (`lib/openagents/tools/scv_deploy.ex:34`), and
it was offered to every signed-in person. At 1,034 bytes it was the second
largest definition in the catalog, spent almost entirely on telling
non-operators about a tool they cannot use.

### 1.13 Boxes — 4 tools

| Tool | Module | Effect | Authority | Bytes |
| --- | --- | --- | --- | --- |
| `box_new` | `BoxNew` | reversible write | `box.control` | 372 |
| `box_list` | `BoxList` | read-only | `box.control` | 262 |
| `box_exec` | `BoxExec` | reversible write | `box.control` | 522 |
| `box_stop` | `BoxStop` | reversible write | `box.control` | 308 |

Provision, list, drive, and stop sandbox VMs scoped to the conversation, with
an OpenCode harness installed. `box_new` provisions a VM and is classified
`reversible_write` rather than `external_effect`, so
`OpenAgents.Modules.SurfacePolicy` never asked for an approval receipt before
spending capacity (`lib/openagents/modules/surface_policy.ex:90`).

---

## 2. How it got to 37

Not blame — mechanism. Four properties of the config made growth the default
and subtraction the exception.

1. **Adding is one line; removing needs a reason.** The list was 37 bare module
   names with no comment, no grouping, and no stated membership rule. A new
   tool joined by appending a line, and nothing in review had a criterion to
   test that line against. A monotonic list is what you get.
2. **Nothing failed when a tool stopped working.** The catalog carries no
   liveness claim. A tool whose caller stopped supplying its context — the
   workspace family — kept being registered, kept being offered, and kept
   costing prompt budget. Its tests passed the whole time, because they build
   the context the tool wants rather than the context a caller supplies.
3. **The test catalog is not the shipped catalog.** `config/test.exs` overrode
   `:tools` with a different 32-module list, dropping the six external-effect
   modules and adding a test-only `recall_messages` tool
   (`test/support/tools/test_recall.ex`). Every test that reached for
   `Registry.current!()` was therefore measuring a fixture. Nothing tested what
   shipped, so nothing could notice it drifting. The fixture is still broader
   on purpose — see section 7 — but the divergence is now asserted rather than
   accidental.
4. **The selector made the size feel free.** `OpenAgents.Tools.Selector` ranks
   the catalog per turn and exposes roughly the top 12
   (`lib/openagents/tools/selector.ex:54`), so 37 tools never all reached the
   model at once. That capped the prompt cost and hid the real cost, which is
   that the top 12 of 37 mostly-broken tools is mostly broken tools. Section 8
   shows a measured selection where 7 of the 13 exposed tools could not
   execute for the caller who saw them.

The one guard that existed is a ceiling, not a criterion:
`OpenAgents.Tools.Registry.build/1` refuses lists longer than 64 modules
(`lib/openagents/tools/registry.ex:34`), and
`OpenAgents.RuntimeConfig.verify_startup!/2` refuses an empty one
(`lib/openagents/runtime_config.ex:147`). Between 1 and 64, nothing had an
opinion.

---

## 3. Who calls the catalog, and what they carry

A tool runs only if two gates pass: the caller holds its `required_authority`,
and the caller populated the fields its context resolver needs. Both gates are
set at the point the `ExecutionContext` is built, and there are four such
points.

| Caller | Built at | Serves |
| --- | --- | --- |
| `/sarah` chat | `lib/openagents/turns/turn_server.ex:464` | `ChatLive`, the visitor-scoped browser chat |
| Account chat | `lib/openagents/chat/account_turns.ex:270` | `/chat` (`ChatConsoleLive`), `POST` chat turns (`ChatTurnController`), and the `openagents coder` CLI path |
| Voice | `lib/openagents/voice/context_capture.ex:29`, `lib/openagents/voice_sessions/session_server.ex:658` | voice sessions |
| Work job | `lib/openagents/work/job_server.ex:328` | durable background jobs |

What each one puts in the context:

| Field | `/sarah` | Account chat | Voice | Work job |
| --- | --- | --- | --- | --- |
| `owner_visitor_id` | Visitor id | **`User` id** | Visitor id | Visitor id |
| `owner_user_id` | set | set | set | **not set** |
| `conversation_id` | set | set | set | set |
| `current_user_message_id` | set | **not set** | **not set** | **not set** |
| `memory_snapshot_ref` | set | **not set** | **not set** | set |
| `profile_memory_snapshot_ref` | set | **not set** | **not set** | set |
| `workspace` | placeholder | placeholder | placeholder | **not set** |
| `job_ref` | not set | not set | not set | set |
| authorities | 13 | 13 | 13 | 5, or 8 for a coding job |

Two structural notes follow from that table.

**The authority set is granted, not derived.** `ConversationExecutionContext`
hands every conversation caller the same fixed 13 authorities regardless of
who they are or what they have connected
(`lib/openagents/tools/conversation_execution_context.ex:18`). The authority
gate therefore filters nothing on a chat surface; only the resolver gate bites.
That is why `scv_deploy` reached non-operators and `computer_run` reached
people with no paired computer. Narrowing that grant is issue #156's work, not
this document's.

**Two of the four callers do not filter the offered catalog by authority at
all.** The account chat and voice paths go through
`OpenAgents.Tools.AdmittedCatalog`, which intersects the selector's ranking
with the context's authorities before offering anything
(`lib/openagents/tools/admitted_catalog.ex:34`). `/sarah` and the work job call
`Registry.prompt_definitions/3` directly and skip that filter
(`lib/openagents/turns/turn_server.ex:113`, `lib/openagents/work/job_server.ex:138`;
the job re-implements a partial version of the filter at `:141`). Execution is
still gated by `Runner` in every path, so this is an exposure inconsistency
rather than an authority hole — but it means "narrow the offering" is currently
two mechanisms, not one.

---

## 4. What actually worked

Applying both gates to all 37 tools. `Yes` means the authority is held and the
resolver's inputs are present. Everything else names the first gate that
refuses.

| Tool | `/sarah` | Account chat | Voice | Work job |
| --- | --- | --- | --- | --- |
| `module_discover` | Yes | Yes | Yes | Yes |
| `github_repo_list` | Yes | `owner_visitor_id` | Yes | Yes |
| `github_repo_read` | Yes | `owner_visitor_id` | Yes | Yes |
| `read_repository_file` | Yes | Yes | Yes | authority, `owner_user_id` |
| `list_repository_directory` | Yes | Yes | Yes | authority, `owner_user_id` |
| `read` | `workspace` | `workspace` | `workspace` | `workspace` |
| `write` | `workspace` | `workspace` | `workspace` | `workspace` |
| `edit` | `workspace` | `workspace` | `workspace` | `workspace` |
| `bash` | `workspace` | `workspace` | `workspace` | authority, `workspace` |
| `publish_changes` | `workspace` | `workspace` | `workspace` | authority, `workspace` |
| `open_pull_request` | no receipt | no receipt | no receipt | authority |
| `conversation_search` | Yes | `memory_snapshot_ref` | `memory_snapshot_ref` | Yes |
| `conversation_read` | Yes | `memory_snapshot_ref` | `memory_snapshot_ref` | Yes |
| `memory_list` | Yes | `owner_visitor_id` | `current_user_message_id` | `current_user_message_id` |
| `memory_search` | Yes | `owner_visitor_id` | `current_user_message_id` | `current_user_message_id` |
| `memory_remember` | Yes | `owner_visitor_id` | `current_user_message_id` | authority |
| `memory_correct` | Yes | `owner_visitor_id` | `current_user_message_id` | authority |
| `memory_forget` | Yes | `owner_visitor_id` | `current_user_message_id` | authority |
| `computer_list` | Yes | `owner_visitor_id` | Yes | Yes |
| `computer_probe` | Yes | `owner_visitor_id` | Yes | Yes |
| `computer_run` | Yes, if paired | `owner_visitor_id` | Yes, if paired | Yes, if paired |
| `computer_devin` | Yes, if paired | `owner_visitor_id` | Yes, if paired | Yes, if paired |
| `computer_agent` | Yes, if paired | `owner_visitor_id` | Yes, if paired | Yes, if paired |
| `deep_work` | Yes | `owner_visitor_id` | Yes | authority |
| `incident_lookup` | Yes | `owner_visitor_id` | Yes | Yes |
| `repo_read` | Yes | Yes | Yes | coding jobs only |
| `repo_grep` | Yes | Yes | Yes | coding jobs only |
| `repo_list` | Yes | Yes | Yes | coding jobs only |
| `code_check` | authority | authority | authority | coding jobs only |
| `repo_edit` | `job_ref` | `job_ref` | `job_ref` | coding jobs only |
| `repo_write` | `job_ref` | `job_ref` | `job_ref` | coding jobs only |
| `repo_commit_push` | `job_ref` | `job_ref` | `job_ref` | coding jobs only |
| `scv_deploy` | operators only | `owner_visitor_id` | operators only | authority |
| `box_new` | Yes | Yes | Yes | authority |
| `box_list` | Yes | Yes | Yes | authority |
| `box_exec` | Yes | Yes | Yes | authority |
| `box_stop` | Yes | Yes | Yes | authority |

Reading down the account-chat column — the caller behind `/chat`, the JSON
turn API, and the `openagents coder` path — **12 of 37 tools worked**. That
column is the wall.

Two entries need their refusal spelled out, because the failure is not where
it looks.

- `deep_work` on the account path passes its own validation, which only checks
  that `conversation_id` and `owner_visitor_id` are strings
  (`lib/openagents/tools/deep_work.ex:98`). It then fails at the database:
  `owner_visitor_id` carries a foreign key constraint to `visitors`
  (`lib/openagents/work/job.ex:90`), and a `User` id has no row there. The
  caller sees `:work_job_start_failed`, which reads like a runtime problem and
  is an identity problem.
- `scv_deploy` on `/sarah` is marked "operators only" rather than "Yes"
  because the authority set grants `scv.deploy` to everyone; the operator check
  happens inside the tool. The refusal is correct and the offer was not.

---

## 5. The zero base

Six tools ship (`config/config.exs:189`). Every one is read-only, every one
requires an authority every conversation caller already holds, and every one
resolves from fields every conversation caller populates correctly today.

| Tool | Why it survived |
| --- | --- |
| `module_discover` | Needs only the captured registry snapshot, so it cannot refuse. It is also the mechanism's escape hatch: `Selector.always_include/1` names it explicitly (`lib/openagents/tools/selector.ex:20`), and it is how the model and the reader see what the catalog currently holds. |
| `repo_read` | With the default `from: "image"` it reads the baked source of the running code. No owner, no workspace, no job. It answers "what does your code actually do" for every caller. |
| `repo_grep` | Same root, same absence of context requirements. Search is what makes reading a repository usable at all. |
| `repo_list` | Same. Listing before reading is how you avoid guessing paths. |
| `read_repository_file` | The only owner-scoped read that resolves through `owner_user_id`, the field every conversation caller sets correctly. It is the one way the agent reaches the person's own code. |
| `list_repository_directory` | Same resolver, same reason. Paired with the read so a path can be found rather than guessed. |

Two honest gaps in that set, named rather than hidden.

- **Non-coding work jobs lose five of the six.** A job's authority set is five
  strings and does not include `repository.read`
  (`lib/openagents/work/job_server.ex:584`); a coding job gains it through
  `Coding.authorities/0`. So a non-coding job now sees `module_discover` alone.
  It previously saw a slightly larger but equally unusable set. The fix is one
  line in `execution_authorities/1` plus setting `owner_user_id`, and it belongs
  with #156's authority work rather than here.
- **`module_discover` is close to redundant at this size.** With 6 tools and a
  `top_k` of 12, the selector omits nothing, so discovery returns exactly the
  tools the model was already handed — for 931 bytes, the largest definition in
  the new catalog. It stays for now because removing it means editing
  `OpenAgents.Tools.Selector`, which is #156's file, and because it is the
  visible handle on the catalog while the catalog is changing. It is the first
  candidate for the next cut.

### 5.1 What a browser user loses

The `/chat` console loses `deep_work`, the box family, and the offer of
everything in the account-chat column of section 4 that was already refusing —
which is most of it. In practice `/chat` keeps what worked and loses one real
capability, `deep_work`, plus the four box tools.

`/sarah` loses more, because more worked there. It loses profile memory
(`memory_*`), conversation recall (`conversation_search`, `conversation_read`),
the paired-computer family including delegation through `computer_agent`,
`incident_lookup`, GitHub browsing, `deep_work`, the box family, and
`scv_deploy` for operators. Those are real capabilities, and this is a real
regression on that surface.

It is deliberate, for two reasons. First, the catalog is one list; there is no
per-surface catalog today, and building one means changing `Tools.Selector`,
which #156 owns. Second, the capabilities that regress are exactly the ones
whose re-admission is cheapest to justify: they already work on one surface, so
the evidence needed for section 6 is mostly writing down what makes them work
and making it true for the other callers. The `/memory` and `/computers` pages
are unaffected; those read the same data through the browser, not through the
model.

### 5.2 What the model sees now

The whole catalog fits under `top_k`, so every caller is offered all six on
every turn: `module_discover`, `list_repository_directory`,
`read_repository_file`, `repo_grep`, `repo_list`, `repo_read`. There is no
ranking to get wrong and no omission to explain.

---

## 6. Getting back in

A tool is re-admitted to `config/config.exs` when all six statements are true
of it. The first four are mechanically checkable and
`test/openagents/tools/shipped_catalog_test.exs` checks what it can; the last
two are review, and this section exists so review has something to check
against.

1. **It works for every caller that can see it.** Not "works in its test" —
   works from each `ExecutionContext` construction site in section 3 that will
   be offered it. If one caller cannot supply its resolver's inputs, either fix
   that caller in the same change or do not admit the tool until the offering
   can be narrowed to callers that can.
2. **Its authority is one the caller genuinely holds.** Membership in the
   blanket 13-authority grant is not evidence; `scv_deploy` and `computer_run`
   both had it. Once #156 derives the authority set from what the person
   actually has, this criterion becomes the authority check itself, and this
   clause can be deleted.
3. **Its refusal path has a test.** Not only the success path. The test must
   assert the exact typed error a caller without the required context gets,
   because that error is what a person reads when the tool declines. DEGRADE-002
   already requires the error be typed and bounded; this requires that someone
   proved it.
4. **Its declared effect matches what it does.** `deep_work` is `read_only`
   while starting a job that can make external effects; `box_new` is
   `reversible_write` while provisioning a VM; `code_check` is `read_only`
   while running a compile probe in the running system. Each of those must be
   reclassified before its module returns, because
   `OpenAgents.Modules.SurfacePolicy` decides whether to demand an approval
   receipt purely from that field (`lib/openagents/modules/surface_policy.ex:90`).
5. **Its description says when *not* to use it.** A description that only
   describes capability makes the model try the tool and read the refusal.
   `memory_remember`'s "call this automatically" is the anti-pattern: it names
   no condition under which the model should not call it.
6. **It earns its prompt budget.** Section 8 gives the unit. A tool costs its
   encoded definition on every turn where the selector ranks it in. State what
   it buys against that number. `scv_deploy` at 1,034 bytes for a capability
   almost every caller is refused is the shape of a tool that does not.

Re-admission is a change to `config/config.exs` **and** to
`test/openagents/tools/shipped_catalog_test.exs`, whose `@shipped` list must be
edited by hand. That is intentional friction: it makes the addition visible in
review as a policy change rather than a one-line append.

---

## 7. Removed, unregistered, not offered

The Omega zero base drew the distinction that matters, between code that is
deleted, code that exists and refuses, and a surface that is never built. Its
rule — a surface that must not run is disabled as well as unrendered — has a
direct translation here, because a tool has the same three states with three
different costs to reverse.

| State | What it means for a tool | Cost to reverse | Used here for |
| --- | --- | --- | --- |
| **Removed** | The module is deleted from `lib/openagents/tools/` | Rewrite it | **Nothing.** All 37 modules stay in the tree. |
| **Unregistered** | The module exists, compiles, and is under test, but is absent from `:tools`, so no snapshot contains it and no caller can name it | One config line plus the section 6 criteria | The 31 tools cut here |
| **Not offered** | The module is registered, but a given caller is not shown it | Nothing; it is per-turn | Not used by this lane. It is the mechanism `Tools.Selector` and `AdmittedCatalog` already provide, and what #156 narrows. |

The translation of Omega's rule is that **unregistered is strictly safer than
not offered**, and this lane used the safer one. A not-offered tool is still in
the snapshot, so `Runner.fetch/3` resolves its name and only the authority
check stands between a model that guesses the name and execution. An
unregistered tool is not in the snapshot at all, and
`Runner` returns `:unknown_tool` before any authority question is asked
(`lib/openagents/tools/registry.ex:201`). For a catalog being cut because its
authority checks are known to be too permissive, that ordering matters.

One consequence to hold onto: **unregistered is not untested**.
`config/test.exs` deliberately keeps a broader fixture catalog so every module
still in the tree keeps its evidence, and
`test/openagents/tools/shipped_catalog_test.exs` asserts that fixture stays a
superset of the shipped set so nothing ships untested. Deleting the evidence
for a tool we intend to re-admit would make section 6 unsatisfiable.

---

## 8. What this cost

Tool definitions are sent on every request that carries tools, so the catalog
is a standing charge against the context window.

The measurement: build the real registry from the 37-module list with
`OpenAgents.Tools.Registry.build/1`, take `provider_definitions/1`, and measure
each definition's JSON encoding of `name`, `description`, and `input_schema` —
the three fields that reach the provider. Totals are bytes, not tokens; see the
caveat below.

| Set | Definitions | Bytes |
| --- | --- | --- |
| The whole 37-tool catalog | 37 | 21,396 |
| A measured selection for a coding intent | 13 | 8,569 |
| The same, with a paired computer | 14 | 8,894 |
| The 6-tool zero base | 6 | 3,410 |

The selection row is the one that matters, because the selector caps what
reaches the model. For the intent "read the file
`lib/openagents/tools/registry.ex` and explain it", the top 12 plus
`module_discover` were: `incident_lookup`, `scv_deploy`, `computer_probe`,
`github_repo_read`, `list_repository_directory`, `read`, `read_repository_file`,
`repo_grep`, `repo_list`, `repo_read`, `box_new`, `computer_agent`,
`module_discover`.

For an account-chat caller, 7 of those 13 could not have executed:
`incident_lookup`, `scv_deploy`, `computer_probe`, `github_repo_read`, `read`,
and `computer_agent` all refuse per section 4, and `scv_deploy` would refuse
again as a non-operator. That is 4,873 of 8,569 bytes — **57 percent of the
tool budget spent on tools that cannot run** — for a request that asked to read
a file. The zero base spends 3,410 bytes, all of it on tools that run.

Two caveats, stated because they bound the claim.

- **These are bytes, not tokens.** No tokenizer for the serving model is
  available in this repository, so the honest conversion is roughly four bytes
  per token for schema-heavy JSON, which would put the 37-tool catalog near
  5,000 tokens and the zero base near 850. Settling it needs a token count from
  the provider: send one request at each catalog size and read `prompt_tokens`
  off the response. That is section 10's open item.
- **Bytes are not the whole cost.** The larger cost of a broken catalog is not
  window pressure but behaviour: a model that has learned its tools usually
  refuse stops trying them, and starts narrating what it would have done. That
  cost is real and this document cannot measure it.

---

## 9. Where this meets issue #156

Two lanes are narrowing the same funnel from different ends and must not fight.

- **#156 narrows the offering.** It changes who is shown a tool, by deriving
  `ExecutionContext.authorities` from what the person actually has instead of
  granting a fixed 13, and by fixing `owner_visitor_id` at
  `lib/openagents/chat/account_turns.ex:273`. Its files are
  `lib/openagents/chat/` and `lib/openagents/tools/selector.ex`.
- **This lane narrows the catalog.** It changes what exists to be offered, in
  `config/config.exs`. It touches no file in `lib/`.

They compose in one direction and conflict in none: a smaller catalog filtered
by a narrower authority set is smaller still. The interaction to watch is that
**#156 landing makes several criteria in section 6 cheaper, not moot.** Once
`owner_visitor_id` is a real Visitor id, the eleven tools that refuse only for
that reason satisfy criterion 1 for the account caller, and criterion 2 becomes
the authority check rather than a review question. That is the intended
build-back trigger: #156 landing should be followed by a re-admission pass, not
by a revert of this cut.

Neither lane should assume the other's state. This document describes
`7b980b2589ce`; if #156 has landed when you read it, re-measure section 4
before quoting it.

---

## 10. What this document cannot settle

- **The token cost.** Section 8 measures bytes. The conversion to tokens needs
  a `prompt_tokens` reading from the provider at two catalog sizes, which needs
  a live key and a request. Nothing in this repository can produce it.
- **Whether anyone relied on the cut tools.** There is no per-tool invocation
  metric in this repository that would answer "how often did
  `computer_agent` succeed for a real person last month". `turn_tool_steps`
  holds the durable rows and would answer it against production data; the query
  is a group-by on `tool_name` and terminal status over a date range. Until
  someone runs it, section 5.1 is reasoning about capability, not usage.
- **Whether `code_check`'s compile probe is safe.** It evaluates model-supplied
  Elixir in the running system when the modules are not already loaded. Its
  `code.execute` authority kept it inert on chat surfaces, so the question was
  never forced. A coding work job does hold that authority. This lane did not
  audit that path, and re-admitting `code_check` should not happen before
  someone does.
- **Whether the fixture catalog is the right shape.** `config/test.exs` keeps
  32 of the 37 modules, dropping `bash`, `scv_deploy`, and the box family. That
  boundary was inherited, not chosen, and it means the five tools it drops now
  have neither a shipped surface nor fixture coverage. Deciding whether they
  should be dropped from the tree entirely is a separate call.

---

## Sources

- `config/config.exs`, `config/test.exs`, `lib/openagents/application.ex`
- `lib/openagents/tools/` — all 37 registered modules and the eight context resolvers
- `lib/openagents/tools/registry.ex`, `selector.ex`, `admitted_catalog.ex`, `runner.ex`
- `lib/openagents/tools/conversation_execution_context.ex`, `execution_context.ex`
- `lib/openagents/turns/turn_server.ex`, `lib/openagents/chat/account_turns.ex`, `lib/openagents/chat/open_router/tool_runtime.ex`, `lib/openagents/work/job_server.ex`, `lib/openagents/voice/context_capture.ex`
- `lib/openagents/modules/surface_policy.ex`, `lib/openagents/runtime_config.ex`
- `INVARIANTS.md` — TOOL-001 through TOOL-005, MODULE-001, MODULE-003, MODULE-004, DEGRADE-002
- `docs/taxonomy.md`, `docs/2026-08-23-openagents-coder-cli-spec.md`
- `test/openagents/tools/shipped_catalog_test.exs`
- The Omega zero-base mode design in the `openagents` monorepo, `docs/omega/2026-07-26-omega-zero-base-mode.md`, for the removed / disabled / not-rendered taxonomy section 7 translates
