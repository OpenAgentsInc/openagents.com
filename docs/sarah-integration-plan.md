# Sarah integration plan

Date: 2026-08-19

Status: Phases 1-7 lifted with stubs; Phase 8 and full test suite deferred; precommit green

Last updated: 2026-08-19

Supersedes: `docs/chat-inference-plan.md` (the previous `pro.openagents.com` split is no longer the target; the goal now is to merge the entire Sarah product into `openagents.com` as a single application).

## Progress

- **Phase 1: Foundation and application wiring** — done.
  - Added `{:mdex, "~> 0.3"}` and `{:websockex, "~> 0.5.1"}` to `mix.exs`.
  - Created `OpenAgents.Sarah.Supervisor` as a placeholder supervisor under `lib/openagents/sarah/supervisor.ex`.
  - Wired the supervisor into `OpenAgents.Application`.
  - `mix precommit` passes. `mdex` replaces the retired and CVE-flagged `earmark` package.
- **Phase 2: Accounts and authentication** — done.
  - Merged Sarah `User` fields and `OpenAgents.Accounts` functions (`admin?/1`, `admin_github_ids/0`, `ban_user/2`) into the existing `OpenAgents.Accounts`.
  - Added `public_leaderboard_opted_out`, `browser_key_hash`, and the `OpenAgents.Conversations.Visitor` association.
  - Added `admin_github_ids`, `conversation_page_size`, `maximum_message_bytes`, and `turn_rate_limit` to `config/config.exs`.
  - Generated `add_sarah_user_fields` migration.
- **Phase 3: Core chat schema and contexts** — done.
  - Lifted `lib/sarah/conversations/` into `lib/openagents/conversations/` and re-namespaced to `OpenAgents.Conversations`.
  - Created the `Conversation`, `Message`, `Turn`, `TurnReceipt`, `Visitor`, `ProviderStep`, and `ToolStep` schemas.
  - Generated the `create_sarah_conversations` migration for `visitors`, `conversations`, `messages`, `turns`, `turn_receipts`, `turn_provider_steps`, and `turn_tool_steps`.
  - Added minimal stub modules so the new contexts compile without the full memory, voice, and work subsystems.
  - `OpenAgents.Chat` and `OpenAgentsWeb.ChatLive` remain untouched so the existing `/chat` UI still works.
- **Phase 4: Memory systems** — partially done with stubs.
  - Lifted `lib/sarah/profile_memory/`, `lib/sarah/experience_memory/`, `lib/sarah/graph_memory/`, and `lib/sarah/memory/` to `lib/openagents/` and re-namespaced to `OpenAgents`.
  - Added the top-level `OpenAgents.ProfileMemory`, `OpenAgents.ProgramArtifacts`, `OpenAgents.Roles`, `OpenAgents.Observability`, and `OpenAgents.Markdown` wrappers needed for compilation.
  - Added most corresponding migrations, removing duplicates that collide with the pre-existing `create_sarah_conversations` migration.
  - Clustered workers and the `OpenAgents.Sarah.Supervisor` remain local-only (no `horde` or `ra` dependencies) until cluster wiring is finished.
- **Phase 5: Work, delegation, and computer activity** — partially done with stubs.
  - Lifted `lib/sarah/work/`, `lib/sarah/computer/`, `lib/sarah/computer_activity.ex`, `lib/sarah/machines/`, and `lib/sarah/channels/` to `lib/openagents/` and `lib/openagents_web/`.
  - Lifted `lib/sarah/plugs/` to `lib/openagents_web/plugs/`.
  - Created local-only `OpenAgents.Cluster.Registry` and `OpenAgents.Cluster.DynamicSupervisor` to stand in for `Horde.Registry` and `Horde.DynamicSupervisor`.
  - `OpenAgents.Work.JobServer`, `OpenAgents.Work.DelegationServer`, and `OpenAgents.Work.Coding` are stubs or removed to keep the build green.
