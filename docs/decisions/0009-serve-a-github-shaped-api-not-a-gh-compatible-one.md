# ADR 0009: Serve a GitHub-shaped API, not a `gh`-compatible one

Date: 2026-08-25

Status: Accepted

## Context

The API moved from `/api/v3` to `/api/v1` (issue #211). The version in the path
names this API's own version, and this API is at its first. One deploy serves
both paths: `OpenAgentsWeb.Plugs.ApiV3Rewrite` rewrites `/api/v3/*` to
`/api/v1/*` so that clients released against the old prefix keep working while
the fleet upgrades.

That alias raised a question the rename audit
(`docs/2026-08-24-api-v1-rename-audit.md`) left open, and issue #215 asks you
to settle: GitHub's own CLI hardcodes `https://HOST/api/v3/` for any host other
than github.com, with no way to override the path segment. If `gh` is a client
this forge wants, the alias can never be deleted.

The audit stopped at the path. Reading the path alone suggests that keeping
`/api/v3` buys `gh` compatibility for the price of one plug. Running `gh`
against the live application says otherwise. Every row below is `gh` 2.89.0
against `openagents.com` on 2026-08-25, captured with `GH_DEBUG=api`:

| Command | Request `gh` makes | Result |
| --- | --- | --- |
| `gh issue list -R …` | `POST /api/graphql` | `404` |
| `gh issue view 215 -R …` | `GET /api/v3/meta` | `406` |
| `gh api repos/OWNER/REPO/issues` | `GET /api/v3/repos/…/issues` | `200` |
| `gh api https://openagents.com/api/v1/repos/OWNER/REPO/issues` | `GET /api/v1/repos/…/issues` | `200` |

Three facts follow.

- The ported commands do not use REST. `gh issue list` sends a GraphQL query to
  `/api/graphql`, and `gh issue view` first probes `GET /api/v3/meta`. This
  application serves neither endpoint, so no alias makes those commands work.
- The one `gh` surface the alias keeps alive is `gh api`, the raw REST
  passthrough, which is a `curl` substitute rather than a reason to use `gh`.
- Even `gh api` does not need the alias. Given a full URL it calls `/api/v1`
  directly and answers `200`. Only a bare path picks up the `/api/v3` prefix.

## Decision

Serve a GitHub-shaped API, and do not claim `gh` compatibility.

- `gh` is not a supported client. The supported clients are the `openagents`
  CLI, which is first-class, and any GitHub-shaped client that takes an
  explicit base URL, such as Octokit configured with
  `baseUrl: "https://openagents.com/api/v1"`.
- `/api/v3` stays a dated migration alias for released clients, and it gets
  deleted on the schedule issue #216 describes. Nothing about `gh` makes it
  permanent.
- Every versioned route is declared at `/api/v1`, and every URL a response
  emits names `/api/v1`. `OpenAgentsWeb.Plugs.ApiV3Rewrite` is the only place
  in `lib/` that names the old prefix, so removing the alias stays a one-file
  change. `INVARIANTS.md` records this as FORGEAPI-002, and
  `test/openagents_web/api_version_posture_test.exs` proves it.

## Consequences

- Issue #216 proceeds. The gh-posture decision it waited on does not make the
  alias permanent.
- Documentation states the limit rather than implying drop-in tooling.
  `priv/docs/rest-api.md` names `gh` as unsupported and gives you the two
  clients that work. The episode 273 summary in `docs/episode-triage.md`
  carries a dated correction, because "so `gh` and octokit work unchanged"
  recorded an intent that the evidence does not support.
- A response that emits an `/api/v3` URL is now a build failure. The trace
  ingest route landed during the rename and returned a `url` field naming
  `/api/v3/traces/{id}`, a link that would have gone dead with the alias. That
  is fixed, and the proof stops the next one.
- If `gh` compatibility is ever worth having, the work is a GraphQL endpoint
  and `GET /api/v1/meta`, plus restoring the `/api/v3` prefix. That is a
  product decision about serving GraphQL, not a decision about a path segment,
  and it belongs in its own ADR.
