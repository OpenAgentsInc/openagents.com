# CLI and API parity

**Date:** 2026-08-21
**Commits measured:** `81e4c25eb5b5` (`openagents/main`, the forge) for the API; `5bd0061e4f6e` in the `openagents` monorepo for `packages/openagents-cli` (package version `0.1.7`)
**Status:** Stage 1 shipped on 2026-08-21 as `@openagentsinc/cli@0.2.1`; see section 5. Everything else below describes the surface as measured, unchanged.
**Question:** Does the CLI only cover repository upload? What of the Issues and Projects API does it reach? Should that coverage be generated from an OpenAPI document instead of hand-written? What is the fastest honest path to managing issues and projects from a terminal?
**Method:** direct reading of `lib/openagents_web/router.ex`, every controller it routes to under `/api/v3`, the contexts behind them (`lib/openagents/issues.ex`, `labels.ex`, `milestones.ex`, `projects.ex`, `repositories.ex`), the auth plugs, `lib/openagents_web/route_authority.ex`, `priv/api-contracts/repositories-v1.json` and its controller and test, and `docs/openagents-cli/`; plus direct reading of all 21 source files in the `openagents` monorepo at `packages/openagents-cli/src/` and its tests. The CLI lives in a different repository, so every CLI citation names it. Claims that neither repository can settle are in section 7 with the command that would settle them.

---

## 0. Summary

The owner is right. The CLI is repository-shaped and reaches **none** of the Issues and Projects API.

The numbers are clean. The router exposes **50 routes under `/api/v3`** (`lib/openagents_web/router.ex:229`, `:253`, `:259`). The CLI calls **11 of them** — the authenticated user, repository create, list, view, delete, the two import routes, import status, and the two device-authorization routes. Those 11 are exactly the routes named in the hand-written contract document at `priv/api-contracts/repositories-v1.json:18`. The other **39 routes — every issue, comment, label, milestone, assignee, and project endpoint — have no CLI surface at all**, and the CLI's own documentation says so: `docs/openagents-cli/command-reference.md:3` scopes the tool to "authentication and hosted repositories", and `:171` lists a generic API command among the things the release does not provide.

There is **no OpenAPI document**. What exists instead is a 99-line hand-written JSON artifact served at `/api/contracts/repositories-v1.json` (`lib/openagents_web/router.ex:222`). It lists endpoints as opaque `"METHOD /path"` strings, has no types, no request bodies, no response schemas, and no status codes. It covers 11 of the 50 routes. Nothing derives it from the router, and nothing verifies it against the router.

The drift story today is that **nothing fails**. The server's contract test asserts the document is served with the right headers and carries the right name and version, and nothing else (`test/openagents_web/controllers/api_contract_controller_test.exs:4`). The CLI's contract test hashes the copy it vendors itself and compares it to a constant in its own source (`openagents` monorepo, `packages/openagents-cli/test/api-contract.test.ts:13`) — it never fetches the server's copy. The two files are byte-identical today, both hashing to `5be86539258c…`, and that is a coincidence maintained by hand. Rename a field and both test suites stay green; the failure surfaces in a user's terminal as a `ContractError`.

Three findings matter more than the raw endpoint count, because they mean the gap is not only "the CLI has no `issue` command":

1. **You can write an issue into a private repository and cannot read it back.** Writes resolve the repository through `Repositories.get_writable_by_path!/3` (`lib/openagents_web/controllers/issue_controller.ex:18`), which does not filter on visibility. Reads run through a pipeline with no authentication at all (`router.ex:230`) and resolve through `Repositories.get_public_by_path!/2` and `Issues.get_issue_by_path!/3`, which require `visibility == "public"` (`lib/openagents/repositories.ex:68`, `lib/openagents/issues.ex:159`). `POST` returns `201` with the issue body; the following `GET` returns `404`. This is deliberate, not accidental — `test/openagents_web/route_authority_test.exs:26` asserts the read is `:public_read` and the write is `:authenticated_api` — but it makes terminal issue management impossible for private work regardless of what commands the CLI grows.
2. **The list endpoints have no pagination and one filter.** `IssueController.index` calls `Issues.list_issues/2` with `state` only (`issue_controller.ex:10`), returning every matching issue in one unbounded array, while `Issues.list_issues_page/2` — which already supports `:label`, `:assignee`, `:milestone`, `:q`, and `:page` — sits unused by the API (`lib/openagents/issues.ex:40`).
3. **The whole `projectsV2` surface is pinned to one repository.** `Projects.list_projects_by_owner/1` and `get_project_by_owner_and_number!/2` both scope to `Repositories.initial_repository!()` (`lib/openagents/projects.ex:26`, `:131`), which is the constant `OpenAgentsInc/openagents.com` (`lib/openagents/repositories.ex:22`). `ProjectController.create` ignores its own `:owner` path segment when choosing a repository and writes into that same one (`lib/openagents_web/controllers/project_controller.ex:21`).

On generation: **do not generate the commands.** Ship a generic `openagents api` passthrough first, hand-write the ten commands that carry the traffic, and only then invest in a derived contract document. Section 4 argues it. The short version is that a passthrough buys total endpoint coverage for roughly 200 lines and can never drift because it makes no claims, while generated command surfaces are worst exactly at the commands people use every day. Generating a *client* is defensible; generating a *CLI* is not.

The first two stages are small and independent: the passthrough command (CLI repository only, no server change), then moving the read routes behind optional bearer auth so a private repository's issues are readable by someone entitled to read them (this repository only, additive).

---

## 1. What the CLI covers today

### 1.1 The command tree

The CLI is 3,452 lines of Effect TypeScript across 21 files in `packages/openagents-cli/src/` in the `openagents` monorepo. It registers two command groups and twelve leaf commands, wired at `cli.ts:800`:

