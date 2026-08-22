# Deployment modes

Date: 2026-08-22

Status: Active in production. Forge tries a direct hot load first, then an
operator uses a compatible relup or an immutable rolling replacement when the
classifier refuses the direct path.

OpenAgents has three deployment classes.

| Update characteristic | Deployment path | Initiation | Examples |
| --- | --- | --- | --- |
| Allowlisted BEAM-only change | Direct hot load | Automatic after promotion | LiveViews, controllers, components, templates compiled into web modules, and status-page changes |
| Compatible application-level change | Relup | Operator fallback after exact-SHA qualification | Core Elixir modules, explicitly supported process-state upgrades, and coordinated application-version transitions |
| Runtime or infrastructure change | Full image build and rolling replacement | Operator fallback after exact-SHA qualification | Dependencies, configuration, migrations, assets, OTP, native libraries, and Docker changes |

The classifier evaluates the complete candidate. It does not hot-load the
eligible portion of a mixed change. If one changed path, toolchain identity,
or module requires a fallback, Forge refuses the entire direct transaction and
marks the target `needs_rolling_replace`.

## Direct hot load

This is the fastest path. It works when all of these conditions hold:

- The change produces only modified BEAM modules, or an added module that does
  not change the application specification.
- Every changed module appears in the hot-load allowlist.
- The change does not delete a module.
- The application version, application specification, Elixir version, OTP version, ERTS version, and `mix.lock` remain unchanged.
- The commit does not change any structurally classified path.

The current allowlist includes:

- `OpenAgentsWeb.*`
- `OpenAgents.Forge.Browse`
- `OpenAgents.Forge.MirrorWatch`
- `OpenAgents.Changelog`
- `OpenAgents.Scratch.*`
- `OpenAgents.BuildInfo`

Good direct-load candidates include:

- LiveView behavior and rendering
- Controllers and API response logic
- UI components
- HEEx templates
- Status-page presentation
- Request validation inside web modules
- Small fixes to the explicitly allowlisted Forge modules
- Published documentation under `priv/docs/**`

Published documentation is a deliberate exception to the general `priv/**`
rule. `OpenAgentsWeb.DocsCatalog` embeds every catalogued Markdown page and
declares those files as external compiler resources. A documentation edit
therefore changes an allowlisted BEAM module, and boot convergence can restore
the exact documentation snapshot after a node restart. Other `priv/**`
changes remain structural.

The deployment builds only the changed BEAM files, verifies the artifact and
manifest, prepares every node, loads the candidate on a canary, verifies the
canary, applies the candidate across the fleet, and commits the transaction.
It retains prior object code for an exact transactional rollback. Boot
convergence also caches the live artifact so a restarted node restores the hot
revision before it becomes ready.

It does not rebuild Docker images or restart the application.

Direct hot loading does not run OTP `appup` instructions or transform existing
process state. Keep stateful domain and supervision changes out of this path
unless the allowlist and production proof explicitly admit them.

## Relup

Use a relup when the update remains compatible with the installed Erlang runtime but needs a complete OTP release transition.

Potential relup candidates include:

- Core `OpenAgents.*` modules outside the direct allowlist
- GenServer state-shape changes that implement an explicit `code_change/3`
- Supervision-tree changes that the generated `appup` and the installed OTP
  applications can validate
- Coordinated updates across several applications or stateful processes
- Changes that need an application patch-version transition
- Code changes whose safety requires forward, reverse, and re-upgrade instructions

A relup installs a complete release through OTP's `release_handler`. It can
transform running process state and preserve process identity. That makes it
appropriate when loading a new BEAM file alone would not correctly update
existing state.

Relups require more validation than direct loads:

- A new patch version, such as `0.2.0` → `0.2.1`
- Valid generated `appup` instructions
- Compatible state-schema direction
- Matching OTP and target system
- Exact artifact and revision digests
- A working reverse transition
- Staging or disposable-node installation proof

A relup does not necessarily require a new serving image, but it does require building and validating complete release packages.

The classifier does not automatically manufacture or install a relup. It
records the direct-path refusal, and an operator builds the exact source and
target release pair, runs the 13-stage exact-SHA gate, and starts the
one-node-at-a-time coordinator. After every node returns `permanent`,
`OpenAgents.Forge.Targets.finish_relup_deployment/2` validates the package,
revisions, versions, duration, artifact digest, and node results before it
atomically settles the original Forge target and writes the deployment
receipt.