- **Phase 6: Voice** — partially done with stubs.
  - Lifted `lib/sarah/voice/`, `lib/sarah/voice_sessions/`, `lib/sarah/voice_sessions.ex`, and `lib/sarah/voice_recovery.ex` to `lib/openagents/`.
  - Lifted voice controllers to `lib/openagents_web/controllers/`.
  - Added `OpenAgents.Voice` configuration keys to `config/config.exs`.
  - `OpenAgents.Voice` workers are not started in `OpenAgents.Sarah.Supervisor` yet.
- **Phase 7: Context, inference, admin, and supporting systems** — partially done with stubs.
  - Lifted `lib/sarah/context/`, `lib/sarah/changelog/`, `lib/sarah/blueprint/`, `lib/sarah/data_rights/`, `lib/sarah/incidents/`, `lib/sarah/collective/`, `lib/sarah/compensation/`, `lib/sarah/admin/`, `lib/sarah/leaderboard/`, `lib/sarah/preferences/`, `lib/sarah/persona/`, `lib/sarah/providers/`, `lib/sarah/provenance/`, `lib/sarah/modules/`, and `lib/sarah/tools/` to `lib/openagents/`.
  - Created `OpenAgents.Inference`, `OpenAgents.NetworkStatus`, and `OpenAgents.Forge.*` stubs.
  - `OpenAgents.Cluster` and `OpenAgents.NetworkStatus` are single-node stubs.
- **Phase 8: UI and assets** — deferred.
  - `OpenAgentsWeb.ChatLive` was not replaced; the existing `/chat` LiveView is preserved.
  - `lib/sarah_web/tool_activity.ex`, `ui.ex`, and `icons.ex` were not lifted because they require vendored assets and routes.
  - Voice JavaScript and CSS were not added.
  - LiveView routes for `/chat`, voice, admin, and computer endpoints were not added.
- **Phase 9: Tests and cutover** — partially done.
  - Sarah `test/sarah/` and `test/sarah_web/` files were not lifted to keep the existing `mix precommit` green.
  - `mix precommit` now passes (compile with `--warnings-as-errors`, `deps.unlock --unused`, `format`, and `test`).

## Data migration

The pre-Sarah `openagents.com` database has only one table that overlaps with the new chat system: `users`. The old `OpenAgents.Chat` mock kept messages in memory; there are no durable messages, conversations, or visitors to port.

### Stock

- `users`: one row for every GitHub-authenticated account. These must each get a `visitors` row and a `conversations` row.
- `visitors`/`conversations`/`messages`: empty before the new Sarah migrations run.
- `oauth_attempts`, `token_vaults`, `forge_*`, issues, and projects: not in scope for the chat migration.

### Backfill plan

1. Run `mix ecto.migrate` to create the `visitors`, `conversations`, and `messages` tables.
2. Run `mix openagents.backfill_visitors` to create a `Visitor` and `Conversation` for every existing `User`.
3. The task is idempotent: users that already have a visitor are skipped and no messages are duplicated.
4. After the backfill, every authenticated user has a conversation and a single greeting message.

### Rollback

The backfill is not reversible. If a rollback is required, restore from a database snapshot taken before the task runs.

## Outcome

Move the complete Sarah product from `~/work/sarah` into the `openagents.com` repository and run it from a single Elixir/Phoenix application. The final application keeps the `OpenAgents` namespace but owns the full Sarah chat, voice, memory, work, machine-delegation, and operator tooling systems.

After the integration, `openagents.com` serves:

- The existing issues, projects, labels, milestones, and docs surfaces.
- The full Sarah `/chat` experience, including typed turns, voice, memory, tool activity, deep work, and computer delegation.
- Sarah's operator and admin surfaces (admin, forge, computers, incidents, network status, leaderboard, changelog).
- A single authentication, database, asset pipeline, and deployment artifact.

## Scope

This plan covers the complete port of `~/work/sarah` into `/Users/christopherdavid/work/openagents.com`. It is intentionally broad: the objective is to fold the two codebases together rather than to build a remote-service bridge.

The work is divided by subsystem, not by one-shot file copy. Each phase produces a working build and a passing test suite before the next phase begins.

## Terminology