| Group | Command | Source line (`openagents` monorepo, `packages/openagents-cli/src/cli.ts`) |
| --- | --- | --- |
| `auth` | `login` (with `--headless`, `--resume`, `--token-stdin`) | `:183` |
| `auth` | `token-stdin` | `:144` |
| `auth` | `status` | `:79` |
| `auth` | `logout` | `:331` |
| `auth` | `setup-git` | `:369` |
| `auth` | `git-credential` (internal Git credential-helper protocol) | `:349` |
| `repo` | `create` | `:445` |
| `repo` | `import` | `:557` |
| `repo` | `list` | `:640` |
| `repo` | `view` | `:699` |
| `repo` | `clone` | `:719` |
| `repo` | `delete` | `:756` |

Four global flags apply to all of them — `--profile`, `--api-url`, `--json`, `--no-color` (`cli.ts:23`–`:31`) — and the root command describes itself as "Manage OpenAgents repositories" (`cli.ts:34`).

### 1.2 The endpoints it calls

Eleven, all of them in the repository, identity, and device-authorization families:

| Method and path | Called from (`openagents` monorepo) | Reached by |
| --- | --- | --- |
| `POST /api/v3/device/authorizations` | `src/device-client.ts:52` | `auth login` |
| `POST /api/v3/device/authorizations/token` | `src/device-client.ts:83` | `auth login` |
| `GET /api/v3/user` | `src/repository-client.ts:363` | `auth status`, `repo import` |
| `GET /api/v3/user/repos` | `src/repository-client.ts:381` | `repo list` |
| `POST /api/v3/user/repos` | `src/repository-client.ts:333` | `repo create` |
| `POST /api/v3/orgs/{org}/repos` | `src/repository-client.ts:333` | `repo create` |
| `POST /api/v3/user/repos/imports` | `src/repository-client.ts:524` | `repo import` |
| `POST /api/v3/orgs/{org}/repos/imports` | `src/repository-client.ts:525` | `repo import` |
| `GET /api/v3/repos/{owner}/{repo}` | `src/repository-client.ts:278`, `:399` | `repo view`, `repo clone`, provisioning poll |
| `DELETE /api/v3/repos/{owner}/{repo}` | `src/repository-client.ts:413` | `repo delete` |
| `GET /api/v3/repository-imports/{id}` | `src/repository-client.ts:424` | `repo import` wait loop |

Git data transfer is not in this list because it is not API traffic. `repo clone` shells out to `git` (`src/git-runner.ts`), and `auth setup-git` installs this binary as a Git credential helper so ordinary `git push` and `git fetch` authenticate against the smart HTTP transport at `router.ex:203`.

### 1.3 The contract layer, and what it actually checks

`src/api-contract.ts` is 105 lines of Effect `Schema` definitions for exactly four response shapes — the authenticated user, a repository, a repository import, and a loose error envelope (`api-contract.ts:14`, `:51`, `:64`, `:93`). Every response is decoded through it, and a decode failure becomes a `ContractError` naming the operation (`src/repository-client.ts:227`).

The transport underneath is deliberately thin: one `request` function that takes an origin, a method, a path string, an optional bearer token, and an optional JSON body (`src/api-transport.ts:82`). Paths are built by string interpolation at each call site. There is no route table, no path type, and no generated surface — adding an endpoint means adding a method to `repository-client.ts`, a schema to `api-contract.ts`, and a command to `cli.ts`.

The contract *artifact* is a separate thing from the contract *schemas*, and this is where the drift story lives. `api-contract.ts:5` pins a SHA-256, and `test/api-contract.test.ts:13` reads `packages/openagents-cli/contracts/repositories-v1.json` — a copy vendored inside the CLI package and shipped in its npm tarball (`package.json`, `files`) — hashes it, and asserts it equals that constant. **The test never contacts the server.** It detects an unannounced edit to the vendored copy. It cannot detect that the server changed.

Both copies currently hash to `5be86539258c38d5249887ff2628680b1f90c93909d6e83e86a836d0250ce79f`, so the two repositories agree today. Nothing enforces that they keep agreeing.

### 1.4 Verdict on the owner's belief

Confirmed, with one refinement. "Repo upload stuff" understates it slightly — the CLI also does device-flow authentication, credential storage, Git credential-helper installation, repository listing, viewing, cloning, and deletion, and it waits on durable provisioning and import state machines. But on the substance the belief is exactly right: **the CLI has no issue, comment, label, milestone, assignee, or project command, and calls no endpoint in those families.** Its own reference documentation states the boundary (`docs/openagents-cli/command-reference.md:3`, `:171`) and its `README.md` in the monorepo has sections only for install, API selection, sign-in, and repositories.

One documentation defect found in passing, relevant because it is evidence for section 4: `docs/openagents-cli/command-reference.md:173` says the release "does not provide `repo delete`" while the same file documents `repo delete` in full at `:122`, the command exists at `cli.ts:756`, and `docs/openagents-cli/index.md:34` describes it as available. A hand-maintained description drifted from the thing it describes, in the smallest possible surface, in the same file.

---

## 2. What the API offers

Fifty routes under `/api/v3`, in three scopes distinguished by pipeline.

### 2.1 Authentication, in one paragraph

Three pipelines serve `/api/v3`. `:api` (`router.ex:25`) runs `accepts ["json"]` and nothing else — **no authentication whatsoever**; a bearer token sent to one of these routes is ignored and `conn.assigns.current_user` is never set. `:forge_write_api` (`router.ex:38`) requires `Authorization: Bearer oa_pat_…` carrying scope `forge:write`, or it halts with `401 {"error":"invalid_api_token"}` (`lib/openagents_web/plugs/api_token_auth.ex:10`). `:optional_forge_api` (`router.ex:43`) accepts the same token but tolerates its absence, which is what lets `GET /api/v3/repos/:owner/:repo` widen from public repositories to the caller's private ones (`lib/openagents_web/controllers/repository_controller.ex:64`). There is exactly one scope in the whole system: `@allowed_scopes ["forge:write"]` (`lib/openagents/api_tokens.ex:12`). A token that can file an issue can also delete a repository.

