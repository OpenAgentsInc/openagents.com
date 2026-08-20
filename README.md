# OpenAgents

OpenAgents is an AGPL-3.0 Phoenix application for building and operating
agent-backed software in public. This repository contains the complete product:
Sarah chat and voice, governed memory and tools, delegated work and connected
computers, issues and projects, the Git forge, and the deployment control plane.

The current architecture and trust boundaries are documented in
[docs/architecture.md](docs/architecture.md). The staged hardening work is
tracked in the
[integration hardening plan](docs/2026-08-20-integration-hardening-and-staging-readiness-recommendations.md).

## Capability status

No part of this repository is approved for production deployment yet.

### Implemented and locally gated

- GitHub OAuth, encrypted server-side GitHub token storage, sessions, and
  account-scoped data rights.
- Authenticated text chat with durable turns, provider receipts, tools, memory,
  delegated work, and connected-computer orchestration.
- Voice session, transcript, usage, recording, and operator-projection domains.
- Issues, comments, labels, milestones, projects, public status, changelog, and
  bounded source-browsing surfaces.
- Git HTTP, push receipts, promotion targets, build receipts, and local BEAM
  deployment primitives.
- An owned local test gate covering browser JavaScript, the Phoenix application,
  distributed cluster cases, merged coverage, and a disposable production
  release smoke test.

"Implemented" means the code and local tests exist. It does not mean the
feature has passed staging, security review, failure injection, or a soak.

### Disabled by default or staging-only

- Voice, recording, semantic recall, experimental program paths, and deployment
  workers remain controlled by runtime configuration.
- Direct BEAM loading, relup installation, rolling replacement, and boot
  convergence require isolated three-node staging proof before they can be
  enabled outside a disposable environment.
- The self-hosted forge is being hardened, but GitHub remains the canonical Git
  remote until the proof-gated cutover in ADR 0007.

### Planned or blocked on hardening

- Repository-backed tenant isolation for every issue and project record.
- Complete route-authority, token-lifecycle, recovery, build-isolation, and
  transactional fleet-deployment gates.
- Separate web and distributed staging lanes, a full regression matrix,
  failure-injection drills, and a 48-hour soak.
- Any production rollout. Production remains explicitly out of scope until the
  staging plan is complete and separately approved.

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
the current transition and extension rules.

Fonts and icons are self-hosted. Do not add a remote font, icon font, second
component library, or unreviewed browser script.

## Local development

The application requires Elixir/OTP, PostgreSQL with pgvector, and Node.js for
the browser-side tests.

```sh
mix setup
mix phx.server
```

Before committing, run the repository-owned gate:

```sh
mix precommit
```

Distributed, merged-coverage, relup, and release-smoke checks live under
`ops/` and are composed by the exact-SHA baseline gate while hardening is in
progress. This repository deliberately has no hosted CI configuration.

## Contributing and source control

Read `AGENTS.md` before changing the application. GitHub is temporarily the
canonical remote during staging hardening. The forge becomes canonical only
after the durability, mirror, restore, and deployment proofs in ADR 0007 pass.

## License

OpenAgents is licensed under the GNU Affero General Public License v3.0. See
`LICENSE`.

Vendored third-party material keeps its own license and notices. In particular,
Basecoat is under `assets/vendor/basecoat/`, the Apps SDK icon set is under
`priv/icons/`, and self-hosted font notices are under `priv/static/fonts/`.
Review those notices when redistributing the application.
