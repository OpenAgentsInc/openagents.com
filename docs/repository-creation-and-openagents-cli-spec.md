# Repository creation, GitHub import, and OpenAgents CLI specification

Date: 2026-08-20

Status: Implemented for local verification; staging release remains gated

## Purpose

Allow an authenticated person or agent to create an OpenAgents-hosted Git
repository, import an existing GitHub repository once, push and pull with
standard Git, and manage the repository through the browser or a first-party
CLI.

This specification uses Cursor Origin as product research. It adopts the useful
interaction patterns without treating Origin's API, implementation, pricing,
team model, or terminology as an OpenAgents contract.

## Implementation homes

| Concern | Owning repository |
| --- | --- |
| Repository, namespace, membership, and provisioning authority | `openagents.com` Phoenix application |
| REST API, browser authorization, Git HTTP, and web interface | `openagents.com` Phoenix application |
| CLI source, release tooling, and terminal tests | `openagents` Effect monorepo |
| Public API contract | Authored and tested by `openagents.com`; consumed as a pinned client contract by the CLI |

The Phoenix application remains the server authority. The CLI must not create a
second repository database or infer authorization from local Git state.

## Related documents

- [OpenAgents architecture](architecture.md)
- [GitHub-shaped Issues and Projects API assessment](github-api-issues-projects-assessment.md)
- [Issues and Projects UI roadmap](issues-projects-ui-roadmap.md)
- [Repository creation and CLI implementation roadmap](repository-creation-cli-implementation-roadmap.md)
- [API authentication](api-authentication.md)
- [GitHub authentication and token lifecycle](github-auth-plan.md)
- [ADR 0007: Cut over to forge-canonical source control after proof](decisions/0007-cut-over-to-forge-canonical-source-control-after-proof.md)
- [Integration hardening and staging readiness recommendations](2026-08-20-integration-hardening-and-staging-readiness-recommendations.md)

## Baseline before implementation

Before this slice, the application already had several parts of the required
domain:

- `OpenAgents.Repositories.Repository` stores a UUID, owner, name, visibility,
  and default branch.
- `OpenAgents.Repositories.Membership` grants repository roles.
- Issues, labels, milestones, comments, projects, and project items carry a
  repository ID and enforce cross-repository isolation.
- `OpenAgents.Repositories.create_repository/1` creates a database row for
  tests and internal callers.
- The forge serves Git smart HTTP, stores a durable write-ahead log, maintains
  reconstructable bare-repository caches, and exposes bounded code-browsing
  projections.
- The first-party `oa_pat_...` token supports the `forge:write` scope for
  GitHub-shaped API mutations.
- The server retains the signed-in user's encrypted GitHub `repo` grant and has
  bounded adapters that list repositories and read repository content.

The baseline did not provide a user repository lifecycle:

- No browser route or public API creates or imports a repository.
- No API lists every repository the current user can access.
- The signed-in dashboard loads only `OpenAgentsInc/openagents.com`.
- Git repository admission comes from `OPENAGENTS_FORGE_REPOSITORIES`, not the
  repository database.
- Forge storage and visibility use repository names from runtime configuration,
  while Issues and Projects use stable repository UUIDs from PostgreSQL.
- Git HTTP paths contain a repository name without an owner namespace.
- Git HTTP accepts an operator credential or paired-machine credential without
  checking an ordinary user's repository membership.
- The public code route has a literal `OpenAgentsInc` owner segment.

Creating a database row alone therefore did not create a usable hosted Git
repository. The implementation described below now joins the database,
provisioning, WAL, Git HTTP, browser, and CLI paths. The implementation roadmap
tracks the remaining local end-to-end and staging evidence.

## Product decisions

The first release follows these decisions:

- A repository belongs to a GitHub-backed user or organization namespace.
- OpenAgents uses the same user and organization names that GitHub reports. It
  keys each namespace by GitHub's immutable numeric account ID instead of a
  mutable login string.
- A namespace is available only through GitHub sign-in and the retained GitHub
  connection. Custom OpenAgents namespaces follow later.
- Repository visibility is `private` or `public`. The `internal` visibility
  from Origin requires a team model and is out of scope.
- New repositories default to `private` and use `main` as the default branch.
- PostgreSQL owns repository identity, lifecycle, membership, and policy.
- The forge write-ahead log owns durable Git ref and object history.
- A local bare repository is a cache that the forge can reconstruct.
- Repository creation never grants build, promotion, hot-load, deployment, or
  operator authority.
- Standard Git remains the data-plane client. The CLI orchestrates API and Git
  commands but does not replace Git.
- The CLI uses the server-provided clone URL instead of constructing one from a
  hard-coded host.
- The first release imports Git repository history, branches, and tags from
  GitHub as a one-time copy. It does not maintain a mirror or two-way sync.
- Pull requests, rulesets, SSH keys, apps, and OpenAgents-native team sharing
  remain future slices.

## Goals

The repository and import slice must support these outcomes:

- Your OpenAgents namespaces match your GitHub user and eligible GitHub
  organization namespaces.
- You can create an empty repository from the browser.
- You can create the same repository with `openagents repo create`.
- You can import a GitHub repository from the browser or with
  `openagents repo import`.
- You can list and view repositories that you can access.
- You can clone, fetch, push, and pull with standard Git.
- A public repository supports anonymous read access.
- A private repository never reveals its existence to an unauthorized caller.
- An agent can complete the flow without parsing prose or answering an
  interactive prompt when it already has an environment credential.
- Repeated create requests do not create duplicate database, storage, or
  membership records.
- Provisioning failures remain durable, inspectable, retryable, and bounded.

## Non-goals for the first slice

The first slice does not include:

- Continuous or bidirectional GitHub synchronization after a one-time import.
- Pull requests, reviews, merge queues, rulesets, or branch protection.
- OpenAgents-native teams, custom namespaces, organization administration, or
  `internal` visibility.
- Repository transfer, rename, archive, restore, or deletion.
- SSH Git transport or SSH-key management.
- Code search across repositories.
- Third-party application installation.
- Billing or plan enforcement.
- Automatic deployment of code pushed to a user repository.
- Complete GitHub or Origin API compatibility.