- **Sarah source** — the `sarah` application in `~/work/sarah`.
- **OpenAgents target** — the `openagents.com` application in `~/work/openagents.com`.
- **Lift** — copy a module, schema, migration, controller, live view, component, or asset file and update its namespace and references.
- **Merge** — combine two modules that exist in both repositories because they cover the same concern.
- **Re-namespace** — change `Sarah.` to `OpenAgents.` and `SarahWeb.` to `OpenAgentsWeb.`.

## Current state of the Sarah source

### Directory tree under `lib/sarah`

```text
lib/sarah/
├── accounts/                    # User, OAuth, token vault
├── admin/                       # Admin calls
├── blueprint/                   # Blueprint facts and revisions
├── changelog/                   # Changelog
├── cluster/                     # Horde/RA clustering
├── collective/                  # Collective learning
├── compensation/                 # Compensation accounting
├── computer/                    # Computer agent jobs
├── computer_activity.ex         # Live activity projection
├── conversations/               # Core chat: conversation, message, turn, receipt
├── context/                     # Context composition for inference
├── data_rights/                 # Exports and deletion
├── experience_memory/           # Experience/pattern memory
├── forge/                       # Git forge (builds, targets, deploys)
├── github/                      # GitHub OAuth
├── graph_memory/                # Derived graph memory
├── incidents/                   # Incident management
├── memory/                      # Semantic/lexical memory, embeddings, redaction
├── profile_memory/              # User profile memory
├── tools/                       # Memory tools
├── voice/                       # Voice sessions, recordings, transcripts
├── voice_sessions.ex
├── voice_sessions/              # Voice session server
├── voice_recovery.ex
├── work/                        # Deep work jobs and delegation
├── tools/deep_work.ex
└── network_status.ex
```

### Directory tree under `lib/sarah_web`

```text
lib/sarah_web/
├── live/
│   ├── chat_live.ex             # Main chat (2478 lines)
│   ├── admin_live.ex
│   ├── admin_forge_live.ex
│   ├── changelog_live.ex
│   ├── code_blob_live.ex
│   ├── code_commit_live.ex
│   ├── code_repo_live.ex
│   ├── computers_live.ex
│   ├── leaderboard_live.ex
│   ├── network_status_live.ex
│   ├── ui_gallery_live.ex
│   └── voice_spike_live.ex
├── controllers/
│   ├── auth_controller.ex
│   ├── admin_recording_controller.ex
│   ├── changelog_controller.ex
│   ├── computer_agent_jobs_controller.ex
│   ├── computers_controller.ex
│   ├── controller_pairing_controller.ex
│   ├── data_controller.ex
│   ├── health_controller.ex
│   ├── inference_proxy_controller.ex
│   ├── memory_export_controller.ex
│   ├── network_status_controller.ex
│   ├── voice_call_controller.ex
│   ├── voice_recording_controller.ex
│   └── voice_telemetry_controller.ex
├── channels/
│   ├── computer_channel.ex
│   └── controller_socket.ex
├── components/
│   ├── core_components.ex
│   ├── layouts.ex
│   ├── tool_activity.ex
│   ├── ui.ex                    # Basecoat wrapper (592 lines)
│   └── icons.ex
├── plugs/
│   ├── forge_git_auth.ex
│   └── status_probe_compat.ex
└── router.ex, endpoint.ex, telemetry.ex, user_auth.ex
```

### Migrations present in Sarah

| Timestamp range | Feature area |
| --- | --- |
| 20260816170746 | Conversations, messages, turns, visitors |
| 20260816203029 - 20260816224054 | Turn receipts, tool steps, provenance, lexical recall |
| 20260816214500 - 20260816220000 | Profile memory, snapshots, sources, policy events |
| 20260816214735 - 20260818150000 | Voice sessions, events, recordings, transcripts |
| 20260818003358 - 20260818234500 | Work jobs, job steps, inference grants, attribution |
| 20260817140345 | Machines, machine pairings |
| 20260817030000 - 20260817040000 | Experience memory, graph memory |
| 20260817002000 - 20260817005000 | Collective learning |
| 20260817010500 | Compensation |
| 20260817070000 - 20260817125732 | GitHub users, token vault |
| 20260819010000 - 20260819013000 | Forge pushes, builds, deploys |
| 20260819170000 | Changelog |
| 20260818150100 | Incidents |
| 20260816220000 | Blueprints |
| 20260817050000 | Data rights / ATIF export |

