# PostHog integration runbook

Date: 2026-08-21

Status: Proposed

PostHog ships an agentic installer, the [AI wizard](https://github.com/PostHog/wizard), that wires PostHog into a codebase end to end. The wizard does not support Phoenix or Elixir: the framework is registered as "coming soon" in PostHog's own documentation, so running `npx @posthog/wizard` against this repository would not produce a usable integration.

This document is the manual replacement. Part 1 records what the wizard does so we know the full surface we are replicating. Part 2 turns that into a concrete runbook for this Phoenix application: server-side capture from Elixir, browser analytics through our asset bundle, pageviews that survive LiveView navigation, user identification, and an event taxonomy covering every product surface. Session replay and self-driving are out of scope.

Use this document as the single checklist for the integration work. Nothing in it requires the wizard.

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

### Step 1: Route credentials through runtime configuration

Follow the `OpenAgents.RuntimeConfig` pattern documented in [runtime-configuration.md](runtime-configuration.md):

| Setting | Requirement |
| --- | --- |
| `OPENAGENTS_POSTHOG_PROJECT_TOKEN` | `phc_...` public project token; empty disables all capture |
| `OPENAGENTS_POSTHOG_API_HOST` | Defaults to `https://us.i.posthog.com` |

When the token is empty, the application boots normally with capture fully disabled. This keeps local development and tests free of network calls without extra flags.

### Step 2: Add the Elixir SDK

Add the dependency in `mix.exs`:

```elixir
{:posthog, "~> 2.0"}
```

Configure it in `config/config.exs` with values supplied at runtime:

```elixir
config :posthog,
  enable: true,
  api_host: {:system, "OPENAGENTS_POSTHOG_API_HOST", "https://us.i.posthog.com"},
  api_key: {:system, "OPENAGENTS_POSTHOG_PROJECT_TOKEN", nil},
  in_app_otp_apps: [:openagents],
  enable_error_tracking: false
```

Notes:

- `enable_error_tracking: false` keeps `$exception` capture off until error tracking is a separate approved decision.
- In `config/test.exs`, set `test_mode: true` so events are dropped instead of sent.
- The package batches events and flushes them from its own supervision tree; captures do not block request handling.

### Step 3: Create one capture boundary

Add a single wrapper module, for example `OpenAgents.Analytics`, and route every server-side capture through it. The wrapper exists to enforce policy in one place:

- No-op when the project token is unset.
- Merge standard properties onto every event: `environment` (from `OPENAGENTS_ENVIRONMENT`), `app_version`, and `surface` (`web`, `api`, `live`).
- Never raise: a capture failure must not fail the caller. Rescue, log, and continue.
- Redact by default: reject property keys matching a denylist (`token`, `secret`, `password`, `ciphertext`, `credential`) and drop oversized values.

```elixir
OpenAgents.Analytics.capture("user_signed_up", distinct_id, %{
  github_login: login
})
```

Passing `distinct_id` explicitly beats relying on process context. The package supports `PostHog.set_context/1` via logger metadata when explicit passing is awkward, but explicit arguments keep call sites greppable.

### Step 4: Add posthog-js to the browser bundle

Install into the existing asset pipeline:

```console
npm install --prefix assets posthog-js
```

Initialize in `assets/js/app.js`:

```javascript
import posthog from "posthog-js"

if (window.POSTHOG_CONFIG.enabled) {
  posthog.init(window.POSTHOG_CONFIG.token, {
    api_host: window.POSTHOG_CONFIG.api_host,
    defaults: '2026-05-30',
    autocapture: true,
  })
}
```

Inject the config from the root layout so no token is hardcoded in JS:

```heex
<body data-posthog-enabled={@posthog_enabled}
      data-posthog-token={@posthog_token}
      data-posthog-api-host={@posthog_api_host}>
```

Read the data attributes in `app.js` before initializing. When disabled, render empty attributes and skip initialization entirely.

Two constraints specific to this repository:

- **No inline scripts.** The CSP allows exactly one nonce-bearing script (the theme bootstrap). Bundling `posthog-js` through esbuild satisfies the policy; do not add the copy-paste snippet.
- **CSP `connect-src`.** `lib/openagents_web/plugs/content_security_policy.ex` currently allows only `'self' ws: wss:`. Extend `connect-src` with the ingest hosts `https://us.i.posthog.com` and `https://us-assets.i.posthog.com`, or autocapture batches will silently fail to send.

### Step 5: Capture pageviews, including LiveView navigation

`posthog-js` records full page loads automatically. LiveView navigations change the URL without a reload, so add the documented listener after initialization:

```javascript
window.addEventListener("phx:navigate", ({ detail: { href } }) => {
  if (window.posthog?.__loaded) {
    posthog.capture("$pageview", { $current_url: href })
  }
})
```

Without this listener, every authenticated LiveView surface (chat, issues, projects, memory, computers) appears as one long session on the landing URL, which corrupts traffic and funnel analysis.

### Step 6: Identify users with one canonical ID

Choose the canonical `distinct_id` now: `user_<id>` where `<id>` is the database user ID. Every producer, client and server, uses exactly this string.

Client side:

1. Render the current user's `distinct_id` and stable profile properties (`github_login`, `github_id`) as data attributes in the root layout when a session exists.
2. After `posthog.init`, if a distinct ID attribute is present, call:

```javascript
posthog.identify(distinctId, {
  github_login: login,
})
```

Calling `identify` merges the anonymous ID that autocapture assigned before login into the identified person, so pre-authentication pageviews connect to the account. Guard the call so it fires once per browser session.

Server side:

1. In `AuthController.callback`, after a successful upsert, capture the auth events listed in the taxonomy below using `user_<id>`.
2. Distinguish sign-up from sign-in by comparing `inserted_at` and `updated_at` on the returned user: equality means the row was just created.
3. For requests, add `plug PostHog.Integrations.Plug` immediately before `plug OpenAgentsWeb.Router` in the endpoint. It attaches `$current_url`, method, and user-agent metadata to events captured during the request, and reads `X-PostHog-Distinct-Id` and `X-PostHog-Session-Id` headers when present.
4. Configure `posthog-js` tracing headers so browser fetches to this app carry those headers, linking server-side events to the originating browser session. Tracing headers are client-controlled analytics hints, never authorization input; server-side code must derive identity from the session, not from these headers.

For background processes (deployment workers, delegated work) there is no browser session: pass the owning `user_<id>` explicitly, or use a system distinct ID such as `system_<worker>` for unowned operational events.

### Step 7: Instrument the event taxonomy

Naming convention: snake_case, past tense, `object_verb` (`issue_created`, `chat_message_sent`). Every event gets the standard properties from step 3 plus the listed ones. Instrument domain contexts rather than individual controllers where one context serves both the LiveView UI and the GitHub-compatible JSON API, so both surfaces produce identical events.

Public and authentication:

| Event | Where | Properties |
| --- | --- | --- |
| `auth_started` | `AuthController.start` | none beyond standard |
| `auth_failed` | `AuthController` failure paths | `reason`: `consent_required`, `banned`, `denied`, `failed`, `unavailable` |
| `user_signed_up` | `AuthController.callback` on new user | `github_login` |
| `user_signed_in` | `AuthController.callback` on returning user | `github_login` |
| `user_logged_out` | `AuthController.logout` | none |

Chat and Sarah:

| Event | Where | Properties |
| --- | --- | --- |
| `chat_opened` | `ChatLive.mount` | none |
| `chat_message_sent` | turn submission handler | `length_bucket`, `tools_available` |
| `chat_turn_completed` | turn completion (server) | `duration_ms`, `model`, `tool_count`, `outcome` |
| `memory_saved` | memory write path | `kind` |
| `memory_viewed` | `MemoryLive.mount` | none |
| `delegated_work_created` | delegated-work creation path | `objective_kind` |
| `delegated_work_completed` | worker terminal result | `outcome`, `duration_ms` |
| `computer_paired` | pairing approval | none |
| `agent_job_created` | `ComputerAgentJobsController.create` | none |
| `voice_call_started` / `voice_call_completed` | voice call lifecycle | `duration_ms` on completion |

Issues, projects, and forge:

| Event | Where | Properties |
| --- | --- | --- |
| `issue_created` | issue creation context | `owner`, `repo`, `has_labels`, `has_assignees` |
| `issue_updated` | issue update context | `fields_changed` count |
| `issue_commented` | comment creation context | none |
| `label_created`, `milestone_created`, `project_created` | respective contexts | `owner`, `repo` |
| `project_item_added` | project item creation | none |
| `git_push_received` | push receipt path | `repo`, `commits_bucket` |
| `release_promoted` | promotion target path | `repo` |
| `deployment_started` / `deployment_completed` | deployment coordinator | `outcome`, `duration_ms` on completion |

Deliberate omissions:

- Admin surfaces stay uninstrumented. They are operator-only, low volume, and would add noise to activation funnels.
- API read endpoints (`GET`) stay uninstrumented except where they represent product activation. Volume without signal costs money per event.
- Never capture message bodies, objective text, token material, ciphertexts, or raw query strings. The `$current_url` property contains query parameters; rely on the wrapper's redaction and keep sensitive routes out of custom properties.

### Step 8: Build the starter dashboards through the PostHog MCP

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

### Rollout order

1. Steps 1-4: foundation (config, SDKs, wrapper, client init). No taxonomy yet.
2. Step 5-6: pageviews and identification. Verify the auth funnel end to end.
3. Step 7: taxonomy, starting with authentication and chat, then issues and forge.
4. Step 8: dashboards.
5. Step 9 gates each stage; do not stack stages without verification.

## References

- [AI wizard repository](https://github.com/PostHog/wizard)
- [Elixir library](https://posthog.com/docs/libraries/elixir)
- [Phoenix guide](https://posthog.com/docs/libraries/phoenix)
- [JavaScript Web SDK](https://posthog.com/docs/libraries/js)
- [Identifying users](https://posthog.com/docs/getting-started/identify-users)
- [PostHog MCP server](https://posthog.com/docs/model-context-protocol)