These omissions reserve future command groups without making them current
product promises.

## Origin pattern adaptation

| Origin pattern | OpenAgents disposition |
| --- | --- |
| Browser-assisted CLI login | Adopt with an OpenAgents-owned device authorization flow |
| Git credential-helper setup | Adopt for the exact admitted OpenAgents host |
| `repo create`, `list`, `view`, and `clone` | Adopt in the first release |
| Repository inference from the `origin` remote | Adopt with strict host and path validation |
| Human and JSON output | Adopt as separate output contracts |
| Endpoint override | Adopt for local development and staging |
| Repository deletion | Defer until recovery and retention semantics exist |
| GitHub mirror creation | Adapt as a receipted one-time import; defer continuous synchronization |
| Pull requests and rulesets | Defer until their server domains exist |
| SSH keys | Defer; use HTTPS and the Git credential helper first |
| Generic authenticated API command | Reserve until endpoint and secret-redaction behavior is specified |
| Self-update and shell completion | Defer until CLI packaging and release channels are admitted |

Origin uses team-owned codebases and `internal` visibility. OpenAgents starts
with GitHub-backed user and organization namespaces and `public` or `private`
repositories because those concepts match the existing identity and repository
domains.

## Namespace model

GitHub supplies the namespace system for the first release. A person signs in
with GitHub and sees the same user login and eligible organization logins as
repository owners in OpenAgents. OpenAgents does not ask the person to claim a
second name.

Key a namespace by GitHub's immutable numeric account ID and account type. Treat
the GitHub login as a mutable URL and display projection.

Add a `namespaces` table with at least these fields:

| Field | Meaning |
| --- | --- |
| `id` | Stable OpenAgents UUID |
| `provider` | `github` in the first release |
| `provider_account_id` | Immutable GitHub numeric user or organization ID |
| `provider_node_id` | GitHub GraphQL node ID when supplied |
| `slug` | Current GitHub user or organization login |
| `slug_key` | Case-insensitive routing key |
| `kind` | `user` or `organization` |
| `owner_user_id` | Local user for a GitHub user namespace; `nil` for an organization |
| `provider_refreshed_at` | Time of the latest successful GitHub projection refresh |
| `state` | `active`, `suspended`, or `retired` |
| `inserted_at`, `updated_at` | Audit timestamps |

Enforce uniqueness on `{provider, provider_account_id, kind}` and on the active
case-insensitive slug. A client-supplied slug never establishes namespace
ownership.

The repository row gains a required `namespace_id`. Keep `owner` as a derived
API projection during migration only if compatibility requires it. New policy
checks must join through `namespace_id` and memberships instead of trusting the
projected owner string.

### GitHub namespace projection

Use this first-release flow:

1. On GitHub sign-in, upsert the GitHub user namespace from the verified numeric
   `github_id` and current `github_login` already stored on the local user.
2. Read the person's active GitHub organization memberships and upsert each
   organization from its numeric ID, node ID, and login.
3. Before an organization create or import, refresh that organization and the
   caller's active membership from GitHub.
4. Require the organization `admin` role for an empty repository creation in
   the first release.
5. For import, require read access to the source repository and authority to
   create the destination in the matching namespace. An organization import
   therefore requires the organization `admin` role under the first-release
   create policy, but it does not require admin permission on the source
   repository itself.
6. Add the creator as the OpenAgents repository `owner` in the repository
   transaction. Do not grant every GitHub organization member repository access
   until an organization access policy is specified.

GitHub logins can change while numeric account IDs remain stable. When GitHub
reports a rename, update the namespace slug and retain the prior slug in a
`namespace_aliases` table so existing web and Git URLs continue to resolve. An
alias can route to the stable namespace but cannot authorize a mutation.

Custom namespace claim, rename, transfer, and non-GitHub identity providers are
out of scope. They can evolve later without changing existing GitHub numeric
identity keys.

### Repository name rules

Use one validation rule in the browser, API, CLI, database, and Git transport:

- Normalize names to lowercase.
- Accept 1 through 64 ASCII characters.
- Require an ASCII letter or digit as the first character.
- Permit lowercase letters, digits, hyphens, underscores, and a dot followed by
  a letter or digit.
- Reserve platform route names and names required by Git internals.
- Enforce case-insensitive uniqueness within a namespace.

The existing forge name expression is the starting contract:

```text
^[a-z0-9](?:[a-z0-9_-]|\.(?=[a-z0-9])){0,63}$
```

The API returns the normalized name. The CLI reports normalization before it
changes local Git configuration.

## Repository lifecycle

Add a lifecycle state to each repository:

```text
provisioning -> ready
provisioning -> failed -> provisioning
ready -> suspended
suspended -> ready
```

Reserve `deleting` and `deleted` for the later deletion slice.

The repository row needs these additional attributes:

| Field | Meaning |
| --- | --- |
| `namespace_id` | Stable owner namespace |
| `created_by_user_id` | Audited creator |
| `description` | Optional bounded description |
| `lifecycle_state` | Provisioning and availability state |
| `provisioning_kind` | `empty` or `github_import` |
| `provision_error_code` | Bounded operational code without provider prose |
| `storage_key` | Stable UUID-derived forge storage key |
| `ready_at` | Time when Git operations became available |

Do not put a credential, filesystem path, bucket URL, or raw provisioning error
in the repository row.

### GitHub import record

A one-time import is a durable provisioning operation, not a mirror. Add a
`repository_imports` table with at least these fields:

| Field | Meaning |
| --- | --- |
| `id` | Stable import UUID |
| `repository_id` | Destination OpenAgents repository |
| `provider` | `github` |
| `source_repository_id` | Immutable GitHub numeric repository ID |
| `source_owner_id` | Immutable GitHub numeric user or organization ID |
| `source_full_name` | Bounded source owner and repository projection |
| `source_default_branch` | GitHub default branch observed at acceptance |
| `source_ref_digest` | Digest of the accepted branch and tag ref map |
| `source_head_sha` | Accepted default-branch head when one exists |
| `state` | `pending`, `running`, `completed`, or `failed` |
| `attempt_count` | Bounded retry count |
| `error_code` | Bounded operational code |
| `started_at`, `completed_at` | Import timing |