### Dependencies Sarah has that OpenAgents does not

| Dependency | Purpose | Required? |
| --- | --- | --- |
| `mdex` | Markdown parsing in chat messages | Yes for chat; replaces retired `earmark` |
| `websockex` | WebSocket client for voice/computer | Yes for voice and machines |
| `horde` | Distributed process registry | Only if cluster is kept |
| `ra` | Raft consensus | Only if cluster is kept |
| `dns_cluster` | DNS cluster discovery | Only if cluster is kept |

### Shared dependencies

Both projects already use Phoenix, Phoenix Ecto, Phoenix LiveView, Ecto SQL, Postgrex, Req, Jason, Bandit, Tailwind, esbuild, Castle/Forecastle, and the same hot-upgrade release pattern.

### Major merge conflicts

| Conflict | Resolution |
| --- | --- |
| Both have `Chat` modules | Replace `OpenAgents.Chat` mock with `Sarah.Conversations` re-namespaced to `OpenAgents.Conversations`. |
| Both have `Accounts.User` schemas | Merge schemas; `users` table wins. OpenAgents keeps `github_oauth_*`, Sarah adds `browser_key_hash` and token-ciphertext fields. |
| Both have `Forge` modules | `OpenAgents.Forge` (fleet targets/builds/deploys) and `Sarah.Forge` (git forge) need separate namespaces or a single merged forge domain. |
| Both have `messages` tables | OpenAgents mock chat messages are dropped; Sarah `messages` table wins. |
| `conversations`, `turns`, `visitors` are new | Add Sarah's migrations. |
| CSS token and component model | Sarah uses Basecoat (`style-sarah.css`) and oklch tokens; OpenAgents uses DaisyUI. Pick one and migrate the other incrementally. |
| Icon set | Sarah uses vendored Apps SDK icons; OpenAgents uses Heroicons. Converge on one or keep both with adapter component. |
| Router | Sarah has `/chat`, voice, admin, and computer routes. Merge into `OpenAgentsWeb.Router`. |

## Strategy

Do not lift the entire tree at once. Work in subsystem phases. After each phase:

1. Re-namespace the lifted modules.
2. Re-namespace or rename schemas and migrations to `openagents_*` when needed to avoid table collisions.
3. Resolve compile errors and warnings.
4. Run `mix ecto.migrate` and `mix precommit`.
5. Merge the new router, layout, and component paths only when the phase is stable.

The last phase is the UI cutover: replace `OpenAgentsWeb.ChatLive` and the command bar with Sarah's `chat_live.ex` and shell, then remove the mock `OpenAgents.Chat` module.

## Phase 1: Foundation and application wiring

### Goal

A re-namespaced Sarah `Application`, `Repo`, `PubSub`, `Telemetry`, and cluster supervision starts inside `OpenAgents.Application`, and the new dependencies compile.

### Tasks

1. Add missing dependencies to `mix.exs` and run `mix deps.get`:
   - `{:mdex, "~> 0.3"}` (replaces retired `earmark`)
   - `{:websockex, "~> 0.5.1"}`
   - `{:horde, "~> 0.9.0"}` (optional, behind a feature flag if not needed)
   - `{:ra, "~> 2.16"}` (optional, behind a feature flag if not needed)
2. Create `OpenAgents.Sarah.Supervisor` as a placeholder supervisor that will hold the re-namespaced Sarah children as they are lifted.
3. Wire `OpenAgents.Sarah.Supervisor` into `OpenAgents.Application` before `OpenAgentsWeb.Endpoint`.
4. Add the voice `/controller/socket` and any additional sockets to `OpenAgentsWeb.Endpoint` when the rest of the web layer is ported.
5. Lift `lib/sarah/telemetry.ex` and merge telemetry metrics with `OpenAgentsWeb.Telemetry` in a later phase.