### 2.2 Reads — no authentication, public repositories only

All sixteen are in the `:api` scope at `router.ex:229`.

| Method and path | Controller action | Line | GitHub-compatible path? |
| --- | --- | --- | --- |
| `GET /repos/:owner/:repo/issues` | `IssueController.index` | `:235` | yes |
| `GET /repos/:owner/:repo/issues/:issue_number` | `IssueController.show` | `:236` | yes |
| `GET /repos/:owner/:repo/issues/:issue_number/comments` | `CommentController.index` | `:237` | yes |
| `GET /repos/:owner/:repo/issues/comments/:id` | `CommentController.show` | `:238` | yes |
| `GET /repos/:owner/:repo/issues/:issue_number/labels` | `IssueLabelController.index` | `:239` | yes |
| `GET /repos/:owner/:repo/issues/:issue_number/assignees` | `IssueAssigneeController.index` | `:240` | no — GitHub carries assignees inside the issue object |
| `GET /repos/:owner/:repo/labels` | `LabelController.index` | `:241` | yes |
| `GET /repos/:owner/:repo/labels/:name` | `LabelController.show` | `:242` | yes |
| `GET /repos/:owner/:repo/milestones` | `MilestoneController.index` | `:243` | yes |
| `GET /repos/:owner/:repo/milestones/:milestone_number` | `MilestoneController.show` | `:244` | yes |
| `GET /repos/:owner/:repo/assignees` | `AssigneeController.index` | `:245` | yes |
| `GET /repos/:owner/:repo/assignees/:assignee` | `AssigneeController.show` | `:246` | path yes, body no — GitHub answers `204`/`404` with no body |
| `GET /users/:username/projectsV2` | `ProjectController.index` | `:247` | no — ProjectsV2 is GraphQL-only on GitHub |
| `GET /users/:username/projectsV2/:project_number` | `ProjectController.show` | `:248` | no |
| `GET /users/:username/projectsV2/:project_number/items` | `ProjectController.items` | `:249` | no |
| `GET /users/:username/projectsV2/:project_number/fields` | `ProjectController.fields` | `:250` | no |

Every issue, label, milestone, and assignee read is gated in the controller by `Repositories.get_public_by_path!/2` or an equivalent `visibility == "public"` clause, so a private repository is indistinguishable from a missing one. The four project reads apply **no visibility predicate at all** (`project_controller.ex:8`, `:41`, `:53`, `:144`); they are constrained only by being pinned to the initial repository.

### 2.3 Writes — bearer token with `forge:write`, repository membership required

All twenty-three are in the `:forge_write_api` scope at `router.ex:259`, alongside the nine repository and import routes the CLI already uses.

| Method and path | Controller action | Line | GitHub-compatible path? |
| --- | --- | --- | --- |
| `POST /repos/:owner/:repo/issues` | `IssueController.create` | `:271` | yes |
| `PUT /repos/:owner/:repo/issues/:issue_number` | `IssueController.update` | `:272` | no — GitHub uses `PATCH` only |
| `PATCH /repos/:owner/:repo/issues/:issue_number` | `IssueController.update` | `:273` | yes |
| `POST /repos/:owner/:repo/issues/:issue_number/comments` | `CommentController.create` | `:274` | yes |
| `PUT /repos/:owner/:repo/issues/comments/:id` | `CommentController.update` | `:275` | no |
| `PATCH /repos/:owner/:repo/issues/comments/:id` | `CommentController.update` | `:276` | yes |
| `DELETE /repos/:owner/:repo/issues/comments/:id` | `CommentController.delete` | `:277` | yes |
| `POST /repos/:owner/:repo/issues/:issue_number/labels` | `IssueLabelController.create` | `:278` | yes |
| `DELETE /repos/:owner/:repo/issues/:issue_number/labels/:name` | `IssueLabelController.delete` | `:279` | yes |
| `POST /repos/:owner/:repo/issues/:issue_number/assignees` | `IssueAssigneeController.create` | `:280` | yes |
| `DELETE /repos/:owner/:repo/issues/:issue_number/assignees` | `IssueAssigneeController.delete` | `:281` | yes |
| `POST /repos/:owner/:repo/labels` | `LabelController.create` | `:282` | yes |
| `PUT /repos/:owner/:repo/labels/:name` | `LabelController.update` | `:283` | no |
| `PATCH /repos/:owner/:repo/labels/:name` | `LabelController.update` | `:284` | yes |
| `DELETE /repos/:owner/:repo/labels/:name` | `LabelController.delete` | `:285` | yes |
| `POST /repos/:owner/:repo/milestones` | `MilestoneController.create` | `:286` | yes |
| `PUT /repos/:owner/:repo/milestones/:milestone_number` | `MilestoneController.update` | `:287` | no |
| `PATCH /repos/:owner/:repo/milestones/:milestone_number` | `MilestoneController.update` | `:288` | yes |
| `DELETE /repos/:owner/:repo/milestones/:milestone_number` | `MilestoneController.delete` | `:289` | yes |
| `POST /:owner/projectsV2` | `ProjectController.create` | `:290` | no, and inconsistent with its own reads |
| `POST /users/:username/projectsV2/:project_number/items` | `ProjectController.create_item` | `:291` | no |
| `POST /users/:username/projectsV2/:project_number/fields` | `ProjectController.create_field` | `:292` | no |
| `PATCH /users/:username/projectsV2/:project_number/items/:item_id` | `ProjectController.update_item` | `:294` | no |