The record never stores a GitHub access token, authenticated clone URL, local
path, raw Git diagnostic, or repository content.

At import acceptance, resolve the source through the GitHub API and freeze the
advertised `refs/heads/*` and `refs/tags/*` map. The import copies the objects
reachable from that map and verifies the same ref digest before it marks the
destination ready. GitHub changes after the accepted snapshot are not part of
the import.

The first release imports standard Git history, branches, tags, the default
branch, and submodule pointer commits. It does not import GitHub Issues, pull
requests, reviews, Actions runs or secrets, releases, repository settings,
wikis, or Git LFS objects. Git LFS pointer files remain ordinary Git content;
the UI and CLI must warn when the source uses LFS.

### Authority split

The lifecycle preserves these authorities:

- PostgreSQL decides whether a repository exists, who can access it, and which
  lifecycle state it occupies.
- The forge write-ahead log durably records Git objects and refs.
- The bare Git directory is a node-local cache.
- Runtime configuration sets service limits and the separate deployment
  allowlist. It does not enumerate every hosted repository.

Split the current `forge_repos` concept into two concerns:

- A PostgreSQL-backed hosted-repository inventory for Git and product routes.
- An operator-owned deployable-repository allowlist for build, promotion,
  direct loading, relup, and rolling replacement.

A new user repository enters only the hosted-repository inventory. Repository
creation must never add it to the deployable-repository allowlist.

## Provisioning contract

Repository creation and GitHub import cross PostgreSQL, GitHub, and durable Git
storage, so one database transaction cannot complete the entire operation. Use
a transactional outbox and an idempotent provisioner.

1. Validate the authenticated principal, namespace, name, visibility, default
   branch, quota, and idempotency key.
2. For an import, resolve the GitHub source repository, immutable owner and
   repository IDs, caller permission, default branch, and accepted ref map with
   the caller's retained server-side GitHub grant.
3. In one PostgreSQL transaction, create the repository, add the creator as an
   `owner` member, insert the optional import record, and insert a provisioning
   outbox record.
4. Commit before any filesystem, Git, or object-store operation begins.
5. Initialize an empty durable WAL namespace using `repository.storage_key`.
6. For an import, fetch the accepted GitHub refs into an isolated temporary
   repository, verify the frozen ref digest, and ingest the accepted objects and
   refs into the destination WAL. Use a server-owned credential adapter that
   never places the GitHub token in a URL, argv, log, receipt, or repository
   configuration.
7. Materialize or initialize the bare-repository cache with the selected
   symbolic default branch.
8. Verify that upload-pack and receive-pack resolve the same repository UUID.
9. Mark the optional import `completed`, mark the repository `ready`, and set
   `ready_at`.
10. On failure, record a bounded `provision_error_code`, mark the repository
   `failed`, and retain the outbox attempt history.

The provisioner must tolerate a crash after every step. A retry must converge
on the same repository and storage namespace without deleting accepted Git
objects.

The create and import APIs can wait for a bounded synchronous attempt. Return
`201 Created` when provisioning completes during that window. Return `202
Accepted` with `lifecycle_state: "provisioning"` when work continues
asynchronously. The CLI polls the repository resource until it reaches `ready`,
reaches `failed`, or exceeds its client timeout.

## API contract

The new surface extends the bounded GitHub-shaped API under `/api/v3`.

### Endpoints

| Method and path | Authority | First release behavior |
| --- | --- | --- |
| `POST /api/v3/user/repos` | Authenticated API with `forge:write` | Create in the caller's GitHub user namespace |
| `POST /api/v3/orgs/{org}/repos` | Authenticated API with `forge:write` | Create in an eligible GitHub organization namespace |
| `POST /api/v3/user/repos/imports` | Authenticated API with `forge:write` | Import a GitHub repository into the caller's user namespace |
| `POST /api/v3/orgs/{org}/repos/imports` | Authenticated API with `forge:write` | Import a GitHub organization repository into its matching organization namespace |
| `GET /api/v3/user/repos` | Authenticated API | List repositories visible to the caller, including private repositories |
| `GET /api/v3/repos/{owner}/{repo}` | Optional API principal | Return a public repository or a repository visible to the principal |
| `GET /api/v3/repository-imports/{id}` | Authenticated API | Return bounded status for an import owned by the caller |
| Git smart HTTP under `/git/{owner}/{repo}.git` | Public read or authenticated Git principal | Clone, fetch, push, and pull |

Do not add an endpoint that accepts an arbitrary owner string. The user route
derives the GitHub user namespace from the authenticated principal. The
organization routes resolve `{org}` to a refreshed GitHub organization ID and
verify the caller's active GitHub authority before creating an OpenAgents row.

The current route classifier treats all `/api/v3` `GET` requests as public.
`GET /api/v3/user/repos` and `GET /api/v3/repository-imports/{id}` are
authenticated exceptions and need explicit route-authority declarations and
tests.

### Create request

```http
POST /api/v3/user/repos
Authorization: Bearer oa_pat_...
Content-Type: application/json
Idempotency-Key: 3ec9fce0-45dd-45b3-93f0-1d1ed3bd4efa
```

```json
{
  "name": "my-project",
  "description": "An optional description",
  "private": true,
  "default_branch": "main"
}
```

Rules:

- `name` is required.
- `description` is optional and bounded to 350 Unicode scalar values.
- `private` defaults to `true`.
- `default_branch` defaults to `main` and follows Git ref-name validation.
- The server derives the GitHub user namespace from the authenticated
  principal. Organization creation uses the organization route.
- `Idempotency-Key` is required for the CLI and recommended for every client.

The same principal, idempotency key, and normalized request returns the original
result. Reusing the key with a different normalized request returns `409
Conflict`.

### Import request

Import into the matching GitHub user namespace:

```http
POST /api/v3/user/repos/imports
Authorization: Bearer oa_pat_...
Content-Type: application/json
Idempotency-Key: f5a7dc80-a670-42ce-9454-fc5e5e64586f
```

