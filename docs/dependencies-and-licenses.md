# Dependencies and licenses

Date: 2026-08-20

Status: Current

`mix.lock` is the authoritative resolved dependency set. The release keeps
only production dependencies; development and test tools do not enter the
runtime image. `mix precommit` rejects retired Hex packages, known Elixir
advisories, and unused lock entries.

## Direct dependency inventory

| Dependency | Scope | Purpose | License |
| --- | --- | --- | --- |
| `phoenix`, `phoenix_html`, `phoenix_live_view` | Runtime | HTTP, HEEx, and LiveView product surfaces | MIT |
| `phoenix_ecto`, `ecto_sql`, `postgrex` | Runtime | PostgreSQL persistence and migrations | MIT; Apache-2.0 |
| `bandit` | Runtime | Phoenix HTTP server | MIT |
| `req` | Runtime | Governed outbound HTTP client | Apache-2.0 |
| `jason` | Runtime | JSON encoding and decoding | Apache-2.0 |
| `gettext` | Runtime | User-facing translation boundary | Apache-2.0 |
| `swoosh` | Runtime | Phoenix mail boundary and local mailbox | MIT |
| `mdex` | Runtime | Sanitized CommonMark rendering | MIT |
| `horde` | Runtime | Distributed registries and supervisors | MIT |
| `ra` | Runtime | Raft-backed cluster authority | Apache-2.0 or MPL-2.0 |
| `websockex` | Runtime | Outbound Realtime WebSocket adapter | MIT |
| `dns_cluster` | Runtime | DNS-based BEAM node discovery | MIT |
| `castle` | Runtime and build | OTP hot-upgrade release assembly | MIT |
| `telemetry_metrics`, `telemetry_poller` | Runtime | Metrics definitions and periodic VM measurements | Apache-2.0 |
| `phoenix_live_dashboard` | Runtime | Operator-only runtime inspection | MIT |
| `esbuild`, `tailwind` | Build and development | Owned JavaScript and CSS bundles | MIT |
| `heroicons` | Build | Documented second-tier icon fallback | MIT |
| `phoenix_live_reload` | Development | Local asset and template reload | MIT |
| `lazy_html` | Test | Structural HTML assertions | Apache-2.0 |
| `mix_audit` | Development and test | Elixir advisory database check | BSD-3-Clause |

Transitive packages and operating-system packages are recorded in the
CycloneDX SBOM for each image. Do not copy this table into a deployment receipt;
generate the SBOM from the exact image digest instead.

## Required checks

Run these checks on owned infrastructure:

```console
MIX_ENV=test mix hex.audit
MIX_ENV=test mix deps.audit
MIX_ENV=test mix deps.unlock --check-unused
```

`mix precommit` runs all three. Update dependencies in a dedicated change when
`mix hex.outdated --all` reports an available version; an available major
version is review input, not an automatic upgrade.

## Release inventory

Generate an SBOM from the exact local or registry image reference:

```console
ops/staging/generate-sbom.sh <image-reference> <evidence-directory>/sbom.cdx.json
```

The script uses digest-pinned Syft `v1.51.0`, resolves the scanned image digest,
writes CycloneDX JSON atomically, and writes a receipt with the source commit and
SBOM checksum. Retain both files with the staging evidence.

## Vendored asset notices

The release includes the notice index at
`priv/licenses/THIRD_PARTY_NOTICES.md`. Its source licenses remain at these
paths:

- Basecoat: `assets/vendor/basecoat/LICENSE.md`.
- Apps SDK UI icons: `priv/icons/LICENSE`.
- Heroicons fallback: `priv/licenses/HEROICONS-LICENSE`.
- Geist Sans and Geist Mono: `priv/static/fonts/LICENSE`.
- Titillium Web: `priv/static/fonts/LICENSE-titillium-web`.
- GitHub mark source and trademark limits: `priv/brand/README.md`.