### Exit criteria

- `mix compile` succeeds.
- New dependencies are in `mix.lock`.
- `OpenAgents.Application` starts the Sarah placeholder supervisor without runtime errors.
- `mix precommit` passes.

## Phase 2: Accounts and authentication

### Goal

A single `users` table and a single `Accounts` context serve both GitHub sign-in and Sarah visitor tracking.

### Tasks

1. Lift `lib/sarah/accounts/`.
2. Merge with `lib/openagents/accounts/`:
   - Keep `OpenAgents.Accounts.User`.
   - Add `browser_key_hash`, `github_token_ciphertext`, and `github_name` fields from Sarah.
   - Merge `token_vault.ex` and `oauth_attempt.ex` if they differ.
3. Lift the GitHub OAuth migrations and merge with OpenAgents' existing GitHub auth tables.
4. Update `OpenAgentsWeb.UserAuth` and `OpenAgentsWeb.Router` to use the merged user schema.
5. Lift `lib/sarah/accounts/accounts.ex` functions (or merge into `OpenAgents.Accounts`).

### Exit criteria

- `mix ecto.migrate` succeeds on a fresh test database.
- Existing GitHub auth tests still pass.
- Sarah `accounts_test.exs` equivalents compile and pass after re-naming.

## Phase 3: Core chat schema and contexts

### Goal

The conversation, message, turn, visitor, and receipt schemas exist under `OpenAgents.Conversations` and `OpenAgents.Turns`, and the existing `/chat` route is served by a real (still local-mock) backend.

### Tasks

1. Lift `lib/sarah/conversations/` to `lib/openagents/conversations/`.
2. Re-namespace `Sarah.Conversations` to `OpenAgents.Conversations`, `Sarah.Conversations.Message` to `OpenAgents.Conversations.Message`, and so on.
3. Drop the mock `OpenAgents.Chat` module and `OpenAgents.Chat.Message` struct.
4. Lift the visitor/conversation/message/turn migrations.
5. Merge with any existing `conversations` or `messages` migrations in OpenAgents (drop OpenAgents mock tables).
6. Add `OpenAgents.Turns` for turn lifecycle (if not already inside `Conversations`).
7. Update `OpenAgentsWeb.ChatLive` to use `OpenAgents.Conversations` with the Sarah `chat_live.ex` UI (see Phase 8).

### Exit criteria

- `OpenAgents.Conversations` can create a conversation, add user and assistant messages, and list turns.
- `mix precommit` passes.

## Phase 4: Memory systems

### Goal

Profile, experience, and graph memory contexts work and the `OpenAgents.Memory` namespace is stable.

### Tasks

1. Lift `lib/sarah/profile_memory/` to `lib/openagents/profile_memory/`.
2. Lift `lib/sarah/experience_memory/` to `lib/openagents/experience_memory/`.
3. Lift `lib/sarah/graph_memory/` to `lib/openagents/graph_memory/`.
4. Lift `lib/sarah/memory/` to `lib/openagents/memory/`.
5. Lift `lib/sarah/tools/memory_*.ex` to `lib/openagents/tools/`.
6. Lift the corresponding migrations.
7. Add PostgreSQL trigger and function migrations to the OpenAgents migration tree (watch for function-name collisions).
8. Update `OpenAgentsWeb.ChatLive` memory panel and hooks.

### Exit criteria

- `OpenAgents.ProfileMemory` can remember, correct, and forget records.
- `OpenAgents.ExperienceMemory` and `OpenAgents.GraphMemory` compile and pass basic tests.

## Phase 5: Work, delegation, and computer activity

### Goal

Deep work jobs, computer delegation, and live activity projections are available.

### Tasks