```json
{
  "source": {
    "provider": "github",
    "repository": "octavia/existing-project"
  },
  "name": "existing-project",
  "private": true
}
```

Import an organization-owned source into its matching organization namespace
through `/api/v3/orgs/{org}/repos/imports`. The `{org}` path ID must resolve to
the same immutable GitHub owner ID returned for the source repository.

Rules:

- The source is a GitHub `owner/name`, not a caller-supplied clone URL.
- The server resolves the source and its permissions with the signed-in user's
  retained, encrypted GitHub token.
- The user route accepts a source owned by the signed-in GitHub user. Copying a
  repository owned by another account into the GitHub user namespace is a
  future fork or template workflow.
- The organization route requires read access to the source repository, active
  organization membership, and the organization `admin` role required by the
  first-release destination create policy.
- `name` defaults to the normalized GitHub repository name.
- `private` defaults to `true`, including when the GitHub source is public. A
  private source can never default to public.
- `default_branch` defaults to the source default branch.
- The server creates an independent OpenAgents repository. It installs no
  webhook and schedules no later GitHub fetch or push.

Return the repository projection with an `import` object containing only the
import ID, provider, source full name, accepted head SHA, state, and timestamps.
Return `202 Accepted` while the import runs and `201 Created` only when the
repository is already `ready`.

### Repository response

```json
{
  "id": "31fb2eb8-c6f9-4dad-80bd-2e532da9ad7f",
  "name": "my-project",
  "full_name": "octavia/my-project",
  "owner": {
    "login": "octavia",
    "type": "User"
  },
  "private": true,
  "visibility": "private",
  "description": "An optional description",
  "default_branch": "main",
  "lifecycle_state": "ready",
  "clone_url": "https://openagents.com/git/octavia/my-project.git",
  "html_url": "https://openagents.com/octavia/my-project",
  "permissions": {
    "admin": true,
    "push": true,
    "pull": true
  },
  "created_at": "2026-08-20T18:00:00Z",
  "updated_at": "2026-08-20T18:00:00Z"
}
```

The server may add fields. The CLI must ignore unknown fields and fail when a
required field has the wrong type.

### Status and error behavior

| Status | Meaning |
| --- | --- |
| `201 Created` | Repository is ready |
| `202 Accepted` | Repository exists and provisioning continues |
| `400 Bad Request` | Malformed JSON or header |
| `401 Unauthorized` | Missing, invalid, expired, or revoked token |
| `403 Forbidden` | Authenticated principal lacks the required authority |
| `404 Not Found` | Repository is absent or hidden from the principal |
| `409 Conflict` | Name or idempotency conflict |
| `422 Unprocessable Entity` | Valid JSON violates repository rules |
| `503 Service Unavailable` | Provisioning or required GitHub access cannot currently start |

Use one bounded error envelope:

```json
{
  "message": "Repository name is unavailable",
  "code": "repository_name_conflict",
  "field": "name",
  "request_id": "req_..."
}
```

`code` is the automation contract. `message` is user-facing text and can
change. Do not include database, filesystem, Git, object-store, or provider
error prose.

### Pagination

`GET /api/v3/user/repos` uses a bounded opaque cursor:

- `per_page` defaults to 30 and permits 1 through 100.
- `after` carries an opaque server cursor.
- The response contains `repositories` and `next_cursor`.
- Ordering is stable by normalized namespace, normalized name, and UUID.

Do not use an unbounded list because the first browser dashboard happens to
contain one repository today.

## API and Git authentication

### Existing personal API tokens

Keep `oa_pat_...` as the first CLI bearer format. Repository creation requires
`forge:write`, and the server still applies repository or namespace policy after
token authentication. A scope never grants access to every repository.

Existing issue and project clients retain their current behavior. Add scope or
token-format changes only through a separately documented migration.

### Retained GitHub grant

GitHub namespace projection and import use the retained, encrypted GitHub OAuth
token on the server. The OpenAgents PAT proves the CLI caller's OpenAgents
authority; it never becomes a GitHub credential and never receives the GitHub
token.

The existing `repo` grant supplies repository access for public and private
imports. Reading private organization membership requires an explicit
organization-read decision. The first release proposes adding `read:org` so the
server can enumerate active organization memberships and roles through
GitHub's organization-membership API. GitHub documents `repo` and `read:org`
separately in its
[OAuth scope reference](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps).

Before activation:

1. Update the GitHub consent UI to explain repository import and organization
   namespace projection.
2. Update the exact granted-scope validation.
3. Require existing users to reconnect rather than rewriting stored scope
   metadata.
4. Use `Req` for GitHub REST calls and explicit fakes in tests.
5. Fail an import with `github_connection_required` when the user has no
   retained grant.
6. Fail organization operations closed when GitHub cannot refresh the required
   membership or repository permission.

Import never installs a GitHub webhook, writes to GitHub, or schedules a later
sync. After the import completes, OpenAgents is the source of truth for the new
repository and GitHub remains unchanged.

### Browser-assisted CLI login

Add a device-style browser flow so a terminal never handles the GitHub OAuth
grant:

1. `openagents auth login` creates a short-lived CLI authorization request.
2. The server returns a secret device code, a short user code, a verification
   URL, an expiry, and a polling interval.
3. The CLI opens the verification URL when the platform supports it and prints
   the URL and user code as a fallback.
4. The user signs in through the existing GitHub flow and reviews the requested
   `forge:write` scope and token lifetime.
5. The authenticated, CSRF-protected browser approves or denies the request.
6. The CLI polls with the secret device code.
7. On approval, the server returns one `oa_pat_...` plaintext exactly once and
   stores only its digest.
8. The CLI stores the token in an admitted operating-system credential store.

Store device codes as digests, expire them within 10 minutes, allow one terminal
claim, rate-limit polling, and return the same refusal for unknown, expired,
claimed, or denied codes where enumeration would reveal state.

### Headless and agent authentication

An agent or noninteractive process supplies `OPENAGENTS_TOKEN`. The CLI reads
the variable at execution time and does not persist it.

