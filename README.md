# OpenAgents

OpenAgents is an AGPL-3.0 Phoenix application for building and operating
agent-backed software in public. This repository contains the complete product:
Sarah chat and voice, governed memory and tools, delegated work and connected
computers, issues and projects, the Git forge, and the deployment control plane.

The current architecture and trust boundaries are documented in
[docs/architecture.md](docs/architecture.md). The staged hardening work is
tracked in the
[integration hardening plan](docs/2026-08-20-integration-hardening-and-staging-readiness-recommendations.md).
The typed settings, safe feature profile, and redacted readiness command are in
[docs/runtime-configuration.md](docs/runtime-configuration.md).
Repository creation, one-time GitHub import, and the terminal client are
documented in the [OpenAgents CLI guide](docs/openagents-cli/index.md).

## Production status

OpenAgents runs at [openagents.com](https://openagents.com) on a three-node
production fleet. The owned Forge is the canonical Git remote for this
repository, and `MirrorWatch` exports accepted `main` commits to GitHub. Every
deployment starts from an exact commit that passed the release gate.

### Active capabilities

- GitHub OAuth, encrypted server-side GitHub token storage, sessions, and
  account-scoped data rights.
- Authenticated text chat with durable turns, provider receipts, tools, memory,
  delegated work, and connected-computer orchestration.
- Voice session, transcript, usage, recording, and operator-projection domains.
- Issues, comments, labels, milestones, projects, public status, changelog, and
  bounded source-browsing surfaces.
- GitHub-backed repository namespaces, private and public repository creation,
  one-time GitHub import, Git smart HTTP, and the Effect TypeScript CLI.
- Git HTTP, push receipts, promotion targets, build receipts, and local BEAM
  deployment primitives, including transactional direct loading, two-way
  relups, and provider-neutral rolling replacement.
- An owned exact-SHA release gate covering browser JavaScript, the Phoenix
  application, distributed cluster cases, direct transactions, relup and
  interruption recovery, rolling replacement, repository contracts, and a
  disposable packaged-release smoke test.

Availability still depends on repository access, account authority, and the
runtime feature profile. A source module or passing local test does not by
itself establish that a feature is enabled for every production user.

### Controlled capabilities

- Voice, recording, semantic recall, experimental program paths, and deployment
  workers remain controlled by runtime configuration.
- Forge direct loading accepts only verified BEAM changes whose modules match
  the production allowlist. Structural changes use a packaged relup or rolling
  replacement, and boot convergence prevents a restarted node from serving an
  older target.
- Staging remains the qualification environment for changes that require
  browser, distributed-cluster, failure-injection, migration, or configuration
  evidence before production promotion.

Read the [Forge hot loop runbook](docs/operations/forge-hot-loop.md) for the
current deployment contract and production evidence. Read the
[Forge cache recovery runbook](docs/operations/forge-cache-recovery.md) when a
repository read differs between fleet nodes or returns `503`.

## Architecture

The browser connects to one Phoenix and LiveView application. PostgreSQL is the
durable authority for product, authorization, work, and deployment state.
Provider APIs and GitHub are server-side dependencies behind explicit adapters;
their credentials never belong in browser state. BEAM processes, PubSub, and
LiveView assigns are recoverable projections of durable records.

Sarah is a persona and behavior package in the OpenAgents application, not a
private service boundary. Generic infrastructure uses the `OpenAgents`
namespace, while persona artifacts retain Sarah-specific identities where that
history is part of the contract.

## Interface system

The product uses Tailwind CSS, pinned vendored Basecoat component styles, the
OpenAgents style pack in `assets/css/openagents.css`, and reusable HEEx
components in `OpenAgentsWeb.UI`. The live component inventory is available at
`/components`; [docs/component-library.md](docs/component-library.md) records
the supported primitives and extension rules. Follow the
[icon policy](docs/ICONS.md) for the governed glyph tiers.

Fonts and icons are self-hosted. Do not add a remote font, icon font, second
component library, or unreviewed browser script.

## Local development

The application requires Elixir/OTP, PostgreSQL with pgvector, and Node.js for
the browser-side tests.

```sh
mix setup
mix phx.server
```

Before committing, run the fast repository checks:

```sh
mix precommit
```

Before pushing a release candidate, provision a disposable database and run
`ops/ci/gate.sh` as documented in
[the release deployment fallback runbook](docs/operations/release-deployment-fallbacks.md).
This repository deliberately has no hosted CI configuration.

Validate the isolated staging infrastructure without changing cloud state:

```sh
ops/staging/terraform.sh validate
```

Read the [isolated staging infrastructure runbook](infra/staging/README.md)
before you bootstrap, plan, or apply any staging resource.

## Contributing and source control

Read `AGENTS.md` before changing the application. Push accepted work to the
owned Forge. `MirrorWatch` maintains GitHub as the public mirror; do not treat
an independently pushed GitHub branch as production authority.

## License

OpenAgents is licensed under the GNU Affero General Public License v3.0. See
`LICENSE`.

Vendored third-party material keeps its own license and notices. In particular,
Basecoat is under `assets/vendor/basecoat/`, the Apps SDK icon set is under
`priv/icons/`, and self-hosted font notices are under `priv/static/fonts/`.
Review [the dependency and license inventory](docs/dependencies-and-licenses.md)
and `priv/licenses/THIRD_PARTY_NOTICES.md` when redistributing the application.