A valid generated relup can still fail OTP's live installation checks. In the
2026-08-22 production drill, `0.2.0` to `0.2.1` upgraded all three nodes in
53.876 seconds. The following `0.2.1` to `0.2.2` attempt stopped on its first
node when `release_handler` could not inspect `libring`'s
`DynamicSupervisor`. The node stayed on the known-good release, the
coordinator did not touch the other two nodes, and the operator used the
rolling-image fallback. Treat relup eligibility as something the package and
live preflight prove, not something a source diff alone guarantees.

## Full image build and rolling replacement

The classifier immediately treats these paths as structural:

- `mix.exs`
- `mix.lock`
- `config/**`
- `assets/**`
- `priv/static/**`
- `priv/repo/migrations/**`
- `priv/**`, except the embedded `priv/docs/**` catalog
- `rel/**`
- `native/**`
- `c_src/**`
- `Dockerfile` and `Dockerfile.*`
- Files ending in `.so`, `.nif`, `.dll`, or `.dylib`

A full build is also required when any of these identities change:

- Elixir
- OTP
- ERTS
- Application specification
- Dependency lock
- Native runtime
- System packages

Concrete examples include:

- Adding or upgrading a Hex dependency
- Changing runtime environment-variable handling
- Adding a database migration
- Rebuilding JavaScript or CSS
- Changing Postgres, networking, or endpoint configuration
- Adding an NIF or Rustler component
- Changing fonts or static images
- Upgrading Erlang or Elixir
- Changing the Docker image or installed OS packages

These changes produce a new immutable application image. The rollout replaces one node at a time while the other two continue serving traffic.

Before replacing a node, the coordinator requires an exact-SHA gate receipt,
an immutable image digest, two remaining healthy nodes, and a matching fleet
snapshot. It drains the selected node, replaces it, and verifies its revision,
release, database access, cluster membership, and load-balancer health before
continuing. It then settles the original target with a rolling-replacement
receipt. A failed relup does not authorize skipping these checks.

## Important conservative boundaries

Some changes could theoretically be hot-loaded but currently are not allowed directly.

For example, changing `OpenAgents.Accounts` produces ordinary BEAM code, but that namespace is not on the direct allowlist. The loop therefore refuses direct loading and routes the update to the fallback path. That refusal is intentional until that module class has production hot-load evidence.

Module deletion also forces a fallback. Loading new code does not reliably purge deleted modules or prove that no running process still references them.

Database migrations always require the full-release path because application code and database schema must remain compatible while old and new nodes overlap.

Changing only comments, uncompiled internal documentation, or another file
that produces no runtime artifact can result in a zero-module build. Forge can
record that target as live without changing running code, but operators must
not interpret a zero-module receipt as proof that an unembedded file appeared
inside an existing container.

## Version policy

Keep the application version unchanged for direct BEAM transactions. Use the
next patch version for a compatible full relup package. Change the minor
version only for a planned compatibility or feature boundary. Never publish
different release bytes under an existing version.

The application version and source revision serve different purposes. A new
commit does not require a new application version when the direct path can
deploy it.

After a full release changes the application version, update the default in
`mix.exs` and the plain-release default in `rel/openagents.appup.exs` to the
same version. The Forge builder compiles the candidate application
specification from that source default, and each deployment node compares it
with its running release. Leaving the source default behind causes every later
direct candidate to fail with `runtime_toolchain_mismatch`.

## Receipts and status

`/status` and `/api/status` expose the active Forge lane, current target,
deployment class, recent targets and deployments, push-to-live timing, boot
convergence, and Forge-to-GitHub mirror freshness. The displayed fallback
order is `direct,relup,rolling`.

Every successful path must leave the original promoted target in `live` with
an immutable deployment receipt. A direct refusal remains visible as
`needs_rolling_replace` until the relup or rolling coordinator settles it. Do
not mark a target live because an operator observed healthy traffic.

## Practical rule

Use this decision order:

1. **Direct:** Only allowlisted Elixir web or approved Forge modules changed.
2. **Relup:** The change is still pure, runtime-compatible Elixir, but it affects broader or stateful application behavior.
3. **Rolling image:** The change affects dependencies, configuration, data schema, assets, native code, the runtime, or the container.

The loop makes this decision from the actual Git diff, compiled module digests, and toolchain identity. It does not rely on the commit message or an operator guessing correctly.

For operating procedures and recovery details, see:

- [Forge hot loop runbook](operations/forge-hot-loop.md)
- [Release deployment fallbacks](operations/release-deployment-fallbacks.md)
- [Transactional Forge deployment](operations/forge-transactional-deployment.md)