Support `openagents auth login --token-stdin` for attended automation that
needs to store an existing token without placing it in argv or shell history.
Do not add a `--token <plaintext>` option. Command-line arguments can appear in
process listings and diagnostic output.

### Git credential helper

`openagents auth login` offers to configure the Git credential helper. The
helper:

- Implements Git's credential-helper stdin and stdout protocol.
- Returns a credential only for an exact configured HTTPS host.
- Uses the operating-system credential store or `OPENAGENTS_TOKEN`.
- Never returns credentials for plain HTTP except an explicit loopback
  development endpoint.
- Never logs the request, response, token, or complete credential-helper input.
- Erases the stored token on `openagents auth logout`.

`openagents auth setup-git --local` changes only the current repository.
`openagents auth setup-git --global` requires explicit confirmation in an
interactive terminal.

### Git authorization

Resolve Git paths through the repository database:

- Anonymous `upload-pack` is allowed only for a `ready`, public repository.
- Authenticated `upload-pack` requires pull access to the resolved repository.
- `receive-pack` requires an active user, `forge:write`, and a writable
  repository membership.
- Machine credentials require an explicit repository grant and operation
  scope. Pairing a machine does not grant access to every repository.
- The operator credential remains an operational recovery path. It must not be
  the normal CLI credential.
- A private, missing, suspended, failed, or unauthorized repository returns an
  indistinguishable refusal where the transport permits it.

Change the canonical Git path from a name-only route to
`/git/{owner}/{repo}.git`. Keep a tested compatibility alias for the existing
`/git/openagents.com.git` remote until the canonical repository cutover plan
retires it.

## Browser experience

### Repository list

Replace the signed-in dashboard's single hard-coded repository card with a
bounded list of repositories the user can access.

The list includes:

- Namespace and repository name.
- Public or private visibility.
- Description when present.
- Updated time.
- Open issue count when available without an unbounded query.
- A **New repository** action.
- An **Import from GitHub** action.

Use a LiveView stream and separate count and empty-state assigns. Add search and
pagination after the base list works.

### New repository page

Add an authenticated `/repositories/new` route with:

- A namespace selector populated from the signed-in GitHub user and eligible
  GitHub organizations.
- A repository name input.
- An optional description.
- A `private` or `public` visibility choice, with `private` selected initially.
- A default-branch input set to `main`.
- A **Create repository** button with pending and disabled states.

Use `OpenAgentsWeb.UI` components, `to_form/2`, stable DOM IDs, and the
authenticated LiveView session. The browser calls the same context operation as
the API and never invokes forge filesystem code directly.

### Import from GitHub page

Add an authenticated `/repositories/import/github` route with:

- A bounded, paginated picker of GitHub repositories available through the
  retained grant.
- The GitHub owner, repository name, visibility, and default branch.
- A destination namespace that defaults to the matching GitHub user or
  organization namespace.
- An editable destination repository name.
- A `private` or `public` destination choice, with `private` selected initially.
- An explicit statement that the operation copies one snapshot and does not
  maintain synchronization.
- An **Import repository** button with pending and disabled states.

Use the existing GitHub adapter through a context operation. Extend its bounded
repository projection with the immutable repository and owner IDs, owner type,
default branch, permissions, and LFS warning inputs required by this contract.
The LiveView must never receive the retained GitHub token.

While an import runs, show the source full name, accepted head SHA when present,
current state, and a bounded failure code. Do not stream raw Git output to the
browser.

### Empty repository page

After creation, the repository page shows:

- Provisioning progress until the repository reaches `ready`.
- The HTTPS clone URL from the repository projection.
- Commands for cloning an empty repository.
- Commands for adding the repository as a remote to an existing checkout.
- A copy control with an accessible name.
- Links to Issues and Projects for the same repository.

For an imported repository, also show the GitHub source, accepted snapshot SHA,
completion time, and the statement **Imported once from GitHub**. Do not label
the repository as synced or mirrored.

Do not show push instructions until the repository is `ready`.

### Repository route

The preferred repository URL remains `/{owner}/{repo}` so code, Issues, and
Projects share one GitHub-shaped root. Place the dynamic repository-home route
after every reserved first-segment route and maintain an executable reserved
segment inventory. Add route tests proving that `/api`, `/auth`, `/admin`,
`/chat`, `/docs`, `/settings`, `/status`, and future declared product routes
cannot be interpreted as namespaces.

If that route contract cannot be proven without fragile ordering, stop the
repository-home activation and revise this specification before using a
different public route.

## CLI product contract

Publish the npm package as `@openagentsinc/cli` and expose the `openagents`
binary. Reserve `oa` as a possible later alias; do not make scripts depend on
it in the first release.

This CLI is the first-party repository-hosting client. It does not replace the
Pylon contributor runtime or absorb Pylon's agent-execution commands.

### Global behavior

```text
openagents [--profile <name>] [--api-url <url>] [--json] [--no-color] <command>
```

- The `production` profile targets `https://openagents.com` and is the default.
- The `staging` profile targets `https://staging.openagents.com`.
- The `local` profile targets `http://localhost:4000`.
- `--api-url` accepts a normalized custom API origin and overrides the selected
  profile for the current command.
- `OPENAGENTS_API_URL` provides the same per-process override for development,
  continuous integration, and end-to-end tests.
- `OPENAGENTS_PROFILE` selects a named profile when `--profile` is absent.
- Command flags take precedence over environment variables, which take
  precedence over persisted configuration, which takes precedence over the
  `production` default.
- `OPENAGENTS_TOKEN` provides a nonpersistent bearer token.
- `NO_COLOR` and `--no-color` disable ANSI output.
- `--json` emits one documented JSON value to stdout.
- Human progress goes to stderr when stdout carries machine-readable output.
- `--help` works at the root, group, and command levels.
- `--version` prints the CLI version and exits.

The CLI must not send telemetry in the first release.

Accept `http` only for `localhost`, `127.0.0.1`, and `[::1]`. Require `https`
for every other API host. Reject credentials, query strings, fragments, and
non-root paths in API origins. Normalize the origin before any credential-store
lookup so production, staging, local, and custom services cannot share a token
by accident.

