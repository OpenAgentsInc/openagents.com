# GitHub authentication plan

Date: 2026-08-19

Source: `~/work/sarah` GitHub OAuth implementation and the current OpenAgents issue tracker UI.

OpenAgents needs a real, server-side GitHub OAuth flow before any issue or project page can claim to use real data. This plan ports the proven auth stack from `sarah`, adapts it to the OpenAgents namespace, and drives every step out with a failing test first.

## Goal

A visitor can sign in with GitHub and then access the issue tracker at `/:owner/:repo/issues` and `/:owner/:repo/issues/new`. There are no seeded users, no placeholder owners, and no fake tokens. The API calls that back the UI use the signed-in user's own GitHub access token.

## What we are copying from `sarah`

These `sarah` modules are the reference implementation:

- `lib/sarah/accounts.ex`
- `lib/sarah/accounts/oauth_attempt.ex`
- `lib/sarah/accounts/token_vault.ex`
- `lib/sarah/accounts/user.ex`
- `lib/sarah/github.ex`
- `lib/sarah/github_oauth.ex`
- `lib/sarah/github_oauth/runtime_config.ex`
- `lib/sarah_web/controllers/auth_controller.ex`
- `lib/sarah_web/router.ex` auth routes and `UserAuth` hooks

## New modules and changes

### Domain and persistence

- `OpenAgents.Accounts` — upsert user, fetch active user, store and retrieve the encrypted GitHub token.
- `OpenAgents.Accounts.User` — Ecto schema for `users` with `github_id`, `github_login`, `github_name`, `github_avatar_url`, `status`, `last_authenticated_at`, and `github_token_ciphertext`.
- `OpenAgents.Accounts.OAuthAttempt` — Ecto schema for `github_oauth_attempts` with `state_digest`, `expires_at`, and `consumed_at`.
- `OpenAgents.Accounts.TokenVault` — AES-256-GCM seal and unseal for the GitHub access token.
- `OpenAgents.GitHub` — read-only GitHub REST wrapper that uses the user's token. To start, we only need `list_repositories/2` and `read_path/4` later; the immediate use is validating the token works after login.
- `OpenAgents.GitHubOAuth` — PKCE authorize URL, state/attempt handling, code exchange, and profile fetch.
- `OpenAgents.GitHubOAuth.RuntimeConfig` — validate `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, and `GITHUB_REDIRECT_URI`.

### Web interface

- `OpenAgentsWeb.AuthController` — `POST /auth/github`, `GET /auth/github/callback`, and `DELETE /logout`.
- `OpenAgentsWeb.UserAuth` — `fetch_current_user/2`, `require_authenticated/2`, `mount_current_user/4`, and `ensure_authenticated/4`.
- `OpenAgentsWeb.Router` — add auth routes, a `:browser` pipeline `fetch_current_user` plug, an `:authenticated` pipeline, and a `live_session :authenticated` `on_mount` hook around the `/:owner/:repo` issue and project routes.
- `lib/openagents_web/components/layouts.ex` — show a **Sign in with GitHub** button or the signed-in user's avatar and a **Log out** link in the navbar.
- `lib/openagents_web/live/home_live.ex` — add a sign-in CTA when the visitor is not authenticated.
- `lib/openagents_web/live/issue_new_live.ex` and other `/:owner/:repo` LiveViews — move inside the authenticated live session.

### Configuration and migrations

- `config/dev.exs`, `config/test.exs`, and `config/runtime.exs` — add `github_oauth` and `github_token_encryption_key` config.
- `priv/repo/migrations/..._create_users.exs` and `..._create_github_oauth_attempts.exs`.

## TDD steps and test files

For each step, write the test first, run `mix test <file>` to confirm it fails, then make it pass. Run `mix precommit` before moving on.

1. **User persistence**
   - `test/openagents/accounts_test.exs`
   - Test `upsert_github_user/1` inserts and updates a user by `github_id`.
   - Test `get_active_user/1` returns `{:ok, _}` for active and `{:error, :banned}` for banned.
   - Test `store_github_token/2` seals a token and `github_token/1` unseals it.

2. **OAuth attempt table**
   - `test/openagents/accounts/oauth_attempt_test.exs`
   - Test `create_oauth_attempt/2` and `consume_oauth_attempt/2` succeed only for valid, unexpired, unconsumed attempts.

3. **Token vault**
   - `test/openagents/accounts/token_vault_test.exs`
   - Test `seal/1` and `open/1` round-trip; test tampered ciphertext fails.

4. **GitHubOAuth flow**
   - `test/openagents/github_oauth_test.exs`
   - Test `begin_authorization/0` returns a URL with `client_id`, `code_challenge`, and `scope=read:user repo`.
   - Test `consume_attempt/2` validates state, verifier, and expiry.
   - Test `exchange_and_fetch/2` using a mocked `Req.post/2` and `Req.get/2` to return an access token and a profile.

5. **Auth controller**
   - `test/openagents_web/auth_controller_test.exs`
   - Test `POST /auth/github` redirects to `github.com/login/oauth/authorize` and sets a session attempt.
   - Test a valid `GET /auth/github/callback` creates the user, stores the token, sets `user_id` in the session, and redirects to `/`.
   - Test an invalid callback clears the session and redirects with an `auth_error`.
   - Test `DELETE /logout` clears the session and redirects.

6. **User auth plug and live hooks**
   - `test/openagents_web/plugs/user_auth_test.exs`
   - Test `fetch_current_user` assigns `current_user` from `user_id`.
   - Test `require_authenticated` redirects when there is no user.
   - Test `OpenAgentsWeb.UserAuth.ensure_authenticated/4` halts an unauthenticated live view.

7. **Protected issue pages**
   - `test/openagents_web/live/issue_new_live_test.exs`
   - Test an unauthenticated `GET /OpenAgents/openagents/issues/new` redirects to `/auth/github`.
   - Test an authenticated user with a stored token can visit `/:owner/:repo/issues/new`.

## Implementation order

1. Add `users` and `github_oauth_attempts` migrations and schemas.
2. Port `OpenAgents.Accounts` and `OpenAgents.Accounts.TokenVault` with tests.
3. Port `OpenAgents.GitHubOAuth` and `OpenAgents.GitHubOAuth.RuntimeConfig` with tests.
4. Add `OpenAgentsWeb.AuthController` and the `/auth/github`, `/auth/github/callback`, and `/logout` routes.
5. Add `OpenAgentsWeb.UserAuth` and the `:authenticated` pipeline, then wrap the `/:owner/:repo` LiveViews in an authenticated `live_session`.
6. Update `HomeLive` and `Layouts.app` to show the sign-in or user state.
7. Switch the `OpenAgents.Issues` API to load the signed-in user's token from the session so `/:owner/:repo/issues/new` can call GitHub with real credentials.

## Configuration

Add these environment variables before running the app:

- `GITHUB_CLIENT_ID`
- `GITHUB_CLIENT_SECRET`
- `GITHUB_REDIRECT_URI` — must be `http://localhost:4000/auth/github/callback` in development or an HTTPS callback in production.
- `GITHUB_TOKEN_ENCRYPTION_KEY` — a Base64-encoded 32-byte AES key.

## Acceptance

- `/` shows **Sign in with GitHub** when no session exists.
- After signing in, the navbar shows the GitHub login and a **Log out** link.
- Visiting `/:owner/:repo/issues/new` without a session redirects to `/auth/github`.
- Visiting `/:owner/:repo/issues/new` with a session renders the new issue form.
- `mix test` and `mix precommit` pass after each step.