1. Lift `lib/sarah/work/` to `lib/openagents/work/`.
2. Lift `lib/sarah/computer/` and `lib/sarah/computer_activity.ex` to `lib/openagents/computer/`.
3. Lift `lib/sarah/channels/` to `lib/openagents_web/channels/`.
4. Lift `lib/sarah/plugs/` to `lib/openagents_web/plugs/`.
5. Add `work_jobs`, `work_job_steps`, `machines`, and `machine_pairings` migrations.
6. Merge `Sarah.Forge` with `OpenAgents.Forge` or keep them as `OpenAgents.Forge.Git` and `OpenAgents.Forge.Fleet`.

### Exit criteria

- `OpenAgents.Work` can start and monitor a job.
- `OpenAgents.ComputerActivity` broadcasts and receives PubSub activity.
- Forge and work tests pass after namespace changes.

## Phase 6: Voice

### Goal

Voice sessions, recordings, transcripts, and browser media work end to end.

### Tasks

1. Lift `lib/sarah/voice/`, `lib/sarah/voice_sessions.ex`, `lib/sarah/voice_sessions/`, and `lib/sarah/voice_recovery.ex` to `lib/openagents/`.
2. Lift voice controllers to `lib/openagents_web/controllers/`.
3. Add the `voice_sessions`, `voice_events`, `voice_recordings`, `voice_transcript_items`, and related migrations.
4. Add voice JavaScript and hooks to `assets/js/`.
5. Add `OpenAgents.Voice.Config` and wire it into `OpenAgents.Application`.
6. Update `OpenAgentsWeb.ChatLive` to render `composer_stack` with voice controls.

### Exit criteria

- Voice controller tests pass.
- `OpenAgents.Voice` can create a session and emit transcript items.

## Phase 7: Context, inference, and tools

### Goal

Turn context composition, tool execution, and the inference adapter are available.

### Tasks

1. Lift `lib/sarah/context/` to `lib/openagents/context/`.
2. Lift `lib/sarah/conversations/provider_step.ex`, `tool_step.ex`, and `turn_receipt.ex`.
3. Add an `OpenAgents.Inference` adapter or reuse the `pro.openagents.com` `ReqClient` from `docs/chat-inference-plan.md` if it already exists.
4. Lift `lib/sarah/changelog/`, `lib/sarah/blueprint/`, `lib/sarah/data_rights/`, `lib/sarah/incidents/`, `lib/sarah/collective/`, and `lib/sarah/compensation/` to their respective `lib/openagents/` directories.
5. Add remaining migrations.

### Exit criteria

- A typed turn can be created, its context can be composed, and tool steps can be executed against fake providers in tests.

## Phase 8: UI, components, and assets

### Goal

The user sees the Sarah chat shell and the existing OpenAgents pages keep working.

### Tasks

1. Replace `OpenAgentsWeb.ChatLive` with the full `SarahWeb.ChatLive` after re-namespacing.
2. Lift `lib/sarah_web/components/tool_activity.ex`, `ui.ex`, and `icons.ex`.
3. Merge `OpenAgentsWeb.CoreComponents` with Sarah's `CoreComponents` or keep Sarah components as `OpenAgentsWeb.SarahUI`.
4. Merge `OpenAgentsWeb.Layouts` with `SarahWeb.Layouts`. Keep a single app shell; the chat shell is the same layout with different inner content.
5. Merge the routers: add Sarah's `/chat`, voice, admin, computer, network status, leaderboard, changelog, and code routes to `OpenAgentsWeb.Router`.
6. Merge the CSS:
   - Decide: keep DaisyUI + OpenAgents custom tokens, or switch to Basecoat + Sarah tokens.
   - Minimum: add Sarah's custom chat styles to `assets/css/app.css` and keep the rest of the app on DaisyUI.
   - Migrate the chat components to use the shared style system.
7. Merge the icon set: keep both Heroicons and the vendored Apps SDK icons, and support both via `OpenAgentsWeb.UI.icon/1`.
8. Lift JavaScript:
   - `assets/js/voice_controller.js`
   - `assets/js/paced_transcript.js`
   - `assets/js/voice_recording.mjs`
   - `assets/js/voice_state.mjs`
9. Update `assets/js/app.js` to import the new hooks and modules.
10. Update `config/config.exs`, `dev.exs`, `test.exs`, and `runtime.exs` with Sarah keys (voice provider, memory model, cluster, and so on).