All automated CLI tests and local end-to-end tests must set
`OPENAGENTS_API_URL=http://localhost:4000` or pass the equivalent `--api-url`
flag. Tests must fail before a network call if the resolved origin is
`https://openagents.com` or `https://staging.openagents.com`.

### Authentication commands

```text
openagents auth login
openagents auth login --token-stdin
openagents auth status
openagents auth setup-git --local
openagents auth setup-git --global
openagents auth logout
```

`auth status --json` reports the endpoint, authentication source, GitHub account
login and numeric ID, eligible GitHub namespaces, token expiry, and Git-helper
state. It never reports a token or token digest.

### Repository commands

```text
openagents repo create <name>
openagents repo create <owner>/<name>
openagents repo import <github-owner>/<github-repo>
openagents repo list
openagents repo view [<owner>/<name>]
openagents repo clone <owner>/<name> [<directory>]
```

`repo create <name>` targets the authenticated user's GitHub user namespace.
`repo create <owner>/<name>` succeeds only when the authenticated user can
create repositories in the matching GitHub organization namespace.

Create options:

```text
--public
--private
--description <text>
--default-branch <branch>
--remote <name>
--source <directory>
```

Rules:

- `--public` and `--private` are mutually exclusive. Omission means private.
- Without `--source`, the command creates only the remote repository.
- With `--source`, the command verifies that the directory is a Git worktree,
  creates or updates the named remote after server creation succeeds, and
  prints the next push command.
- The first release does not push automatically. A future `--push` flag needs a
  separate confirmation and branch-selection contract.
- `--remote` defaults to `origin` only when that remote is absent. If `origin`
  already points elsewhere, the command refuses to overwrite it.

Import options:

```text
--name <destination-name>
--namespace <github-owner>
--public
--private
--wait-timeout <duration>
```

Import rules:

- The source argument is a GitHub `owner/name`, not a URL.
- The destination namespace defaults to the GitHub source owner and must resolve
  to the same GitHub user or organization identity.
- `--namespace` can state that matching owner explicitly. It cannot copy the
  source into an unrelated namespace in the first release.
- `--name` defaults to the source repository name.
- The destination defaults to private. `--public` requires an explicit flag,
  including for a public source.
- The command submits one idempotent import, polls until `ready` or `failed`,
  and reports the accepted source head SHA.
- The command exits after the bounded `--wait-timeout` without canceling a
  durable import that still runs on the server.
- After success, the command states that later GitHub changes will not sync.

`repo list` supports `--namespace`, `--limit`, `--after`, and `--json`.
`repo view` and later repository-scoped commands infer the repository from the
`origin` remote when no argument is present. `-R, --repo <owner>/<name>`
overrides inference.

Remote inference accepts only clone URLs returned by an admitted OpenAgents
endpoint. It must not treat an arbitrary path that resembles `owner/name` as an
authenticated OpenAgents repository.

### Future command reservations

Reserve these names without shipping placeholder commands:

```text
openagents repo delete
openagents repo mirror
openagents pr ...
openagents ruleset ...
openagents ssh-key ...
openagents api ...
openagents update
openagents completion
```

A help page must describe only commands that work in the installed version.

### Noninteractive behavior

When stdin or stdout is not a terminal:

- Never open a browser or prompt for confirmation.
- Require `OPENAGENTS_TOKEN` or an existing admitted credential-store entry.
- Require all ambiguous values as flags or arguments.
- Return stable exit codes.
- Keep stdout machine-readable when `--json` is present.
- Cancel in-flight HTTP requests and child Git processes on `SIGINT` and
  `SIGTERM`.

Use these initial exit-code classes:

| Code | Meaning |
| --- | --- |
| `0` | Success |
| `1` | Unclassified operational failure |
| `2` | Usage or validation error |
| `3` | Authentication or authorization failure |
| `4` | Repository not found or hidden |
| `5` | Conflict |
| `6` | Network or service unavailable |
| `7` | Repository provisioning failed or timed out |
| `130` | Interrupted by the user |

The JSON error shape contains `code`, `message`, `exit_code`, and `request_id`
when the server supplies one.

## CLI implementation proposal

Create the CLI in the `openagents` monorepo at
`packages/openagents-cli/` with:

- Package name `@openagentsinc/cli`.
- Binary name `openagents`.
- Node 24, pnpm, and Vite Plus, matching the monorepo contract.
- Effect and Effect Schema for services, configuration, response decoding,
  typed failures, resource scopes, retries, interruption, and tests.
- A public package boundary only if the release process intends npm
  distribution. Keep it private during the first implementation slice if the
  release format remains undecided.

The monorepo requires Effect for new TypeScript service and CLI logic. The
remaining decision is the command-parser package, not whether business logic
uses Effect. Do not add `@effect/cli` or another parser until a small spike
proves compatibility with the pinned Effect version, help output, completion,
and packaged binaries.

### Effect service boundaries

Keep command handlers thin and compose these services:

| Service | Responsibility |
| --- | --- |
| `CliConfiguration` | Profile, API origin, output mode, timeouts, and environment inputs |
| `CredentialStore` | Secure token presence, read, write, and erase |
| `AuthClient` | Device authorization, status, and logout |
| `ForgeApiClient` | Authenticated repository API calls and schema decoding |
| `RepositoryResolver` | Parse `-R`, environment, and admitted Git remotes |
| `GitClient` | Run argv-only Git commands with bounded output and cancellation |
| `GitCredentialHelper` | Implement the exact Git credential protocol |
| `BrowserLauncher` | Open the verification URL in an attended session |
| `ConsoleOutput` | Human and JSON rendering without secret leakage |

Model expected failures as tagged errors and map them to the exit-code table in
one place. Preserve server error codes instead of parsing user-facing messages.

The monorepo contains `@openagentsinc/local-secret-store`, including platform
adapter contracts and some owner-attended adapters. Run a focused suitability
review before reuse. A CLI credential store must work for ordinary attended
users and fail closed in headless environments; it must not require a hidden
developer-only acknowledgment.