Note `router.ex:290`: project creation lives at `/api/v3/:owner/projectsV2` while every project read and every other project write lives under `/api/v3/users/:username/projectsV2`. A generated client would faithfully reproduce that inconsistency; a human writing a command would notice it.

No routed action is a stub. Every one of the fifty reaches a real context function.

There is **no** search endpoint, no `GET /api/v3/users/:username`, no `GET /api/v3/orgs/:org`, no issue events, reactions, or timeline, and no `/api/v3/meta`.

### 2.4 Where "GitHub-compatible" stops being true

The paths are largely GitHub-shaped. The bodies are not, in one systematic way that matters for any plan involving generated clients: **every list response is wrapped in a named envelope**, where GitHub returns a bare array.

`GET /repos/:owner/:repo/issues` returns `{"issues": [...]}` (`lib/openagents_web/controllers/issue_json.ex:6`), and the same pattern holds for labels (`label_json.ex:6`), milestones (`milestone_json.ex:6`), comments (`comment_json.ex:6`), and projects (`project_json.ex:6`). Repository lists use a third shape again, `{"repositories": [...], "next_cursor": …}` (`priv/api-contracts/repositories-v1.json:56` describes it; the CLI decodes it at `packages/openagents-cli/src/api-contract.ts:56` in the monorepo).

Two further deviations worth recording:

- **Two error dialects.** The repository endpoints emit `{code, message, request_id}` with a fixed vocabulary of twenty stable codes (`priv/api-contracts/repositories-v1.json:74`), and the CLI decodes exactly that (`packages/openagents-cli/src/repository-client.ts:157` in the monorepo). The issues endpoints emit `{"message": "Not Found"}` for 404 and `{"errors": {field => [messages]}}` for 422 (`issue_controller.ex:44`, `issue_json.ex:14`). The CLI's decoder tolerates the 404 because it reads a `message` key, and degrades to the generic `The API returned HTTP 422.` for the validation case, discarding the field errors.
- **Hardcoded origin in generated URLs.** `issue_json.ex:38` builds `html_url` and `url` from the literal `https://openagents.com`, so a staging response points at production.

The practical consequence: you cannot point GitHub's own OpenAPI description, or a client generated from it, at this server and expect it to work. The surface is GitHub-*inspired*, not GitHub-*compatible*, and any generated client has to be generated from this repository's own description of itself.

---

## 3. The gap

Thirty-nine of fifty routes have no CLI surface. Not "partial" — zero. Every row in section 2.2 and section 2.3 is uncovered.

### 3.1 Ranked by what a person managing issues from a terminal reaches for first

| Rank | What you want to type | Endpoints behind it | Blocked by anything beyond the missing command? |
| --- | --- | --- | --- |
| 1 | `openagents issue list` | `GET .../issues` (`router.ex:235`) | Yes — public repositories only, unpaginated, `state` is the only filter |
| 2 | `openagents issue view 41` | `GET .../issues/:n`, `GET .../issues/:n/comments` (`:236`, `:237`) | Yes — public repositories only |
| 3 | `openagents issue create` | `POST .../issues` (`:271`) | No |
| 4 | `openagents issue close` / `reopen` / `edit` | `PATCH .../issues/:n` (`:273`) | No — `state` is castable (`lib/openagents/issues/issue.ex:32`) and covered by `test/openagents_web/controllers/issue_controller_test.exs:92` |
| 5 | `openagents issue comment 41` | `POST .../issues/:n/comments` (`:274`) | No |
| 6 | `openagents issue label add` / `remove` | `POST`, `DELETE .../issues/:n/labels` (`:278`, `:279`) | No |
| 7 | `openagents issue assign` / `unassign` | `POST`, `DELETE .../issues/:n/assignees` (`:280`, `:281`) | No |
| 8 | `openagents label list` / `create` / `edit` / `delete` | `router.ex:241`, `:242`, `:282`, `:284`, `:285` | Reads are public-only |
| 9 | `openagents milestone` CRUD | `router.ex:243`, `:244`, `:286`, `:288`, `:289` | Reads are public-only |
| 10 | `openagents project list` / `view` / `item add` / `item move` | `router.ex:247`–`:250`, `:290`–`:296` | Yes — the whole surface is pinned to one repository |

Ranks 3 through 7 are pure CLI work: the endpoints exist, take a bearer token, and enforce membership correctly. Ranks 1, 2, 8, and 9 need a server change first or they only work on public repositories. Rank 10 needs a server change that is larger than a command.

### 3.2 Three gaps that no CLI command can close

**The private-repository read asymmetry.** This is the one that matters most, because it defeats the use case rather than delaying it. Consider a private repository you own:

```
POST /api/v3/repos/you/private/issues        → 201, issue #1 in the body
GET  /api/v3/repos/you/private/issues/1      → 404 {"message":"Not Found"}
```

The write path resolves through `Repositories.get_writable_by_path!/3`, which joins on membership and filters on `lifecycle_state` but never on `visibility` (`lib/openagents/repositories.ex:111`). The read path runs in a pipeline that discards the bearer token entirely (`router.ex:230`) and then filters `visibility == "public"` in the query (`lib/openagents/issues.ex:159`, `lib/openagents/repositories.ex:68`). The repository already has the mechanism to fix this — `Repositories.get_visible_by_path!/3` (`repositories.ex:72`) and the `:optional_forge_api` pipeline that `GET /api/v3/repos/:owner/:repo` uses (`router.ex:254`).

