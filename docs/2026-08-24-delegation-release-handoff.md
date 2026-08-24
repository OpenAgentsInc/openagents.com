# Delegation release handoff, 2026-08-24

This document hands off unfinished work on model-driven delegation. The CLI side
is published. The server side is committed and pushed to forge `main`, but
production still runs the previous release, so the new behavior is not live yet.

## What is live

- Production runs openagents.com `adc413e98c701e1aa23db5d82eac525e5cca23e2`,
  image digest
  `sha256:28e7bafa803f8125cb60f139d38df7fbe6f5ef313b261ecbc14249f9211683c0`,
  on `sarah-fleet-1`, `sarah-fleet-2`, and `sarah-fleet-3`. Forge target
  `0c4f5374-d693-4b6a-a2a4-3b679887e2d1` is `live`.
- `POST /api/v3/threads` answers `201`, so `openagents coder` opens a thread.
- `@openagentsinc/cli@0.3.5` is the published latest release. `0.3.3` is
  deprecated because it shipped unresolved `catalog:` dependencies.
- In `0.3.5` the model calls a `delegate` tool during a conversation. There is
  no slash command, no `--child-model` flag, and no client-side provider
  credential. Children are real `opencode` processes that spend a grant the CLI
  obtains from the server.

## What is committed but not deployed

Forge `main` for openagents.com is
`26a7e605e9c3462a79ecd2aa185abe293cc0d9c7`, "Give a signed-in account credit, a
chat scope, and a second model". It carries three behavior changes, each with
tests, and the full suite passes locally (`3 doctests, 4141 tests, 0 failures`):

1. **A chat scope on ordinary login.** `openagents auth login` now mints
   `["chat:account", "forge:write"]`. `OpenAgents.ApiTokens.default_scopes/0` is
   the single source, and the device authorization schema, service, and
   controller all defer to it. Before this change, a plain login produced a
   token that `POST /api/v3/threads` refused, which is the failure Christopher
   hit.
2. **Account-level credit.** A signed-in account draws against
   `account_credit_microusd`, `100_000_000` microUSD, for the life of the
   account rather than per thread. An anonymous visitor keeps
   `visitor_credit_microusd`, `2_000_000` microUSD.
   `OpenAgents.Inference.Credit.spent/1` sums usage across every grant the
   visitor owns, including revoked and expired ones, and
   `OpenAgents.Threads.ceilings/1` mints each new grant for the remainder. An
   exhausted account is refused with `credit_exhausted` and an actionable
   sentence.
3. **A second model, routed to OpenRouter.** `OpenAgents.Inference.Models` is
   the registry that separates the public ID, the provider module, and the
   provider's own model string. `ox-alpha` resolves to
   `OpenAgents.Providers.OpenRouter` with provider model `stealth/ox-alpha`;
   `gpt-5.6-luna` stays on `OpenAgents.Providers.OpenAI`.
   `POST /api/v3/threads` accepts `{"model": "ox-alpha"}`, validates it through
   the registry, and mints the grant against it. The inference proxy resolves
   the provider from the grant, never from the request body.

On the CLI side, `0.3.5` opens a **separate** child thread on `ox-alpha` for
delegated children, so the parent conversation stays on Luna. A refusal to open
that thread is reported, never absorbed: the session says which refusal stopped
it rather than quietly running children on the parent's Luna grant.

## Remaining work, in order

1. **Deploy `26a7e60` to production.** Follow
   `docs/operations/production-deploy-runbook.md`: release gate, image build and
   push, promote, migration job, rolling replacement, settle, verify.
2. **Verify the routing end to end against production**, with the published
   CLI. Do not report success from configuration alone. The claims to prove are:
   plain `openagents auth login` opens a thread; the parent grant reports
   `gpt-5.6-luna`; the child thread request carries `"model": "ox-alpha"` and its
   grant reports `ox-alpha`; the proxy calls
   `OpenAgents.Providers.OpenRouter` with `stealth/ox-alpha`; no client-side
   OpenRouter key is involved; a child-thread failure surfaces its real code and
   message; both grants are revoked on exit.
3. **Review credit minting under concurrency.** `Threads.ceilings/1` reads
   remaining credit and then mints. Two simultaneous thread opens can each read
   the same remainder, so an account can oversubscribe by one grant's ceiling.
   Decide whether to serialize on the visitor row or accept the overshoot, and
   record the decision.
4. **Consider registry uniqueness.** If `openai_model` is ever configured as
   `ox-alpha`, `Models.all/0` returns two entries with the same ID. Deduplicate,
   or assert uniqueness in a test.
5. **Rotate the npm token** pasted in the working session. It published `0.3.4`
   and `0.3.5` and is now in a transcript.

## Deploy notes for this box

The release gate ran repeatedly here and stalled on environment flakes rather
than on the candidate:

- The gate needs Node 24. Node 20 fails
  `assets/test/sidebar_section_test.mjs`. Use
  `export PATH="$HOME/.nvm/versions/node/v24.19.0/bin:$PATH"`.
- The gate's `version_chain` and later stages connect over TCP, where
  `pg_hba.conf` requires `scram-sha-256`. The local `ubuntu` role needs a
  password, and the smoke URL must carry it:
  `OPENAGENTS_RELEASE_SMOKE_DATABASE_URL='ecto://ubuntu:PASSWORD@127.0.0.1/openagents_release_smoke'`.
- `mix precommit` failed once per run on a different load-sensitive test each
  time, and every one of them passed in isolation on the same commit:
  `OpenAgents.SCV.RunTest`, `OpenAgents.SCV.OpenCodeExecutorTest`, and
  `OpenAgents.Machines.IndexReachTest`. The first two spawn real processes and
  the third asserts a planner index choice. On an 8-core box under load they are
  unreliable. Treat a single failure of one of these as a flake, confirm it in
  isolation, and rerun rather than changing the candidate. Making them robust is
  worth its own issue.
- Two checkouts exist on this box. `~/repos/openagents.com` has the forge as
  `origin`; `~/repos/openagents-com` has the GitHub mirror proxy and holds the
  warm `_build`, `deps`, and the gate receipts under
  `.git/openagents/release-gate-receipts/`. The gate keys a receipt to the exact
  SHA, so it must run in the checkout that will build the image.
- Promotion needs `deployments:promote` and live operator standing. Saved tokens
  expire within 7 days, so mint one through the device authorization flow, or on
  a fleet node, at deploy time.

## Reference material

- `docs/2026-08-23-nested-thread-delegation-audit.md`, the delegation audit this
  work follows.
- In the openagents monorepo,
  `docs/teardowns/2026-08-23-cc-tool-and-agent-fleet-rendering-reproduction.md`
  and `docs/teardowns/2026-08-23-openagents-coder-tui-agent-fleet-port-plan.md`
  hold the tool contract, task registry, and fleet rendering specification the
  Coder TUI is being ported against.
- `INVARIANTS.md` records the credit and scope statements this change updated.