The monorepo also contains `@openagentsinc/forge-protocol`. Its README labels it
a historical coordination contract and says the hosted `openagents.com` service
owns current API authority. Do not make it the repository-creation authority.
Reuse a type only if it matches a new Phoenix-owned public API contract and no
historical D1, R2, Nostr, or standalone-service assumption crosses the boundary.

The CLI targets the Phoenix endpoints in this specification. It does not target
`apps/forge-git-service` as a separate API authority. Moving the Git data plane
behind that service would require a separate architecture and deployment
decision while preserving the Phoenix policy authority.

### Client contract synchronization

The server repository owns the HTTP contract. Keep the two repositories in
sync through a versioned artifact:

1. Add repository endpoint controller tests and JSON fixtures in
   `openagents.com`.
2. Publish a bounded OpenAPI document or equivalent JSON Schema artifact for
   the repository endpoints.
3. Record its version and SHA-256 digest in the CLI source.
4. Generate or hand-author Effect Schema decoders against that artifact.
5. Run CLI contract tests against the server-owned fixtures.
6. Fail the release gate when a required field or error code changes without a
   contract-version update.

The OpenAPI or JSON Schema artifact describes the client contract. Phoenix
controller tests remain the executable server truth.

### Distribution

The desired user experience is a single installer followed by
`openagents --version`, but the packaging mechanism needs a spike.

Evaluate these release steps in order:

1. Run `@openagentsinc/cli` from the monorepo with Node 24 during development.
2. Publish an npm development preview after package and binary smoke tests pass.
3. Produce checksum-verified standalone artifacts for macOS, Linux, and WSL.
4. Serve a versioned installer from `openagents.com` only after artifact signing,
   rollback, and update-channel behavior pass release tests.
5. Add `openagents update` only after the updater verifies a signed manifest and
   artifact digest before replacement.

Do not publish a `curl | sh` instruction before the script pins and verifies the
downloaded artifact.

## Security and privacy requirements

- Derive every namespace and repository mutation from an authenticated
  principal.
- Check membership and lifecycle state in the same query that resolves a
  repository for API or Git access.
- Store API tokens, device codes, and poll secrets only as digests on the
  server.
- Keep the retained GitHub token inside the server adapter. Never return it to
  the CLI, browser, provisioning row, import receipt, or Git remote.
- Show a CLI token once and never include it in export, logs, telemetry,
  receipts, exception messages, or JSON output.
- Do not put credentials in clone URLs.
- Bound request bodies, Git diagnostics, descriptions, names, list sizes,
  retries, polling, and total command duration.
- Treat repository descriptions, README files, and other repository content as
  untrusted input.
- Apply the existing Markdown sanitization boundary to rendered repository
  content.
- Return `404 Not Found` for a private repository when the caller must not learn
  that it exists.
- Audit repository creation, provisioning transitions, membership creation,
  GitHub import transitions, token creation, and Git writes without recording
  repository content.
- Prevent repository creation from changing runtime configuration or deployment
  targets.
- Remove isolated import workspaces after success or failure through a bounded
  recovery worker.
- Never describe an imported repository as synchronized after the one accepted
  snapshot completes.

## Test plan

### Phoenix domain and API tests

Add focused tests for:

- GitHub user and organization namespace projection by immutable numeric ID.
- GitHub login rename, alias routing, case normalization, and collision refusal.
- Repository name and default-branch validation.
- Atomic repository, owner-membership, optional import, and outbox creation.
- Idempotent repeat requests and mismatched idempotency keys.
- GitHub user namespace authority, organization admin authority, stale
  membership refresh, and refusal of arbitrary owner creation.
- Missing GitHub connection, missing `read:org`, source repository refusal, and
  private source authorization.
- Import request and status projections without credentials or raw Git output.
- Public, private, member, nonmember, banned-user, suspended, failed, and
  missing repository reads.
- `201`, `202`, `401`, `403`, `404`, `409`, `422`, and `503` behavior.
- Pagination order and cursor bounds.
- Route-authority classification for authenticated `GET /api/v3/user/repos`.
- Cross-repository isolation for the new endpoints.

Follow the repository's endpoint-first test-driven workflow: start each route
with a failing `OpenAgentsWeb.ConnCase` test before adding the route or
controller action.

### Provisioning and Git tests

Add tests for:

- A crash after each provisioning transition followed by convergence.
- Duplicate outbox delivery.
- WAL initialization before `ready`.
- Frozen GitHub branch and tag refs, source ref-digest verification, and an
  update that lands on GitHub after the accepted snapshot.
- Import of public and private GitHub repositories.
- Import failure, retry, interruption, timeout, and isolated-workspace cleanup.
- LFS detection and the required pointer-only warning.
- Proof that neither GitHub nor OpenAgents receives a synchronization write
  after import completion.
- Bare-cache deletion followed by reconstruction.
- Two repositories with the same name in different namespaces.
- Anonymous clone of a public repository.
- Hidden private clone without a credential.
- Member clone, contributor push, reader push refusal, and nonmember refusal.
- Token expiry and revocation during a Git session.
- A paired machine with and without an explicit repository grant.
- Compatibility of the existing `openagents.com` Git remote.
- Proof that a user repository cannot enter build, promotion, or deployment
  paths.

### LiveView tests

Add tests for stable DOM IDs and outcomes:

- Repository list, empty state, and pagination.
- GitHub user and organization namespace selection.
- Create form validation and submission.
- GitHub repository picker, import submission, progress, warning, and failure
  states.
- Private visibility as the default.
- Provisioning, ready, and failed states.
- Clone instructions only after readiness.
- Navigation to Issues and Projects under the new repository path.

### CLI tests

Use deterministic Effect layers and fake clocks for:

- Command parsing and generated help.
- Environment, stored credential, and endpoint precedence.
- Device authorization approval, denial, expiry, rate limiting, and
  interruption.