**No pagination, one filter.** `IssueController.index` passes only `state` into `Issues.list_issues/2` (`issue_controller.ex:10`), which returns every match with no limit (`issues.ex:26`). The paginated, filterable query the web interface uses is right beside it and unreachable from the API: `Issues.list_issues_page/2` supports `:state`, `:label`, `:assignee`, `:milestone`, `:q`, and `:page` (`issues.ex:40`). A repository with two thousand issues returns two thousand issues.

**Projects are one repository's projects.** Both project read functions scope to `Repositories.initial_repository!()` (`lib/openagents/projects.ex:26`, `:131`), which resolves the module constants `OpenAgentsInc` and `openagents.com` (`lib/openagents/repositories.ex:22`). `ProjectController.create` checks that the `:owner` segment matches the caller's GitHub login and then discards it, resolving `Repositories.initial_path()` for the repository the project attaches to (`project_controller.ex:17`, `:21`). A cross-repository paginated query exists in the context for the web interface (`projects.ex:43`) and the API does not use it. Building `openagents project` commands on the surface as it stands would ship a command that silently only ever addresses one repository.

---

## 4. How the coverage should be produced

This is the part worth being slow about, because the answer determines the cost of every future endpoint.

### 4.1 What exists today, and what it does not check

**No OpenAPI document exists.** There is no `open_api_spex`, `phoenix_swagger`, or equivalent in `mix.exs`. The single mention of OpenAPI anywhere in the repository is a future intention in a planning document: `docs/repository-creation-and-openagents-cli-spec.md:1008` proposes publishing "a bounded OpenAPI document or equivalent JSON Schema artifact for the repository endpoints" as a step in client-contract synchronization. There is no `.well-known` route and no capability manifest.

**A hand-written contract artifact exists**, and it is worth understanding precisely because it is the seed of any answer here. `priv/api-contracts/repositories-v1.json` is 99 lines, served by `ApiContractController.repositories_v1` which reads the file at request time and sets an ETag from its SHA-256 (`lib/openagents_web/controllers/api_contract_controller.ex:8`). It carries:

- an `endpoints` map of eleven `name → "METHOD /path"` strings (`:18`), covering repositories, imports, the authenticated user, and device authorization, and **nothing** from the issues or projects families;
- authentication metadata — bearer, `oa_pat_` prefix, `forge:write` scope (`:4`);
- which four `POST`s require `Idempotency-Key` (`:8`);
- flat lists of required field *names* per object, plus enum values (`:33`–`:66`);
- pagination parameter names (`:68`) and the error shape with twenty stable codes (`:74`).

What it does not carry: any type, any request body, any response body, any status code, any relationship between an endpoint and a schema. It is a vocabulary agreement, not a description. **You could not generate a client from it.** It also is not generated from anything — it is a checked-in file that a human edits.

**An executable route inventory exists**, and this is the genuinely promising asset. `lib/openagents_web/route_authority.ex` walks `OpenAgentsWeb.Router.__routes__/0` and classifies every route with a class, principal, scope, and mutation flag (`:59`), and `test/openagents_web/route_authority_test.exs:6` fails if any route lacks them. The derivation this repository would need already runs in CI.

But it also demonstrates the failure mode that any derived-document plan has to design against, twice over:

- Its `@moduledoc` states "The classifier intentionally has no catch-all policy" (`route_authority.ex:5`), and for `/api/v3` there are in fact two catch-alls: any unmatched `GET` becomes `:public_read` and anything else becomes `:authenticated_api` with scope `forge:write` (`:195`, `:198`). A new `/api/v3` route is classified automatically, so **adding an endpoint cannot fail this test**.
- It declares scope `forge:read` for `GET /api/v3/user`, `GET /api/v3/user/repos`, and `GET /api/v3/repository-imports/:id` (`:184`). Those three routes are in the `:forge_write_api` pipeline (`router.ex:260`, `:262`, `:263`, `:269`), which requires `forge:write`, and `forge:read` is not a scope that exists anywhere in the system (`lib/openagents/api_tokens.ex:12`). The label is derived from a hand-written policy function that nothing checks against the plug it describes.

So the state of the art here is: one derivation that runs but does not constrain, and one description that constrains nothing and describes 22% of the surface.

### 4.2 The four options, honestly

**Option A — keep hand-writing commands (status quo).**

*Cost.* Measured from the existing code: `repository-client.ts` is 595 lines for nine operations (about 66 lines each), and `cli.ts` is 803 lines for twelve leaf commands (about 67 lines each), in the `openagents` monorepo. Thirty-nine endpoints at that rate is roughly 2,600 lines of client plus perhaps 1,300 of command surface before tests — which would roughly double a 3,452-line codebase. In a second repository, in a second language, on a second release cadence, published to npm.

*What it buys.* The best possible user experience at every command, because a human decides what `issue list` prints, that `-R owner/repo` falls back to the origin remote, that `41` means issue 41, and that `issue create` opens `$EDITOR`.

*What it forecloses.* Nothing. Hand-written commands compose with every other option.

*Where it breaks down.* At exactly the volume in front of us. The marginal endpoint is never worth the marginal pull request, so coverage stalls where it is now — which is the observed outcome, since the API has had these 39 routes long enough to accumulate full controller test files for all of them.

*Drift.* Silent, and this is not hypothetical: it is today's behavior. Nothing fails when an endpoint changes. Both contract tests stay green. The user finds out.

**Option B — generate a typed client, hand-write the command surface.**

Generate the transport and schema layer from a machine-readable description of this API; keep `cli.ts` hand-written on top of it.