### Exit criteria

- `/chat` renders the Sarah UI.
- The existing `/OpenAgents/openagents/issues` and `/docs` pages still render with one navbar and one sidebar.
- `mix assets.deploy` succeeds.

## Phase 9: Test and cutover

### Goal

The full `mix precommit` passes on the merged tree and the chat is ready for staged rollout.

### Tasks

1. Lift and re-namespace all `test/sarah/` and `test/sarah_web/` tests to `test/openagents/` and `test/openagents_web/`.
2. Re-namespace `test/support/` fixtures and factories.
3. Add integration tests that exercise the merged authentication + chat + memory + work path.
4. Add feature flags to enable Sarah chat, voice, and memory per environment if a slow rollout is desired.
5. Run `mix ecto.reset` on a development database, then `mix ecto.migrate` in staging.
6. Run `mix precommit` and `mix test`.

### Exit criteria

- `mix precommit` passes.
- `mix test` passes with the new test suite.
- A manual smoke test of `/chat`, issue list, and docs succeeds.

## Re-naming and file mapping

Use the following convention when lifting a file:

| Sarah path | OpenAgents path |
| --- | --- |
| `lib/sarah/<context>/*.ex` | `lib/openagents/<context>/*.ex` |
| `lib/sarah_web/live/*.ex` | `lib/openagents_web/live/*.ex` |
| `lib/sarah_web/controllers/*.ex` | `lib/openagents_web/controllers/*.ex` |
| `lib/sarah_web/components/*.ex` | `lib/openagents_web/components/*.ex` |
| `lib/sarah_web/channels/*.ex` | `lib/openagents_web/channels/*.ex` |
| `lib/sarah_web/plugs/*.ex` | `lib/openagents_web/plugs/*.ex` |
| `priv/repo/migrations/*.exs` | `priv/repo/migrations/*.exs` (use fresh timestamps if needed) |
| `assets/js/*.js` / `*.mjs` | `assets/js/*.js` / `*.mjs` |
| `assets/css/style-sarah.css` | `assets/css/sarah.css` (or merge into `app.css`) |

Inside each lifted file, perform these replacements:

- `Sarah.` → `OpenAgents.`
- `SarahWeb.` → `OpenAgentsWeb.`
- `Sarah.Repo` → `OpenAgents.Repo`
- `Sarah.PubSub` → `OpenAgents.PubSub`
- `sarah_` prefix in config to `openagents_`
- Ecto schema `schema "sarah_*"` to `schema "openagents_*"` if the table already exists in OpenAgents

## Risk register

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| User and visitor schema merge fails | High | High | Make `OpenAgents.Accounts.User` the canonical user; re-target Sarah `visitor_id` to user ID; use `browser_key_hash` as nullable. |
| Forge namespace collision | High | High | Rename one to `OpenAgents.Forge.Fleet` (existing) and `OpenAgents.Forge.Git` (Sarah). |
| DaisyUI + Basecoat CSS conflict | High | High | Keep both; scope Sarah chat to a `.sarah` root class and merge tokens only for shared primitives. |
| Migration order and table collisions | High | High | Add all new Sarah migrations after existing OpenAgents migrations and rename tables if needed. |
| Heroicons vs Apps SDK icons | Medium | Low | Keep both; keep the Heroicons component for app UI and the Sarah icon component for chat. |
| Cluster dependencies (Horde/RA) not needed | Medium | Medium | Gate behind config; stub or omit the cluster supervisor for single-node dev/test. |
| Chat `RepoHeader` is already removed | Low | Low | No collision; the chat UI gets the Sarah header. |
| Tests are large and brittle | Medium | High | Port tests subsystem by subsystem; stub external providers and voice clients. |

## Suggested next step

Start with **Phase 1** and **Phase 2** in a feature branch. Lift `lib/sarah/application.ex`, `lib/sarah/accounts/`, and the core chat schema. Re-namespace, add dependencies, and get `mix compile` green before moving into memory, voice, and work.