- Token redaction from human output, JSON, errors, logs, and snapshots.
- Repository create `201` and `202` flows.
- Repository import `201`, `202`, failure, timeout, and idempotent retry flows.
- Matching GitHub destination namespace enforcement.
- Idempotent retry after a connection failure.
- Remote inference and refusal of unadmitted hosts.
- Refusal to overwrite an existing `origin` remote.
- Git credential-helper protocol transcripts.
- TTY and non-TTY behavior.
- Stable exit-code and JSON error mappings.
- Unknown response fields and invalid required response fields.

Run an end-to-end suite against a disposable Phoenix server, PostgreSQL
database, forge storage directory, and Git checkout. The suite must create a
repository through the CLI, push a commit with standard Git, clone it into a
second directory, and verify the exact commit SHA. A second case must import a
GitHub fixture repository, verify every accepted branch and tag, change the
GitHub fixture after acceptance, and prove that the OpenAgents repository does
not synchronize that later change.

## Delivery sequence

### Phase 0: Close design decisions

1. Approve the canonical browser and Git URL shapes.
2. Confirm the GitHub `read:org` consent and reconnection migration.
3. Record the initial npm-only distribution boundary and the later standalone
   artifact gate.
4. Record the GitHub namespace, one-time import, repository lifecycle, and
   authority split in `INVARIANTS.md`.

### Phase 1: Add namespace and repository authority

1. Generate migrations with `mix ecto.gen.migration`.
2. Add GitHub-backed namespace, namespace-alias, repository-import, and
   repository lifecycle schemas.
3. Backfill `OpenAgentsInc/openagents.com` into an explicit GitHub organization
   namespace identified by its numeric GitHub ID.
4. Add transactionally created owner membership, optional import, and
   provisioning outbox rows.
5. Rehearse the migration down and up against populated fixtures.

### Phase 2: Add create, import, list, and view APIs

1. Add failing controller tests for `POST /api/v3/user/repos`.
2. Add failing controller tests for the user and organization import routes.
3. Implement the context operations, controllers, JSON projections, and routes.
4. Add authenticated repository list, import status, and optional-auth
   repository view.
5. Add idempotency, cursor, error-envelope, and route-authority tests.
6. Publish the initial client contract artifact.

### Phase 3: Provision Git repositories

1. Make the hosted repository inventory database-backed.
2. Change storage keys and Git paths to include stable repository identity.
3. Add the idempotent provisioning worker and recovery scan.
4. Add the one-time GitHub importer with frozen refs, bounded retries, secure
   credential delivery, and temporary-workspace recovery.
5. Scope upload-pack and receive-pack through repository policy.
6. Preserve the deployment allowlist as a separate operator control.
7. Prove create, import, push, cache loss, reconstruction, fetch, and clone
   locally.

### Phase 4: Add CLI authentication

1. Add device authorization records and endpoints.
2. Add GitHub organization projection and the proposed `read:org` consent
   migration.
3. Add the authenticated browser approval page.
4. Add one-time PAT delivery and expiry behavior.
5. Implement the CLI credential store and Git credential helper.
6. Pass secret-handling and headless-agent tests.

### Phase 5: Build the Effect CLI

1. Create `packages/openagents-cli` in the monorepo.
2. Pin the Phoenix-owned contract artifact.
3. Implement `auth`, `repo create`, and `repo import` through Effect services.
4. Add human output, JSON output, exit-code, signal, and redaction tests.
5. Run the cross-repository disposable end-to-end suite.

### Phase 6: Add the browser interface

1. Replace the hard-coded dashboard repository card with the scoped list.
2. Add GitHub namespace selection and repository creation pages.
3. Add GitHub repository selection and one-time import pages.
4. Add provisioning, import, and empty-repository states.
5. Run accessibility, keyboard, responsive, and browser checks.

### Phase 7: Stage and release

1. Run `mix precommit` and the owned exact-SHA gate in `openagents.com`.
2. Run `pnpm run check` in the CLI monorepo.
3. Deploy to an isolated staging environment only after Gate 12 permits it.
4. Create, import, push, clone, revoke, retry, and recover on one staging
   candidate.
5. Scan the complete log window for tokens, clone credentials, repository
   content, and private paths.
6. Publish the CLI only after the server candidate and client contract digest
   match.

## Acceptance criteria

The first repository and import slice is complete when:

- An authenticated user receives the GitHub user namespace identified by the
  same numeric GitHub user ID and sees eligible organization namespaces
  identified by their numeric GitHub organization IDs.
- The browser and CLI create the same repository resource through the same
  context policy.
- A successful command returns only after the repository is ready, or reports a
  durable provisioning failure with a stable code.
- The creator receives an `owner` membership in the same database transaction
  as the repository row.
- A repeat request with the same idempotency key cannot create a duplicate.
- The browser and CLI can import an authorized GitHub repository's accepted
  history, branches, and tags into the matching GitHub namespace.
- An imported repository records its source and exact accepted snapshot without
  retaining a GitHub credential.
- A GitHub commit created after import acceptance does not appear in OpenAgents
  without a new explicit future import or synchronization feature.
- A public repository clones anonymously.
- A private repository is hidden from a nonmember.
- A permitted user can push and a read-only or unrelated user cannot.
- Deleting the node-local bare cache does not lose accepted Git history.
- Creating a repository cannot make it deployable.
- The CLI works in attended and noninteractive modes without placing a token in
  argv, logs, JSON, or a clone URL.
- `openagents repo create`, standard `git push`, and `openagents repo clone`
  complete an exact-SHA end-to-end test.
- `openagents repo import` completes a second exact-ref end-to-end test for a
  GitHub fixture.
- Both repositories pass their required local gates at the exact delivered
  revisions.

## Implementation decisions recorded

This document records these implementation decisions:

- GitHub user and organization identity is the first-release namespace
  authority.
- The package is `@openagentsinc/cli`, and the binary is `openagents`.
- The CLI uses Effect TypeScript with `effect/unstable/cli`.
- The CLI includes production, staging, and local API profiles and accepts a
  validated custom API origin.
- The browser uses `/{owner}/{repo}` after the reserved-route proof passes.
- GitHub OAuth requests `read:org` with `repo`; an existing connection that
  lacks a required scope must reconnect.
- The first distribution is an npm dogfood release. Signed standalone artifacts
  require their separate release gate.