*Cost.* Dominated by the prerequisite. The description does not exist and must be produced, and — the important part — it must be **derived** from the router rather than maintained beside it, or you have moved the drift one layer up and added a file to forget. Paths, methods, and pipeline-derived auth are mechanically derivable from `Router.__routes__/0`, as `RouteAuthority` proves. Response schemas are the hard half: they live in the `*_json.ex` view functions, and six controllers render inline with `json/2` and have no view module at all (`assignee_controller.ex`, `issue_assignee_controller.ex`, `issue_label_controller.ex`, `forge_user_controller.ex`, `device_authorization_controller.ex`, `repository_controller.ex`). Deriving the response shape for those means restructuring them first.

*What it buys.* The 66-lines-per-operation client layer mostly disappears, and — the real prize — a server-side schema change becomes a **compile error in the CLI** on regeneration, before anyone ships.

*What it forecloses.* Little. A generated method can always be wrapped or bypassed by hand.

*Where it breaks down.* When the description lies. A generated client inherits every inaccuracy of its source with total confidence, and the two demonstrated inaccuracies in this repository — the stale `repo delete` line in the command reference and the `forge:read` label in the route inventory — are both in hand-maintained descriptions.

*Drift.* Loud, conditionally. Regeneration diffs, and CI fails on an uncommitted diff — but only for the parts the description actually covers, and only if the description is derived. A hand-maintained OpenAPI file gives you a *feeling* of drift detection and no drift detection.

**Option C — generate the commands too.**

*Cost.* High fixed cost (a generator, plus naming and flag conventions), near-zero marginal cost.

*What it buys.* All 50 endpoints covered in one step, and every future endpoint free.

*What it forecloses.* The product. Generated command surfaces are worst precisely where usage is highest. A generator produces `openagents repos-owner-repo-issues-list --owner X --repo Y --issue-number 41`. It will not infer `-R owner/repo` from the origin remote — which this CLI already does, at `cli.ts:695` — it will not decide that a bare `41` means issue 41, it will not open an editor for a body, it will not render a table, it will not ask before a destructive call the way `repo delete` demands `--yes` (`cli.ts:761`), and it will faithfully expose both the `PUT` and the `PATCH` spelling of every update route because the router has both. It will also expose `POST /api/v3/:owner/projectsV2` under a different noun than every other project command, because that is what the router says.

*Where it breaks down.* The first day a person uses it for real work.

*Drift.* Loud — the regeneration diff — but with a cost the other options do not have: the CLI's public interface becomes generator output, so a path rename on the server renames a user's command.

**Option D — a generic passthrough, the way `gh api` works.**

```
openagents api /repos/OpenAgentsInc/openagents.com/issues
openagents api -X POST -f title="…" -f body="…" /repos/o/r/issues
```

*Cost.* One command. The CLI already owns every part except argument parsing: endpoint resolution and profiles (`src/endpoint.ts`), the credential store and `OPENAGENTS_TOKEN` fallback (`src/session.ts:30`), a transport that takes an arbitrary method, path, and JSON body (`src/api-transport.ts:82`), JSON and human output modes (`src/output.ts`), and an error decoder with exit-code mapping (`src/errors.ts`). Estimate 150–250 lines including tests — the size of one existing `repo` subcommand.

*What it buys.* Complete endpoint coverage on the day it lands, permanently, at zero marginal cost per endpoint — **including endpoints that do not exist yet**. It also decouples the two release trains: a new server endpoint becomes reachable from the terminal without an npm publish.

*What it forecloses.* Nothing. `gh` ships `gh issue` and `gh api` side by side and has for years; the passthrough is where power users and scripts go, and the named commands are where everyone else stays.

*Where it breaks down.* It is not issue management, it is authenticated `curl` with sane defaults. The caller has to know the path, spell the JSON, and read the envelope. Nobody triages with it.

*Drift.* None to detect, because it makes no claims — its correctness does not depend on any description of the API. That is its strength and, symmetrically, its limit: it will also never warn you that the server broke a shape.

### 4.3 Recommendation

**Ship D now, do A for the top ten commands, invest in B only once the description is derived and verified, and never do C.**

The reasoning, in order of confidence:

1. **Never C.** The CLI's entire reason to exist is that it is nicer than `curl`. Generating its command surface trades away the only thing it adds, to save work on commands nobody types. The `gh` precedent is decisive here — GitHub has the largest OpenAPI description in public software and still hand-writes `gh issue`.

2. **D first, because it is the cheapest thing that answers the owner's actual question.** "So I can do issues and projects management from the CLI" is satisfied for scripting and one-off work by roughly 200 lines of code, in one repository, with no server change and no coordination. Everything after it is an ergonomics upgrade on a capability that already exists rather than a capability that does not.

3. **A for the top ten.** Thirty-nine hand-written commands is the trap; ten is a week. The ranking in section 3.1 is the list, and it is short because issue work is concentrated: list, view, create, close, comment, label, assign. Those get hand-written UX because that is where UX pays.

4. **B is right, but its prerequisite is the whole job, and the prerequisite is worth doing on its own merits.** The rule that makes it worth anything: **generate the document from the router, not beside it.** `RouteAuthority` already walks `Router.__routes__/0`; extending that walk to emit paths, methods, pipeline-derived auth, and — where a `*_json.ex` module exists — the response key set, produces a document that cannot drift on the parts it covers, because CI fails on an uncommitted regeneration diff. Then generate the CLI's schema layer from it.

There is a cheaper move available immediately that is worth naming separately, because it converts today's silence into a red build for about twenty lines per repository, and it is a prerequisite for trusting any of the above:

- **In this repository:** assert that every route in `Router.__routes__/0` whose path starts with `/api/v3` appears in `priv/api-contracts/repositories-v1.json`. Today that test fails immediately on 39 routes, which is the correct first result — it converts "the contract covers 22% of the API" from a fact nobody knows into a fact the build states.
- **In the `openagents` monorepo:** make the CLI's contract check fetch `/api/contracts/repositories-v1.json` from the configured origin and compare it to the vendored copy, rather than hashing the vendored copy against a constant in the same package (`packages/openagents-cli/test/api-contract.test.ts:13`). Run it against staging in the CLI's `verify` script. Today it would pass, because the two files happen to be identical; tomorrow it is the only thing that would notice they are not.

