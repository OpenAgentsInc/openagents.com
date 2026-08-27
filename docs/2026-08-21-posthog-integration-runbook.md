# PostHog integration runbook

Date: 2026-08-21

Status: Implemented in code; live staging verification remains

PostHog ships an agentic installer, the [AI wizard](https://github.com/PostHog/wizard), that wires PostHog into a codebase end to end. The wizard does not support Phoenix or Elixir: the framework is registered as "coming soon" in PostHog's own documentation, so running `npx @posthog/wizard` against this repository would not produce a usable integration.

This document is the manual replacement. Part 1 records what the wizard does so we know the full surface we are replicating. Part 2 turns that into a concrete runbook for this Phoenix application: server-side capture from Elixir, browser analytics through our asset bundle, pageviews that survive LiveView navigation, user identification, and an event taxonomy covering every product surface. Session replay and self-driving are out of scope.

Steps 1 through 8 of part 2 are implemented. What remains is operational:

1. Set `OPENAGENTS_POSTHOG_PROJECT_TOKEN` (and optionally `OPENAGENTS_POSTHOG_API_HOST`) in the staging environment.
2. Run the verification checklist against a live staging deployment (step 9).

Use this document as the single checklist for that work. Nothing in it requires the wizard.

## Part 1: What the PostHog wizard does

### What it is

The wizard (`npx @posthog/wizard`) is a TypeScript CLI, roughly 20K lines, distributed through npm. It authenticates the user against PostHag cloud, detects the project's framework, then hands the work to an LLM agent that edits the project directly. The agent runs inside a harness (the Claude Agent SDK or an alternative runtime) with two tool sources:

- A remote PostHog MCP server that can query project data and create insights, dashboards, and notebooks.
- A local in-process tool server with file-scoped helpers: `.env` inspection and writes, package-manager detection, skill installation, and a structured "ask the user" channel.

A run streams progress to a terminal UI, then finishes with an outro screen summarizing what changed.

### The default integration flow

Running the wizard with no arguments executes the default program. Its steps, in order:

1. **Detect the framework.** A registry of about 27 framework configs runs detection predicates against the install directory: presence of `package.json` dependencies for JavaScript frameworks, `manage.py` for Django, `mix.exs` defining a project for Elixir, and so on. Each config also gathers context (router type, project type) and carries version checks.
2. **Confirm setup.** An intro screen shows what will happen and asks for confirmation.
3. **Check health.** Before spending any work, the wizard polls status pages and liveness endpoints for its critical dependencies (the LLM provider, PostHog ingest, npm). If a critical dependency is down, it refuses to run.
4. **Ask disambiguation questions.** If detection cannot resolve a variant (for example, which router a framework uses), the user picks one.
5. **Authenticate.** Either an OAuth browser flow with a local callback server, or a personal API key for non-interactive runs. Tokens carry scoped permissions; the wizard verifies the grant was not narrowed.
6. **Install knowledge.** The wizard downloads a markdown "skill" for the detected framework from PostHog's skill registry. Skills are versioned independently of the CLI, so integration guidance improves without a wizard release.
7. **Run the agent.** The agent receives the credentials, the skill, and project context, then edits the codebase. For a typical web app it does all of the following:
   - Installs the relevant SDKs (client and server packages).
   - Initializes the SDKs with the project token and ingest host.
   - Enables autocapture and `$pageview` tracking in the browser.
   - Adds `identify` calls so events attach to real users.
   - Reads the actual product flows in the codebase and instruments meaningful custom events.
   - Writes credentials to `.env` files through a fenced tool so secret values never enter the model conversation.
   - Creates starter insights and a first dashboard in the PostHog app through the MCP tools.
8. **Finish.** Post-run hooks upload environment variables to detected hosting providers, the outro summarizes changes and next steps, and the wizard offers to install the PostHog MCP server into the user's AI coding clients.

### What lands in the integrated project

Regardless of framework, a completed default run produces the same product-analytics foundation:

- **Pageviews** (`$pageview`) on every navigation, including client-side routing.
- **Autocapture**: clicks, form submissions, and element visibility with data attributes, no per-element code required.
- **Identification**: anonymous browsers merge into identified persons at login.
- **Custom events** named after real product actions, with properties.
- **Web analytics basics**: UTM attribution, referrers, devices, entry pages, all derived from the events above.
- **Credentials** stored as environment variables, never hardcoded.
- **Starter dashboards** in the PostHog app.

Optional products the wizard can add but that this runbook treats separately: session replay, error tracking, feature flags, surveys, revenue analytics, data warehouse sources, and self-driving.

### Concepts worth carrying over

Three design ideas from the wizard transfer directly to a manual integration:

- **One canonical identity per user.** Browser events and server events must use the same `distinct_id`, or backend events become orphaned persons that cannot be joined to frontend behavior. The wizard enforces this in every framework template; we must enforce it ourselves.
- **Instrument at real product moments, not arbitrary ones.** The agent reads the codebase and places events where meaningful state changes happen (sign-up, first message, created object). A checklist of surfaces, like the taxonomy in part 2, is how you get the same coverage without an agent.
- **Credentials stay in configuration.** Tokens come from environment variables read at boot; nothing is committed.

## Part 2: Runbook for OpenAgents

### Scope

In scope:

- Server-side event capture from Elixir using the official [`posthog`](https://hex.pm/packages/posthog) package.
- Browser analytics using `posthog-js`, bundled into `assets/js/app.js` by esbuild (no snippet tag; see the CSP constraint below).
- Pageviews for full loads and LiveView push navigation.
- Autocapture.
- User identification with a single canonical `distinct_id` across client and server.
- A custom-event taxonomy covering every user-facing surface.
- Web analytics fundamentals that fall out of the above: traffic, referrers, UTMs, retention inputs.

Out of scope for this effort:

- Session replay and self-driving (explicitly skipped).
- Error tracking. Note that the Elixir package enables exception capture by default; step 2 disables it so scope stays controlled. Revisit later as its own decision.
- Feature flags, surveys, revenue analytics, warehouse sources. Feature flags are the most likely follow-up; the SDK support comes free once step 2 is done, and flag creation, evaluation testing, and rollout are all manageable through the PostHog MCP (`create-feature-flag` and related tools) when that decision lands.
- Installing the PostHog MCP server into coding agents. Useful later, unrelated to instrumentation.

### Prerequisites

1. Get the public project token (`phc_...`) from PostHog project settings for the OpenAgents project at `us.posthog.com`. This token is safe to ship in the browser bundle; it identifies the project, not a person.
2. Confirm the ingest host: `https://us.i.posthog.com`.
3. Decide the rollout environment. Staging first; production remains locked behind the existing staging gate, so the integration lands in staging configuration before any production decision.

### Step 1: Route credentials through runtime configuration (implemented)

The settings follow the same optional-text pattern the rest of `config/runtime.exs` uses for optional credentials; they are not part of the strict `OpenAgents.RuntimeConfig` validator, because analytics must never block a boot:

| Setting | Requirement |
| --- | --- |
| `OPENAGENTS_POSTHOG_PROJECT_TOKEN` | `phc_...` public project token; absent or empty disables all capture |
| `OPENAGENTS_POSTHOG_API_HOST` | Optional; defaults to `https://us.i.posthog.com` |

When the token is absent, the application boots normally with capture fully disabled: no PostHog supervision tree starts and every capture call is a no-op. Local development and tests stay free of network calls without extra flags.

### Step 2: The Elixir SDK (implemented)

`mix.exs` carries `{:posthog, "~> 2.0"}`. Configuration lives in `config/config.exs` with values supplied at runtime:

```elixir
config :posthog,
  enable: false,
  api_host: "https://us.i.posthog.com",
  api_key: nil,
  in_app_otp_apps: [:openagents],
  enable_error_tracking: false
```

Deviations from a plain install, all deliberate:

- The package's default supervisor stays off. `OpenAgents.Application` starts `{PostHog.Supervisor, config}` only when a project token was configured at boot, so an unconfigured environment runs zero PostHog processes.
- `enable_error_tracking: false` keeps `$exception` capture off until error tracking is a separate approved decision.
- `config/test.exs` sets `test_mode: true` so events are dropped instead of sent.
- The package batches events and flushes them from its own supervision tree; captures do not block request handling.

### Step 3: One capture boundary (implemented)

Every server-side event goes through `OpenAgents.Analytics.capture/3`. The boundary enforces policy in one place:

- No-op when the project token is unset (including blank strings).
- Merges standard properties onto every event: `environment` (from the runtime environment), `app_revision`, and `surface` (`server` unless the caller passes one).
- Drops property keys on a sensitive denylist (`token`, `secret`, `password`, `ciphertext`, `credential`, plus `_token`/`_secret`/... suffixes), truncates oversized values to `[truncated]`, bounds maps and lists by depth and count, and drops structs.
- Never raises: a sink failure logs `analytics_capture_failed` and returns `:ok`.

Identity helpers live on the same module:

- `Analytics.distinct_id(user_or_id)` derives the canonical `user_<uuid>` ID; already-prefixed values pass through unchanged.
- `Analytics.system_distinct_id(surface)` gives operational events a stable synthetic person per surface (`system_forge`).
- `Analytics.browser_distinct_id(conn)` reads the `X-PostHog-Distinct-Id` tracing header when present, falling back to `"anonymous"`.

A test sink (`Application.put_env(:openagents, :analytics_sink, ...)`) lets tests observe captures without the network; see `test/openagents/analytics_test.exs`.

### Step 4: posthog-js in the browser bundle (implemented)

`posthog-js` is installed into `assets/package.json` and bundled into `app.js` by esbuild — no snippet tag, so the CSP script policy is untouched. `OpenAgentsWeb.Plugs.PostHogBootstrap` assigns the boot configuration and session identity, and the root layout renders them as body data attributes; `app.js` initializes only when `data-posthog-enabled="true"`.

Initialization options, as shipped:

```javascript
posthog.init(token, {
  api_host: host,
  defaults: "2026-05-30",
  autocapture: true,
  capture_pageview: false,        // pageviews are explicit; see step 5
  capture_exceptions: false,      // error tracking is out of scope
  disable_session_recording: true, // replay is out of scope
  tracing_headers: [window.location.hostname], // links server events to sessions
})
```

Two constraints specific to this repository:

- **No inline scripts.** The CSP allows exactly one nonce-bearing script (the theme bootstrap). Bundling satisfies the policy; do not add the copy-paste snippet.
- **CSP `connect-src`.** The policy now allows `https://us.i.posthog.com` and `https://us-assets.i.posthog.com`; without them autocapture batches silently fail to send.

### Step 5: Pageviews, including LiveView navigation (implemented)

Automatic history tracking is disabled (`capture_pageview: false`) so exactly one producer owns each `$pageview`:

1. `app.js` captures one on initial load with the current URL.
2. A `phx:navigate` listener captures one per LiveView navigation with the target `href`.

Without the listener, every authenticated LiveView surface (chat, issues, projects, memory, computers) appears as one long session on the landing URL, which corrupts traffic and funnel analysis. With both producers explicit, no navigation double counts.

### Step 6: Identification with one canonical ID (implemented)

The canonical distinct ID is `user_<uuid>` where `<uuid>` is the database user ID; `OpenAgents.Analytics.distinct_id/1` is the single derivation point.

Server side:

1. `AuthController.callback` distinguishes sign-up from sign-in by comparing the upserted row's `inserted_at` and `updated_at`: equality means the row was just created. It then captures `user_signed_up` or `user_signed_in`.
2. The same callback writes a `posthog_identity` session key (`distinct_id` plus `login`). `logout` reads it before dropping the session to capture `user_logged_out`.
3. `plug PostHog.Integrations.Plug` sits immediately before the router in the endpoint, attaching request metadata and reading tracing headers.

Client side:

1. The root layout renders the session identity as data attributes through `PostHogBootstrap` — no database query on the render path.
2. After initialization, if a distinct ID attribute is present, `app.js` calls `posthog.identify(distinctId, { github_login })` once per browser session (guarded in `sessionStorage`). Identifying merges the anonymous pre-login events into the account's person.
Calling `identify` merges the anonymous ID that autocapture assigned before login into the identified person, so pre-authentication pageviews connect to the account. Guard the call so it fires once per browser session.

Server side:

1. In `AuthController.callback`, after a successful upsert, capture the auth events listed in the taxonomy below using `user_<id>`.
2. Distinguish sign-up from sign-in by comparing `inserted_at` and `updated_at` on the returned user: equality means the row was just created.
3. For requests, add `plug PostHog.Integrations.Plug` immediately before `plug OpenAgentsWeb.Router` in the endpoint. It attaches `$current_url`, method, and user-agent metadata to events captured during the request, and reads `X-PostHog-Distinct-Id` and `X-PostHog-Session-Id` headers when present.
4. Configure `posthog-js` tracing headers so browser fetches to this app carry those headers, linking server-side events to the originating browser session. Tracing headers are client-controlled analytics hints, never authorization input; server-side code must derive identity from the session, not from these headers.

For background processes (deployment workers, forge pushes) there is no browser session: events attribute to the owning account's `user_<uuid>` when one is known, or a stable system person such as `system_forge` for unowned operational events.

### Step 7: The event taxonomy (implemented)

Naming convention: snake_case, past tense, `object_verb` (`issue_created`, `chat_message_sent`). Every event gets the standard properties from step 3 plus the listed ones. Domain contexts rather than individual controllers carry the instrumentation wherever one context serves both the LiveView UI and the GitHub-compatible JSON API, so both surfaces produce identical events. Contexts that lacked an actor parameter gained an optional trailing actor argument (defaulting to `nil`, attributed to the surface's system person), and their call sites now pass the signed-in user.

Public and authentication:

| Event | Where | Properties |
| --- | --- | --- |
| `auth_started` | `AuthController.start` | none beyond standard |
| `auth_failed` | `AuthController` failure paths | `reason`: `consent_required`, `banned`, `denied`, `failed`, `unavailable` |
| `user_signed_up` | `AuthController.callback` on new user | `github_login` |
| `user_signed_in` | `AuthController.callback` on returning user | `github_login` |
| `user_logged_out` | `AuthController.logout` | none |

Anonymous funnel events (`auth_started`, `auth_failed`) attribute to the browser tracing header when present, else `"anonymous"`.

Chat and delegated work:

| Event | Where | Properties |
| --- | --- | --- |
| `chat_opened` | `ChatLive.mount` on connected mount | none |
| `chat_message_sent` | `ChatLive.launch_turn` | `length_bucket` |
| `chat_turn_completed` | terminal `turn_updated` broadcast in `ChatLive` | `outcome`: `completed`, `failed`, `cancelled`; `duration_ms` from turn timestamps |
| `chat_message_queued` | `ChatLive` queues a message behind an active turn | `length_bucket`, `queue_depth`, `conversation_id` |
| `chat_message_received` | complete assistant message in `ChatLive`; completed run in `Chat.AccountTurns` | `length_bucket`, `modality`, `conversation_id` |
| `chat_stream_chunk` | streaming assistant deltas, throttled to one event per second per stream | `conversation_id`, `modality` |
| `chat_tool_called` | `Turns.TurnServer` tool request; `tool_call_started` in `Chat.AccountTurns` | `tool_name`, `turn_id`, `conversation_id`; never arguments |
| `chat_tokens_used` | once per turn at terminal state in `Turns.TurnServer` and `Chat.AccountTurns` | `input_tokens`, `output_tokens`, `model`, `provider`, `conversation_id`, `turn_id`, `outcome` |
| `inference_model_selected` | inference proxy after grant and catalog admission, before the provider call | requested, granted, selected, provider, and provider model IDs; availability; substitution policy; effective pricing table, basis, rates, and promotion cutoff; request shape counts; grant budget ceilings and fence types; never bearer material, prompts, instructions, tool arguments, or provider credentials |
| `inference_model_served` | successful inference proxy call | all selection properties plus effective served model, disclosure state, outcome, and whether the provider reported usage |
| `inference_model_failed` | failed inference proxy provider call | all selection properties plus outcome, sanitized reason code, upstream status, and whether the provider reported usage |
| `chat_turn_failed` | non-completed terminal turn in `ChatLive`; failed or cancelled run in `Chat.AccountTurns` | `reason`, `outcome`, `conversation_id`, `turn_id` |
| `chat_voice_started` / `chat_voice_ended` | voice session lifecycle broadcasts in `ChatLive` | `conversation_id`; end adds `outcome`, `duration_ms` |
| `memory_saved` | `ProfileMemory.remember_explicit` | `disposition`: `stored`, `already_active` |
| `memory_viewed` | `MemoryLive.mount` on connected mount | none |
| `computer_paired` | `ComputersController.approve_pairing` success | `tier` |
| `agent_job_created` | `ComputerAgentJobsController.create` success | `machine_tier` |
| `voice_call_started` / `voice_call_ended` | `VoiceCallController` create/delete success | `duration_ms` on end |

Issues, projects, and forge:

| Event | Where | Properties |
| --- | --- | --- |
| `issue_created` | `Issues.create_issue` | `owner`, `repo`, `issue_number`, `issue_state`, `has_labels`, `has_assignees` |
| `issue_updated` | `Issues.update_issue` | `owner`, `repo`, `issue_number`, `previous_issue_state`, `issue_state`, `issue_state_changed`, `has_labels` |
| `issue_commented` | `Issues.create_comment` | `owner`, `repo`, `issue_number`, `author_role`, `is_maintainer` |
| `label_created`, `milestone_created`, `project_created` | respective contexts | `owner`, `repo` |
| `project_item_added` | `Projects.create_project_item` | `project_number`, `has_issue` |
| `git_push_received` | `Forge.Pushes` live push path | `repo`, `refs_changed`, `duration_ms` |
| `release_promoted` | `Forge.Targets.promote` | `repo` |
| `deployment_started` / `deployment_completed` | `Forge.Deployment.run` | `repo`, `deployment_id`; completion adds `outcome`, `duration_ms` |

Scoping decisions worth remembering:

- Forge pushes and deployments attribute to `system_forge`. Push capture sits only on the live receive-pack path; crash-recovery receipt reconciliation never captures, so recovered rows cannot double count.
- Delegated work started inside a conversation turn is represented by the chat turn events; the computers API path is covered by `agent_job_created`. A separate `delegated_work_created` would double count one of those surfaces.
- Memory owners without a linked account attribute to a synthetic `visitor_<id>` person.
- Admin surfaces stay uninstrumented: operator-only, low volume.
- API read endpoints (`GET`) stay uninstrumented except where they represent product activation.
- Never capture message bodies, objective text, token material, ciphertexts, or raw query strings. `$current_url` contains query parameters; rely on the wrapper's redaction denylist and keep sensitive routes out of custom properties.

### Step 8: Build the dashboards (implemented)

Build every dashboard from your coding agent through the PostHog MCP server instead of clicking in the web app. Dashboard, insight, and annotation objects are all writable through MCP tools, so this step becomes a scripted session you can rerun and review like code.

Connect the MCP server first if your client does not already have it. The wizard's `mcp add` command edits AI-client configuration only and works regardless of project language, so it is safe to use here even though the wizard's integration flow itself does not support Phoenix:

```console
npx @posthog/wizard mcp add
```

Then drive the whole step through MCP tools:

1. **Create the containers.** Call `dashboard-create` once per dashboard below, or browse `dashboard-templates-list` and create from a template with `use_template` when one matches. Add section headers with `dashboard-create-text-tile`.
2. **Test each chart before saving it.** Run the underlying query with the read-only query tools: `query-trends`, `query-funnel`, `query-stickiness`, `query-web-overview`, and `query-web-stats`. Confirm the series names and volumes look right while the data is still cheap to inspect.
3. **Save passing queries as insights.** Call `insight-create` with the tested query and pass the dashboard IDs in its `dashboards` field. Re-run later with `dashboard-insights-run` to confirm rendering.
4. **Mark the rollout.** Call `annotation-create` with the integration date so later trend breaks are attributable to the instrumentation itself.

The five dashboards, mapped to their queries:

| Dashboard | Tiles | Query source |
| --- | --- | --- |
| Web overview | visitors, pageviews, sessions, bounce rate, top pages, referrers, UTMs, devices | `query-web-overview` plus `query-web-stats` breakdowns |
| Activation funnel | `$pageview` → `auth_started` → `user_signed_up` → `chat_message_sent` | `query-funnel` |
| Engagement | weekly active chatters, `chat_turn_completed` duration, delegated-work completion rate | `query-stickiness` on `chat_message_sent`, `query-trends` with a median aggregate, `query-funnel` |
| Product adoption | issues and projects created per week, pushes received | `query-trends` broken down by event name |
| Volume sanity | total events per day by name | `query-trends`, total count, breakdown by event |

Keep the dashboard definitions in the agent session transcript or commit them as a script; because creation goes through MCP calls, recreating the set in staging or after a project reset is mechanical.

The operations project also has the pinned **Issue triage health** dashboard
(dashboard `2022873`). It contains:

- **Triage health snapshot** (insight `11257107`): the rolling 90-day median
  time from `issue_created` to the first `issue_commented` event whose
  `is_maintainer` property is true, plus the share of open issues that remain
  unlabeled 24 hours after creation.
- **Weekly issue flow** (insight `11257108`): issues created and closed for
  each of the trailing eight weeks. A closure is an `issue_updated` event with
  `issue_state_changed = true` and `issue_state = "closed"`.

The dashboard and its two HogQL insights were created through the PostHog REST
API because the MCP server was unavailable during setup. This does not change
their ownership or query semantics.

Historical issue events do not contain the new triage properties. Expect the
response, label, and closure metrics to populate from the deployment that
introduces those properties; do not infer historical zeros from missing data.

### Weekly triage review

Review the pinned dashboard once each week:

1. Record the median first-maintainer response and compare it with the prior
   week.
2. Compare issues created with issues closed. Investigate sustained intake
   above closure volume.
3. Open the unlabeled count and label or close each eligible issue.
4. Treat a blank response metric as insufficient instrumented data, not a zero.
5. Add an annotation for instrumentation, policy, or staffing changes that can
   explain a trend break.
6. Record follow-up work as forge issues and link the dashboard in the issue.

### Step 9: Verify

Work through this checklist in staging. Browser-side checks stay manual; every server-side or ingestion check runs through the PostHog MCP against the events table, which beats tailing the web UI:

1. Cold load of `/` produces a `$pageview`; navigating to `/docs` through a LiveView link produces a second one with the correct `$current_url`. Confirm in the browser and then with an `execute-sql` query filtering `event = '$pageview'` ordered by timestamp.
2. Autocapture lands click events. Query the last hour of events where `event LIKE '$autocapture%'`.
3. Complete a GitHub OAuth login: `auth_started`, `user_signed_up` (or `user_signed_in`) arrive, and the identified person shows both the anonymous pre-login events and the identified ones. Check person merging with a persons query on the distinct ID.
4. Send a chat message: `chat_message_sent` on the client and `chat_turn_completed` on the server attach to the same person.
5. Create an issue through the web UI and through the JSON API: both produce `issue_created` with a `surface` property distinguishing them.
6. Search captured event properties for token-shaped strings and message content; find nothing. An `execute-sql` scan over recent event properties catches this faster than the UI.
7. Stop the app with `OPENAGENTS_POSTHOG_PROJECT_TOKEN` unset: boot succeeds and no network calls go to PostHog.
8. Run the test suite: `test_mode` drops events and no test asserts on outbound PostHog traffic.
9. Check the browser console for CSP violations against the ingest host; fix `connect-src` if any appear.
10. Confirm each taxonomy event registered as an event definition with `read-data-schema`, so typos surface as missing definitions rather than silent zero-volume charts.

## Operator analytics surface

`/admin/analytics` gives operators the usage and triage picture without opening
PostHog. It pulls computed results from the PostHog REST API at request time
through `OpenAgents.PostHog` (a personal API key over HogQL), so it adds no
second aggregation authority: the numbers match what the PostHog app answers
for the same window.

Settings (all optional; absent credentials disable the read path only, independently of capture):

| Setting | Requirement |
| --- | --- |
| `OPENAGENTS_POSTHOG_PERSONAL_API_KEY` | A `phx_...` personal API key created for this integration |
| `OPENAGENTS_POSTHOG_PROJECT_ID` | The numeric PostHog project id |
| `OPENAGENTS_POSTHOG_APP_HOST` | Optional; defaults to `https://us.posthog.com`. This is the app/API host, not the ingest host |

The page renders six bounded projections: activation funnel, chat turn outcomes
and durations, event volume, top pages, triage health, and weekly issue flow.
Usage projections cover the trailing 24 hours, triage health covers 90 days,
and issue flow covers eight weeks. It renders unconfigured credentials, an
unanswered query (with retry, never stale numbers), and loading as first-class
states. It shows aggregates only; no conversation content is reachable from
it. The route is operator-gated like the rest of `/admin` and classified in the
route authority inventory as `analytics:read`.

### Rollout order

1. Steps 1-6 are implemented and covered by the test suite; they activate the moment a project token is configured.
2. Set `OPENAGENTS_POSTHOG_PROJECT_TOKEN` in staging and confirm boot with capture live.
3. Step 7 events flow automatically; watch volume in the first days.
4. Step 8 is complete; review the pinned triage dashboard weekly.
5. Step 9 gates each stage; do not stack stages without verification.

## References

- [AI wizard repository](https://github.com/PostHog/wizard)
- [Elixir library](https://posthog.com/docs/libraries/elixir)
- [Phoenix guide](https://posthog.com/docs/libraries/phoenix)
- [JavaScript Web SDK](https://posthog.com/docs/libraries/js)
- [Identifying users](https://posthog.com/docs/getting-started/identify-users)
- [PostHog MCP server](https://posthog.com/docs/model-context-protocol)