The order matters. The passthrough removes the urgency, the drift tests remove the silence, the hand-written commands do the ergonomics, and the derived document — which is real work with a real restructuring prerequisite — happens once the surface has stopped moving, not while it is moving fastest.

---

## 5. A staged path to parity

Each stage is independently shippable and independently useful. Sizes are rough and relative.

### Stage 1 — Ship `openagents api` (CLI repository only, small) — SHIPPED 2026-08-21

Add one leaf command taking a path, an optional `-X/--method`, repeated `-f key=value` body fields or `--input -` for raw JSON, and honoring the existing `--json` and profile flags. **Seam:** `packages/openagents-cli/src/cli.ts` plus a thin passthrough client in the `openagents` monorepo; no schema, no server change. **Size:** 150–250 lines with tests. **Effect:** every one of the 50 endpoints becomes reachable from a terminal, and every future endpoint arrives free. Also update `docs/openagents-cli/command-reference.md:171`, which currently lists a generic API command among the things the release does not provide, and fix the stale `repo delete` claim on the same line while you are in there.

**What shipped.** `eaa2aa1006` in the `openagents` monorepo, released as
`@openagentsinc/cli@0.2.1`. The command is `openagents api <path>`: a path
without a leading slash resolves under `/api/v3/`, an absolute path must start
with `/api/` and stay on the selected origin, `-X` covers GET, POST, PATCH,
PUT, and DELETE, `-f key=value` repeats into a JSON object, `--input <file|->`
takes a whole body from a file or standard input, `-H` repeats headers and
refuses to overwrite `authorization`, and `--profile`/`--api-url`/`--json`
behave as they do elsewhere. The body goes to stdout as JSON so it pipes into
`jq`; a non-2xx writes status, body, and request id to stderr and exits
non-zero, keeping stdout clean. 32 tests, and `ApiTransport` gained PATCH and
PUT, which it had never carried (`api-transport.ts:8`) — the audit missed that
the transport could not express the issue-update route at all.

**What it cost to publish, which is worth recording.** `0.2.0` went to npm with
`"effect": "catalog:"` in its dependencies and installed nowhere. The monorepo
is a pnpm workspace: pnpm resolves catalog references while packing, `npm
publish` does not, and the tarball reaches the registry looking healthy. npm
refuses unpublishing outside its window, so `0.2.0` could only be deprecated
and replaced. The rule now lives in that repository's `AGENTS.md` and
`docs/DEPLOYMENT.md`, along with the check that catches it in seconds:
install the published version from the registry rather than reading the
publish output.

**What Stage 1 does not fix**, both from section 3.2 and both server-side:
reading an issue back from a private repository still answers 404, because the
read pipeline discards the bearer token, so the passthrough can create an issue
it cannot then show you. And the `projectsV2` routes still resolve through
`Repositories.initial_repository!/0`, so `openagents api users/me/projectsV2`
returns real-looking JSON describing one hardcoded repository rather than
yours. A passthrough is faithful by design: it exposes those surfaces exactly
as they are, including where they are wrong.

### Stage 2 — Let an authenticated caller read their own private issues (this repository only, medium)

Move the issue, comment, label, milestone, and assignee read routes (`router.ex:235`–`:246`) from `pipe_through :api` into `pipe_through :optional_forge_api`, and change the resolution calls in `IssueController`, `CommentController`, `IssueLabelController`, `IssueAssigneeController`, `LabelController`, `MilestoneController`, and `AssigneeController` from `Repositories.get_public_by_path!/2` to `Repositories.get_visible_by_path!/3`, threading `conn.assigns.current_user` (which the optional plug sets to `nil` for anonymous callers). The visibility filters inside `Issues.get_issue_by_path!/3` (`issues.ex:159`), `Issues.get_comment_by_path!/3`, `Labels.get_label_by_path!/3`, and `Milestones.get_milestone_by_path!/3` need the same treatment. **Seam:** router pipelines, ten or so controller call sites, four context queries, and the `RouteAuthority` policy at `route_authority.ex:184`, whose `:public_read` classification for these paths becomes wrong. **Size:** medium; mechanical but wide, and every one of these controllers already has a test file to extend. **Effect:** additive and backward-compatible — anonymous callers see exactly what they see today; the change is that a bearer token now widens the result instead of being discarded. Without this, sections 3.1 ranks 1, 2, 8, and 9 only ever work on public repositories, so this gates most of the value of Stage 3.

### Stage 3 — The five commands that carry the traffic (CLI repository only, medium)

`issue list`, `issue view`, `issue create`, `issue close` / `reopen`, `issue comment`. Hand-written, with `-R owner/repo` falling back to the origin remote the way `repo view` already does (`cli.ts:695`), bare integers for issue numbers, `--json` for scripting, and a table for humans. **Seam:** new `issue-client.ts` and schema additions in `api-contract.ts` in the `openagents` monorepo, on top of Stage 2's reads. **Size:** medium — roughly five client methods and five commands at the codebase's observed 66 lines each, plus tests.

### Stage 4 — Pagination and filters on the API list endpoints (this repository only, small)

Change `IssueController.index` to call `Issues.list_issues_page/2` and pass through `label`, `assignee`, `milestone`, `q`, and `page` (`issue_controller.ex:10`; the query already supports all of them at `issues.ex:40`). Decide the pagination contract deliberately — the repository list already uses opaque cursors (`next_cursor`, `after`, `priv/api-contracts/repositories-v1.json:68`) while the issue context is offset-paged, and shipping a third convention would be a mistake. **Size:** small on the server; unlocks `issue list -l bug -a me` in the CLI without further server work.

### Stage 5 — Derive the contract document, and fail CI on divergence (both repositories, large)

Extend the `RouteAuthority` walk to emit the full `/api/v3` surface — path, method, pipeline-derived auth and scope, and response key sets where a `*_json.ex` view exists — into the published contract artifact, and add the two drift tests from section 4.3. Restructure the six controllers that render inline with `json/2` into view modules first, or accept that their responses stay undescribed. **Size:** large, and it is the only stage that should wait.

### Stage 6 — Labels, milestones, and assignee commands (CLI repository, medium)

Ranks 6 through 9. Straightforward once Stage 3 has established the client and command shapes.

### Stage 7 — Make projects addressable, then build project commands (this repository, then CLI; large)

Unpin the project surface from `Repositories.initial_repository!()` (`projects.ex:26`, `:131`), make `ProjectController.create` honor its own `:owner` segment instead of resolving `Repositories.initial_path()` (`project_controller.ex:21`), reconcile `POST /api/v3/:owner/projectsV2` with the `/users/:username/projectsV2` shape every other project route uses (`router.ex:290`), and give the project reads a visibility predicate. Only then are there project commands worth writing. **Size:** large, and it is genuinely a redesign rather than a port.

### What makes issue management usable this week versus complete

Stages 1 and 2 make it usable — the passthrough covers everything, and the read fix makes private repositories work. Stage 3 makes it pleasant. Stages 4 through 7 make it complete. Stage 5 is what makes it stay correct, and it is deliberately not early: deriving a document from a surface that Stages 2, 4, and 7 are still reshaping means regenerating it three times.

### The cross-repository cost, and how to handle it

The CLI ships from the `openagents` monorepo as `@openagentsinc/cli`, published to npm at version `0.1.7`, with its own `verify` pipeline (format, lint, typecheck, test, build) and its own release cadence. This repository deploys on its own. Four rules keep that from becoming a coordination tax:

1. **Order every stage server-first.** A released CLI in a user's `$PATH` will meet a deployed server. The reverse — a server change that only works with an unreleased CLI — creates a window where the published tool is broken. Stages 2, 4, and 7 land and deploy before the CLI stage that depends on them.
2. **Never require simultaneous merges.** Each stage above touches exactly one repository, by construction. Stage 2 is additive: anonymous reads keep their current behavior, so no released CLI breaks.
3. **Use Stage 1 to buy slack.** The passthrough's real strategic value is that it decouples the release trains — a new endpoint is reachable from the terminal the moment it deploys, with no npm publish, so nothing is ever blocked on a CLI release again.
4. **Make the one shared artifact a build failure rather than a memory.** `priv/api-contracts/repositories-v1.json` and its vendored twin at `packages/openagents-cli/contracts/repositories-v1.json` are the only file that must change in both repositories together. Generate it here, vendor it there, and have the CLI's CI fetch and compare (section 4.3). That converts a coordination problem into a named, failing test in a specific repository — which is the only form of cross-repository discipline that survives contact with two release cadences.

---

## 6. What is worth preserving

Not everything here needs changing, and two decisions are better than they look:

- **The bearer-token boundary is clean.** One credential family, one plug, one scope check, constant-time comparison, revocation and expiry honored, `last_used_at` bumped (`lib/openagents/api_tokens.ex:52`). The CLI's device flow and credential store are built to match it, and the `--profile` and `--api-url` split means a single binary talks to production, staging, and a local server without reconfiguration (`packages/openagents-cli/src/endpoint.ts:8` in the `openagents` monorepo).
- **`RouteAuthority` is the right instinct in the wrong strength.** An executable inventory that walks the real router and fails a test is exactly the mechanism a derived contract needs. It needs its two catch-alls narrowed and its scope labels checked against the pipelines that enforce them, not replacing.
- **The CLI's decode-on-every-response discipline is worth keeping under any generation strategy.** A `ContractError` naming the operation (`packages/openagents-cli/src/repository-client.ts:227`) is a much better failure than silently reading `undefined` off a changed field.

---

## 7. Open questions

- **Does the published npm package's vendored contract match the deployed server's?** Both working copies hash to `5be86539258c…`, but a stale local build in the CLI's gitignored `dist/` carries `9355cac5191e…`, which suggests the constant has changed at least once. Settle with `npm pack @openagentsinc/cli@0.1.7`, then `shasum -a 256 package/contracts/repositories-v1.json`, and compare against `curl -s https://openagents.com/api/contracts/repositories-v1.json | shasum -a 256`.
- **Is the absence of any visibility predicate on the four project reads intentional?** `ProjectController.index`, `show`, `items`, and `fields` apply none (`project_controller.ex:8`, `:41`, `:53`, `:144`), unlike every sibling controller. The pinning to one repository may be masking it. A test asserting that a project on a private repository is not listed anonymously would settle the policy either way.
- **Is `forge:read` in `route_authority.ex:184` an aspiration or a mistake?** If the intent is a read-only token scope, it needs adding to `@allowed_scopes` (`lib/openagents/api_tokens.ex:12`) and a `:forge_read_api` pipeline; if not, the label should say `forge:write`. Settle by asking whether a token that can file an issue should also be able to delete a repository, which is today's answer.
- **Does anything consume the `{"issues": [...]}` envelope, or could the list endpoints move to bare arrays for GitHub compatibility?** Settle by grepping the `openagents` monorepo and this repository's web layer for consumers before Stage 5 freezes the shape into a generated document.
- **What is the intended pagination convention across the whole API?** Repositories use opaque cursors and issues are offset-paged internally. Stage 4 has to pick one, and the choice belongs to whoever owns the contract document, not to the first endpoint that needs a page.
