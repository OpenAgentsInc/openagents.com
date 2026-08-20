# SCV planning

Date: 2026-08-20

Status: OpenCode SCV environment and bounded report path implemented and proven
locally; three shared-project read-only audit SCVs deployed; durable
coordination, durable tool effects, isolated staging, and autonomous deployment
remain disabled

## Outcome

Build an Elixir-native, durable SCV that continuously finds bounded codebase
improvements, implements them in isolated repository workspaces, proves each
candidate against an exact Git SHA, and submits admitted candidates to the Forge
deployment pipeline.

SCV means Space Construction Vehicle. Use SCV consistently in code,
documentation, configuration, and the interface. Do not introduce another name
for this subsystem.

An SCV is a logical long-running service, not one immortal process or one
unbounded model response. OTP processes may restart, provider calls may end, and
workspaces may be discarded. PostgreSQL, Forge commits, immutable artifacts, and
receipts preserve the SCV's identity and progress across those events.

The intended end state includes automatic deployment. The first implementation
must not bypass the repository's current safety contracts:

- GitHub remains canonical until the proof-gated cutover in
  [ADR 0007](decisions/0007-cut-over-to-forge-canonical-source-control-after-proof.md).
- Forge fleet deployment remains disabled until the isolated staging gates in
  the [integration hardening plan](2026-08-20-integration-hardening-and-staging-readiness-recommendations.md)
  pass.
- `SELF-EDIT-001` currently requires a human promotion. Enabling an SCV to
  promote a candidate requires an explicit invariant and architecture amendment,
  a typed service principal, and a policy-bound promotion receipt. Do not encode
  an SCV identity in the existing free-form `promoted_by` field and call that
  authorization.

The recommended first milestone is a continuously running, propose-only SCV
that uses OpenCode inside an isolated worker. Qualify the worker against the
OpenCode repository before using the same runtime to improve `openagents.com`.
The recommended first autonomous milestone is staging-only deployment of a
narrow, low-risk change class. Production autonomy is a later admission, not a
configuration toggle hidden inside the first release.

### Model capability boundary

SCVs use `openai/gpt-5.6-luna` with `low` reasoning by default. You may select
`none` for latency-sensitive, measured workloads. Do not run implementation or
production-code tasks with GPT-5.4. GPT-5.6 is the minimum admitted model family
for code generation by an SCV.

Model capability does not grant infrastructure authority. A code-writing SCV
must still use an isolated workspace, repository-scoped principal, durable
effect records, required tests, and Forge promotion policy before its code can
reach staging or production.

## SCV runtime boundary

Define an SCV as the durable execution and supervision contract. Do not define
an SCV as a container, OpenCode session, model, or tool catalog. The internal
runtime deploys an SCV run. Each run selects one implementation driver and one
execution environment.

| Boundary | Responsibility |
| --- | --- |
| SCV | Owns identity, objective, policy, capabilities, lifecycle, budgets, events, receipts, cancellation, artifacts, and Forge handoff |
| Driver | Adapts one coding implementation, such as OpenCode or a native Elixir tool loop, to the SCV contract |
| Environment | Supplies one digest-addressed runtime image or owned host with declared language and system capabilities |
| Runner | Starts and supervises the selected driver inside the environment |
| Tool catalog | Defines the typed effects available to a native driver; an external driver may retain its protocol only when the SCV maps it to the same policy and event boundary |

An SCV run normally binds one driver to one worker. A durable SCV campaign may
coordinate several runs with different drivers or environments. Do not place
several independent repository writers inside one worker and call the container
an SCV.

Expose two tool surfaces:

- The internal runtime uses SCV control tools to start, inspect, cancel, and
  collect artifacts from SCV runs.
- A native SCV driver uses admitted coding tools for workspace inspection,
  edits, commands, tests, and Git operations. OpenCode retains its own protocol
  behind the same capability policy until the durable sidecar replaces its
  direct effects.

This split gives every implementation one operational contract without forcing
OpenCode, a native Elixir driver, and future coding runtimes to share one model
or tool-loop implementation.

## Local implementation checkpoint

The repository now contains a complete direct-process SCV boundary and the
first container environment. This implementation proves driver dispatch and
worker execution without enabling a durable coordinator, repository write
authority in staging, worker registration, Forge promotion, or deployment:

- `OpenAgents.SCV.Run` binds one objective to an admitted driver, environment,
  permission profile, capability set, and runner.
- `OpenAgents.SCV.Driver.OpenCode` adapts OpenCode to the common SCV run and
  event contract.
- `OpenAgents.SCV.Environment` declares the `opencode-core` capabilities
  separately from the driver.
- `OpenAgents.SCV.Runner.Local` supervises the driver as a direct process in the
  current environment. A container scheduler may place this runner inside a
  digest-addressed worker.
- `OpenAgents.SCV.Worker` accepts the staging environment contract, admits only
  read-only OpenCode runs, streams JSON events, writes one terminal result, and
  exits with the run status.
- `OpenAgents.SCV.Executor.OpenCode` starts one bounded OpenCode process with an
  isolated home, XDG roots, SQLite database, operator-owned configuration, and
  explicit permission profile.
- `OpenAgents.SCV.OpenCodeEvents` normalizes content-free event counts, tool
  outcomes, token classes, and estimated cost.
- `OpenAgents.SCV.OpenCodeReport` collects only redacted OpenCode text events
  into a versioned report capped at 32 KiB. It never includes tool output or
  diagnostic lines.
- `OpenAgents.SCV.ResourceSampler` observes the direct OpenCode process from the
  host and records RSS and CPU samples.
- `mix openagents.scv.opencode` exposes the adapter for local qualification.
- `ops/scv/images/opencode-core/Dockerfile` defines the first complete
  multi-architecture environment with a pinned Debian runtime, Elixir release,
  Node.js, Bun, Python, Git, native build tools, and OpenCode.

The executor emits `openagents.scv.event.v1` records while the run is active.
Callers can supply an `event_sink` function, and the executor also emits the
same records through the `[:openagents, :scv, :event]` telemetry event. The Mix
task prints lifecycle events, five-second resource heartbeats, and normalized
OpenCode events to standard error. `--diagnostic-logs` also prints redacted
OpenCode logs as OpenCode produces them. Final JSON remains on standard output,
so an operator or process can consume the receipt without waiting blindly for
the command to finish.

The terminal worker result now includes `openagents.scv.report.v1`. The executor
applies its run-specific provider-key redaction before the report parser sees a
line, preserves valid UTF-8 at the byte limit, and marks truncated reports. This
path makes a read-only audit result consumable through Cloud Logging. It does
not replace durable artifact storage: a write-capable SCV must persist and
acknowledge the report, event artifact, and their digests before it reports
success.

The adapter writes the bounded prompt to a mode `0600` scratch file and gives
that finite file to OpenCode as standard input. This keeps prompt content out of
the process argument list and delivers EOF after the prompt. OpenCode reads a
non-terminal standard input stream as additional prompt content and otherwise
waits indefinitely when an Erlang port keeps that stream open. Keep the finite
input wrapper as part of the adapter contract and retain its regression test.

OpenCode treats `XDG_CONFIG_HOME` as a parent directory and
`OPENCODE_CONFIG_DIR` as the OpenCode configuration directory itself. The
adapter uses `<XDG_CONFIG_HOME>/opencode` for the latter. Pointing both variables
at the parent creates two dependency locations and can trigger an unseeded
background install. A trusted local `config_seed` may copy only dependency and
lock files into the isolated directory; it never copies OpenCode configuration
or authentication state.

### GPT-5.6 local qualification receipt

On 2026-08-20, installed OpenCode `1.18.5` ran a read-only SCV against OpenCode
commit `b155b15694dbcc6768f11d2f25cc2bdd1f738ab4` with
`openai/gpt-5.6-luna` and `low` reasoning. The run read `package.json` and
returned the package name and a one-sentence repository description without
changing the checkout.

SCV run `f4955a8b-d0a1-42ad-bc8b-acf4c6cb48b8` succeeded in 5,475
milliseconds. It emitted six normalized events, completed one `read` call,
used 6 input, 59 output, and 11 reasoning tokens, and reported no truncation.
The terminal receipt recorded the exact model and reasoning effort. This run
qualifies the local model-selection and event path. It does not authorize an SCV
to write to a shared repository or deploy code.

### Historical GPT-5.4 read-only run

On 2026-08-20, the adapter ran installed OpenCode `1.18.5` against the inspected
OpenCode `dev` commit `b155b15694dbcc6768f11d2f25cc2bdd1f738ab4` with model
`openai/gpt-5.4-mini` and read-only permissions. The fixed task read
`package.json` and `README.md` without changing the checkout.

The terminal receipt recorded:

- `succeeded` with exit status `0` in 7,845 milliseconds;
- eight structured events across two model steps;
- two completed `read` tool calls and no tool errors;
- 7,981 input, 144 output, 74 reasoning, and 3,584 cache-read tokens;
- an estimated cost of `$0.00723555`;
- 622,215,168 bytes of peak direct-process RSS and 141.9% maximum sampled CPU;
- 40,855 captured output bytes with no truncation.

The run streamed lifecycle, diagnostic, tool, and resource events before it
wrote the terminal summary. The summary and redacted event artifact use mode
`0600`; the executor deletes its scratch home after termination. The supplied
provider credential entered through silent terminal input and did not appear in
the command arguments, summary, or artifact.

A separate `workspace_write` proof ran only against a disposable Git fixture.
It changed `message.txt` from `before` to `after`, emitted one completed
`apply_patch` tool event, produced no malformed event lines, and left every
other file unchanged. This validates local edit mechanics but does not admit the
write profile for a durable or autonomous SCV.

This proof does not satisfy the final worker boundary. It runs the Elixir
controller and OpenCode process on the trusted development host, measures only
the direct OpenCode process, terminates only that direct process, and treats the
whole OpenCode session as one uncertain external effect. Before an SCV receives
write authority, move this adapter into the admitted worker, enforce process
groups or cgroups, replace reusable provider credentials with a run-scoped
inference grant, and persist each tool effect before execution.

### Run the local adapter

Set `OPENAI_API_KEY` in the process environment without adding it to shell
history, then run:

```console
OPENCODE_BIN=/absolute/path/to/opencode \
OPENCODE_CONFIG_SEED=/absolute/path/to/trusted/opencode-config \
mix openagents.scv.opencode \
  --repo /absolute/path/to/target \
  --model openai/gpt-5.6-luna \
  --reasoning-effort low \
  --timeout-seconds 180 \
  --diagnostic-logs \
  --prompt 'Inspect the requested files without changing them.' \
  --json
```

Omit `OPENCODE_CONFIG_SEED` when the isolated OpenCode installation can resolve
its dependencies during an admitted setup phase. Do not use `--write` against a
valuable checkout. The current write profile enables only OpenCode's edit tool;
it does not yet provide the durable per-effect barrier required for candidate
construction.

### Proven image build

Run `ops/scv/images/build-opencode-core.sh` to build the native architecture as
`openagents/scv-opencode-core:local`. The build pins its Debian and Elixir base
digests, Debian snapshot, Hex, Rebar3, Node.js, Bun, and OpenCode. It produces a
self-contained Elixir release and the OpenCode toolchain in one image.

Use `ops/scv/images/build-opencode-core-cloud.sh` to build a clean committed
source tree on native `linux/amd64` Cloud Build infrastructure and publish it to
the immutable staging repository. Do not use an emulated cross-build as staging
evidence when the language runtime fails under the emulation layer.

On 2026-08-20, the complete ARM64 image ran as UID and GID `10001` through the
Elixir SCV process role. The SCV selected the `opencode` driver and
`opencode-core` environment, inspected the source baked into the image, and
made no changes. The worker emitted lifecycle records, two-second heartbeats,
normalized OpenCode events, two completed `read` calls, resource samples, and
one terminal worker result.

The terminal result recorded:

- `succeeded` in 9,387 milliseconds;
- eight normalized OpenCode events and no tool errors;
- 9,060 metered tokens and an estimated cost of `$0.00657015`;
- 706,650,112 bytes of peak direct-process RSS and 188% maximum sampled CPU;
- 16,908 captured bytes with no truncation.

The image contains no Docker client or socket. The SCV process role starts no
Phoenix endpoint, application Repo, Forge service, or deployment coordinator.
It accepts only the staging environment and read-only permission profile. This
proof does not admit repository writes or autonomous deployment. Add the
durable worker protocol, process-tree or cgroup enforcement, run-scoped
credential proxy, and effect-persistence sidecar before enabling writes.

### Proven staging qualification

On 2026-08-20, Cloud Build built commit
`09a775b83fa05b6a92854b0ad1f7b5c23b3aee88` on native `linux/amd64`
in build `9721075d-ed17-491c-af9a-85be8f46bf52`. Artifact Registry stored the
image as
`sha256:ee2a74660faa6137e4021a2870380f5977796d33ca9dcaabcb0b958f35e0e36b`.
Cloud Run job execution `openagents-scv-staging-wrppq` ran that digest with one
task, zero retries, and the dedicated
`openagents-scv-staging@openagentsgemini.iam.gserviceaccount.com` identity.

The job configuration referenced only the staging provider secret. It did not
contain database, GitHub, Forge, release-cookie, deployment, or general cloud
credentials. The SCV emitted `run_preparing`, process-start, heartbeat,
normalized OpenCode, process-finish, run-finish, and terminal worker-result
records through Cloud Logging before it exited with status `0`.

The terminal result recorded:

- `succeeded` in 11,008 milliseconds;
- eight normalized OpenCode events, two completed `read` calls, and no tool
  errors;
- 5,520 input, 173 output, 158 reasoning, and 3,072 cache-read tokens;
- an estimated cost of `$0.0058599`;
- 666,734,592 bytes of peak direct-process RSS, 114% maximum sampled CPU, and
  44 resource samples with no sampling errors;
- 16,910 observed and captured bytes with no truncation;
- event artifact digest
  `sha256:506e4cbd02eb19abd5078d73832be45049b707e06f8c73ef1b4ef7dcc53c1e83`.

This result qualifies the complete read-only SCV image in the existing shared
Google Cloud project. It does not pass the isolated-staging gate described in
this plan and does not authorize writes, Forge handoff, or autonomous
deployment.

The current staging worker now uses `openai/gpt-5.6-luna` with `low` reasoning.
Cloud Build `655a2fe6-8173-4686-9533-f3a1733942b0` built revision
`c7175ed8a8781ea1aab7d204623a28ac45a70bc1` as image digest
`sha256:156ff9f51e955d03b4795af8e2bb190a6c4f9962cc7942a6dcc0586e9b48b0a9`.
Parity execution `openagents-scv-parity-audit-p5mkz` proved the exact model and
reasoning effort in its live preparation event and terminal result. Its bounded
report arrived as three ordered structured JSON chunks without truncation. See
[Qualify an SCV in staging](operations/scv-staging-qualification.md) for the
complete receipt.

## Goals

An SCV should:

- Operate without a browser conversation or a person keeping a process alive.
- Select work from explicit evidence instead of producing undirected code churn.
- Use a versioned, digest-addressed SCV program and policy revision.
- Read and change the exact repository that Forge recognizes as source truth.
- Use an isolated, secret-free workspace with a complete compiler and test
  toolchain.
- Route work to capability-described workers so an SCV can use Elixir, Bun,
  Node.js, Python, Rust, browser, and platform-specific toolchains without
  adding those runtimes to the Phoenix release.
- Preserve every model request, tool decision, command result, commit, gate,
  promotion, deployment, verification, and rollback as bounded evidence.
- Collect host-observed resource use, benchmark samples, and OpenCode usage
  statistics with enough provenance to compare equivalent runs.
- Recover after node, process, provider, and executor failures without repeating
  an uncertain external effect.
- Enforce token, cost, time, CPU, memory, disk, command, diff, commit, and
  deployment budgets outside the model.
- Keep one linear improvement history so later work includes earlier admitted
  improvements.
- Treat no change, refusal, and rollback as valid outcomes.

## Non-goals

The first SCV should not:

- Replace the existing user-scoped coding-job experience.
- Run as a conversational persona or compose user conversation memory into its
  instructions.
- Receive production credentials, user conversation content, profile memory,
  voice transcripts, or unrestricted database access.
- Edit its own authority policy, deployment allowlist, release gates, or
  evaluator and then approve that edit.
- Modify production data, perform destructive migrations, rotate secrets,
  change billing policy, or widen an authorization boundary.
- Run several repository-writing SCVs concurrently.
- Treat workers with different images, resource classes, operating systems,
  toolchain versions, or cache states as interchangeable benchmark hosts.
- Deploy a structural or unclassified candidate automatically in the first
  autonomous release.
- Treat a passing model-authored test as sufficient evidence of correctness.

## Existing foundation

The repository already implements much of the mechanical foundation. Reuse the
contracts, but do not force an SCV into a user-scoped abstraction whose identity
or bounds are wrong.

| Existing capability | Reuse | Required SCV change |
| --- | --- | --- |
| `OpenAgents.Providers.Provider`, `OpenAgents.Providers.Request`, and `OpenAgents.Providers.OpenAI` | Reuse the provider-neutral stream and event normalization | Add an SCV-specific client and program. Do not use the conversational context composer. Admit SCV-specific output and timeout bounds instead of relying on the text-turn defaults. |
| `OpenAgents.Tools.Registry`, `OpenAgents.Tools.Runner`, and tool receipts | Reuse schema validation, authority checks, cancellation, timeout handling, output bounds, and normalized outcomes | Add an `scv` execution surface and an SCV-only tool catalog. The model must never receive promotion, policy-edit, or deployment tools. |
| `OpenAgents.Work.JobServer` and `OpenAgents.Work` | Reuse the durable-step, generation-fence, forced-report, and recovery patterns | Do not add `scv` to `work_jobs.kind`. Work jobs are conversation- and owner-scoped, have a ten-minute limit, run the coding-lieutenant role program, and terminate after one report. |
| `OpenAgents.Work.Coding` and repository tools | Reuse exact-match edit semantics, safe path resolution, commit receipts, and branch confinement | Replace per-user approval receipts and the fixed `openagents/job-<id>` lifecycle with SCV service authority, durable run workspaces, richer Git inspection, and full test execution. |
| `OpenAgents.Inference` | Reuse metering concepts and server-held provider credentials | Add a service-principal ledger or generalize grants to identify an SCV. Do not invent a visitor, conversation, or machine to satisfy the current schema. |
| `OpenAgents.Forge.Pushes` and the WAL | Reuse the push acknowledgment barrier and immutable push receipts | Give an SCV executor a repository-scoped, branch-scoped credential. It must not receive the operator token or a credential that can update arbitrary refs. |
| `OpenAgents.Forge.Builder` and the build worker | Reuse isolated exact-SHA builds, structural classification, artifact verification, and bounded output | Keep the web release compiler-free. Run SCV commands in a separate worker identity and make candidate gate receipts durable outside one worker's `.git` directory. |
| `OpenAgents.Forge.Targets` and deployment coordinators | Reuse newest-target fencing, direct-load transactions, relup, rolling replacement, boot convergence, and receipts | Add a policy-authorized SCV promotion path that remains separate from a push. Preserve human promotion for every class outside the admitted SCV policy. |
| `OpenAgents.Incidents` | Reuse typed failures, bounded context, recurrence tracking, and nonrecursive repair principles | Admit sanitized incidents as possible work-item evidence. Never expose private incident context or allow a failed SCV to recursively create another SCV. |
| Exact-SHA release gate | Reuse `mix precommit`, focused tests, release smoke, direct-load, relup, and rolling proofs | Define which gate is mandatory for each risk class. Store the exact gate definition digest so an SCV cannot weaken the gate in the same candidate. |

The existing coding-job integration test proves the sequence through a pushed
branch and deliberately stops before promotion. An SCV should extend that
receipt chain instead of replacing it with a less governed shortcut.

## Separate bounded context

Create an `OpenAgents.SCV` bounded context. Keep generic SCV control-plane code
out of `OpenAgents.Work` and keep persona-specific code out of `OpenAgents.SCV`.

The context should own:

- durable SCV identity and policy revision;
- work discovery and admission;
- run leases and generation fencing;
- SCV program composition;
- provider continuations and tool-step receipts;
- executor requests and responses;
- repository workspace lifecycle;
- candidate and gate decisions;
- policy-authorized promotion requests;
- post-deployment observation and rollback decisions;
- budgets, circuit breakers, and operator controls.

Forge should continue to own Git, build, target, deployment, rollback, and boot
convergence. An SCV proposes source and presents policy evidence. Forge decides
whether an exact SHA can become a target and whether that target becomes live.

## Architecture

```text
sanitized evidence and operator work
                |
                v
      SCV work-item admission
                |
                v
   durable SCV coordinator and lease
       |                    |
       | provider events    | typed executor requests
       v                    v
server provider adapter   capability scheduler
                                   |
                 +-----------------+-----------------+
                 |                 |                 |
                 v                 v                 v
          OpenCode driver    OpenCode driver     native driver
                 |                 |                 |
                 v                 v                 v
          core environment   browser environment Rust environment
                 |                 |                 |
                 +-----------------+-----------------+
                                   |
                                   |-- exact Forge checkout
                                   |-- bounded file tools
                                   |-- bounded command runner
                                   |-- disposable database and services
                                   `-- no production secrets
                                   |
                                   v
                         SCV candidate commit and push
                                   |
                                   v
                        immutable exact-SHA gate receipt
                                   |
                                   v
                     host policy and promotion receipt
                                   |
                                   v
                    Forge build and deployment pipeline
                                   |
                                   v
                    post-deployment verification window
                         |                     |
                         v                     v
                    admit result       promote predecessor
```

### Runtime placement

Keep the durable coordinator Elixir-native. Implement its lifecycle with OTP,
Ecto, and supervised tasks. Do not make an external coding CLI the SCV's
authority or durable state machine.

Run candidate code and build commands in a separate SCV worker container or
owned worker VM. Run an Elixir/OTP worker release there with a separate runtime
identity and mounts from the Phoenix release. Start only the worker supervision
tree; do not start the Phoenix endpoint, application Repo, Forge control plane,
or deployment coordinators. This preserves the Forge build-lane rule that the
web release receives no compiler, Docker socket, or general command-execution
authority.

The worker needs:

- read access to exact Forge objects;
- write access only to an SCV run ref;
- access to an atomic request and response channel;
- an ephemeral workspace, build cache, and disposable database;
- bounded CPU, memory, disk, process count, and wall-clock time;
- no production database URL, release cookie, cloud credential, Forge operator
  token, or user credential;
- no network by default, except the narrow internal endpoints required for
  Forge and coordinator communication.

Candidate code is untrusted during evaluation even though the worker runs in an
owned environment. Tests and Mix tasks can execute arbitrary repository code.
Do not mount any credential that candidate code could read or transmit.

## OpenCode as the first driver

Use OpenCode for the first end-to-end SCV worker implementation. This validates
non-Elixir execution, long model-driven runs, structured events, permission
handling, a large polyglot repository, and measurable performance work before
the SCV targets `openagents.com` itself.

Keep these milestones separate:

1. **Environment qualification:** Build the OpenCode worker image, compile and test
   the inspected OpenCode source, exercise one bounded OpenCode session, and
   collect resource and benchmark evidence without pushing a candidate.
2. **Self-targeting proof:** Use the read-only admitted OpenCode driver to fix
   a seeded OpenCode defect in the separate target checkout. Stop at a
   propose-only run ref.
3. **Product pilot:** Use the qualified OpenCode driver and environment to improve
   `openagents.com`, pass its Elixir and Forge gates, and keep promotion human
   controlled.

Passing runtime qualification does not admit an OpenCode candidate, and passing
the self-targeting proof does not authorize an `openagents.com` deployment.
Mirror the inspected OpenCode commit into a dedicated Forge qualification
repository and keep its run refs internal. Do not push a self-targeting proof to
the upstream OpenCode repository or treat Forge as upstream authority.

### Inspected baseline

This plan uses the OpenCode `dev` branch at commit
`b155b15694dbcc6768f11d2f25cc2bdd1f738ab4` as its inspected baseline. The
repository is a Bun-first TypeScript monorepo, not a generic Node.js project.
Its relevant contracts include:

- Bun `1.3.14` from the root `packageManager` declaration;
- Node.js 24 in continuous integration, with Node.js `24.15` used for the
  Playwright path because the repository records a Chromium extraction issue
  with the next patch release;
- Ubuntu 24.04 for the primary Linux test environment;
- Python 3 and `setuptools` for dependency compatibility;
- native build tools, `pkg-config`, Git, OpenSSH client, `curl`, certificates,
  `jq`, `ripgrep`, `unzip`, `xz-utils`, and `zip`;
- package-scoped tests and type checks, because the root test configuration
  intentionally refuses test execution;
- Rust stable for native and desktop work, plus GTK, WebKit, and Tauri system
  packages for Linux desktop builds;
- Playwright Chromium and its system dependencies for application end-to-end
  and performance work;
- Windows and macOS runners for complete platform and release coverage.

OpenCode already publishes Linux container layers for a base toolchain,
Bun plus Node.js, Rust, Tauri Linux, and publishing. Reuse their pinned versions
as input evidence, but build and sign SCV-owned images. Do not trust a mutable
tag or let repository code select the worker image.

### Trust boundary

OpenCode is a driver inside an SCV worker. It is not an environment, SCV
coordinator, lease authority, policy engine, receipt store, or promotion
authority. The Elixir control plane owns those responsibilities even when
OpenCode manages the model and tool loop for one run.

When an SCV works on OpenCode, keep two separate copies:

- Install the admitted OpenCode runtime under a read-only path such as
  `/opt/scv/opencode/bin/opencode`. Bind its version to the worker image digest.
- Check out the target OpenCode SHA under the disposable writable workspace.
  Treat every file and executable produced there as candidate code.

The target checkout must not replace the admitted runtime during a run. A gate
may build and execute the candidate OpenCode binary as an untrusted test
artifact, but that binary cannot control the run, approve permissions, write
receipts, or evaluate its own gate.

### First worker image

Build `scv-opencode-core` before creating generic language images. The image is
the first executable SCV milestone and should contain:

| Layer | Pinned contents |
| --- | --- |
| Operating system | Digest-pinned Debian Trixie from one dated snapshot for the build and runtime stages; use a separate Ubuntu qualification environment when exact OpenCode CI parity matters |
| JavaScript runtimes | Bun `1.3.14` baseline build, Node.js `24.15`, and Corepack |
| Native support | Python 3, `setuptools`, `build-essential`, `pkg-config`, `libgcc`, and `libstdc++` |
| Repository tools | Git, OpenSSH client without credentials, `curl`, certificates, `jq`, `ripgrep`, `unzip`, `xz-utils`, and `zip` |
| SCV runtime | A self-contained Elixir/OTP worker release with ERTS, a pinned read-only OpenCode binary, and cgroup and process-tree measurement support |
| Runtime identity | An unprivileged UID, empty home and XDG roots per execution, a read-only root filesystem, and a bounded writable workspace and cache |

Do not include Chromium, Rust, a Docker daemon or socket, a cloud CLI,
credential helpers, an SSH agent, or production credentials in this first
image. Build dependencies while the image build has admitted network access.
Run candidate commands without general network access.

Address the image by its manifest digest. Produce an SBOM and record the source
SHA, Dockerfile digest, base image digest, OpenCode version, package-manager
lock digest, toolchain versions, and build receipt. Forge should admit that
manifest before any worker registers with it.

Use a multi-stage build. Compile the minimal SCV worker release and the admitted
OpenCode binary in build stages, then copy their immutable artifacts into the
final toolchain image. Do not copy source credentials, package-manager tokens,
Hex state, SSH state, or build-stage homes into the final image. The worker
release should spawn OpenCode and language tools as contained OS processes and
remain the parent authority for deadlines, cancellation, output bounds, and
receipts.

### Worker image family

Use additional images only when the work item requires their capabilities:

| Worker image | Adds | Intended work |
| --- | --- | --- |
| `scv-opencode-core` | Bun, Node.js, Python, native build tools, and the admitted OpenCode runtime | OpenCode CLI and server changes, unit tests, type checks, source benchmarks, and most TypeScript work |
| `scv-opencode-browser` | Playwright Chromium, browser system libraries, and production application assets | Application end-to-end tests, trace capture, and UI performance benchmarks |
| `scv-opencode-rust` | A pinned stable minimal Rust toolchain | Rust crates, native helpers, and cross-language changes |
| `scv-opencode-tauri-linux` | GTK, WebKit, librsvg, Tauri prerequisites, and packaging utilities | Linux desktop compilation and packaging |
| Platform workers | Native Windows or macOS environment with the same SCV protocol | Platform behavior and release evidence that Linux cannot prove |

Derive later `scv-node`, `scv-python`, and `scv-rust` images from the same worker
contract. A new language requires an image and capability manifest, not a new
privilege in the Phoenix release.

Use this initial artifact layout when implementation starts:

```text
ops/scv/images/opencode-core/Dockerfile
ops/scv/images/opencode-browser/Dockerfile
ops/scv/images/opencode-rust/Dockerfile
ops/scv/images/opencode-tauri-linux/Dockerfile
ops/scv/images/versions.env
ops/scv/worker/entrypoint.sh
```

Keep versions and expected digests in an operator-owned manifest. The
entrypoint may start only the compiled worker release. It must not interpret
repository input or construct a shell command.

### OpenCode execution adapter

Implement `OpenAgents.SCV.Executor.OpenCode` behind the generic executor
protocol. Start with one admitted OpenCode process per run:

1. Create isolated `HOME`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`,
   `XDG_STATE_HOME`, and `XDG_CACHE_HOME` directories.
2. Generate operator-owned OpenCode configuration through
   `OPENCODE_CONFIG_CONTENT` and record its redacted digest.
3. Start `opencode run --format json` with the admitted model, directory, and
   bounded prompt.
4. Parse JSON events as nested observational records under one outer SCV
   execution step.
5. Mark the outer step uncertain and discard its workspace if OpenCode exits
   without a terminal event. Do not infer which internal tool effects finished.
6. Cancel the entire process tree when the lease, generation, deadline, budget,
   or operator state changes.
7. Reconcile the OpenCode session ID and local database at termination, retain
   admitted artifacts, and destroy the run home.

Do not use `--auto`, `--yolo`, or `--dangerously-skip-permissions`. Those modes
bypass the permission boundary that an SCV needs to test. A later adapter may
run `opencode serve` inside each worker for durable multi-turn sessions. Bind it
to loopback, require a random `OPENCODE_SERVER_PASSWORD`, keep the password in
the sidecar, and address sessions by their recorded OpenCode session IDs.

The native JSON stream provides useful visibility, but it cannot prove that the
SCV persisted each tool request before OpenCode executed it. Treat the first
compatibility run as one coarse, disposable effect. Before crash-resumable
candidate construction, add an SCV-specific OpenCode tool transport that:

1. Disables OpenCode's direct edit and command execution for SCV sessions.
2. Sends each typed tool request, session ID, run generation, and idempotency
   key to the sidecar.
3. Persists the requested `scv_step` before the sidecar acknowledges it.
4. Executes the request in the credential-free candidate compartment after
   policy and generation checks pass.
5. Returns a signed, digest-addressed result that OpenCode can use as its tool
   output.
6. Resolves retries from the committed step instead of repeating the effect.

Implement this transport as a narrow OpenCode integration or admitted patch,
not by parsing terminal output and reconstructing tool calls afterward. Keep
OpenCode's SDK, server event stream, session API, and permission API available
for session control, but do not confuse those APIs with the durable effect
barrier.

OpenCode project configuration, plugins, Model Context Protocol servers,
skills, instructions, and language-server downloads are executable or
instruction-bearing repository inputs. The first adapter should disable
automatic project configuration and downloads with
`OPENCODE_DISABLE_PROJECT_CONFIG=1` and
`OPENCODE_DISABLE_LSP_DOWNLOAD=1`. Resolve `AGENTS.md` and other required
repository instructions separately, admit their exact digests, and pass their
bounded content as evidence. Enable a project feature only after the host
policy classifies and receipts it.

Configure OpenCode permissions explicitly. Start from deny and admit only the
read, list, search, workspace edit, and structured command operations that the
current phase needs. Pass the operator-owned rule set through
`OPENCODE_PERMISSION` and record its digest. OpenCode's permission result is one
input to enforcement; the outer worker namespace, filesystem mounts, command
policy, cgroup, and network policy remain authoritative.

### Provider credentials

Give OpenCode a short-lived, run-scoped inference grant for an
OpenAI-compatible internal endpoint. Bind it to the SCV ID, run ID, admitted
model set, request count, token budget, cost budget, expiry, and worker
generation. Never place a reusable provider key in the image or workspace.

OpenCode normally launches tool processes beneath itself. Assume those child
processes can inspect the OpenCode environment until isolation proves
otherwise. The first experiment may use only a disposable, tightly budgeted
grant with no authority outside inference. It does not satisfy the final
credential-isolation requirement.

Before an SCV receives autonomous write or deployment authority, separate the
OpenCode model process from candidate command execution. Route tool requests
through the sidecar into a credential-free execution compartment. Keep the
inference grant in the model compartment or authenticate to a local inference
proxy through an out-of-band worker identity. Prove that candidate code cannot
read, reuse, or transmit the grant.

### First OpenCode validation run

Use a fixed workload against the inspected baseline before admitting arbitrary
OpenCode work:

1. Build and admit `scv-opencode-core` by digest.
2. Import the exact OpenCode baseline into the dedicated Forge qualification
   repository and verify its object and WAL receipts.
3. Check out the exact OpenCode baseline in a clean disposable workspace.
4. Verify the Bun, Node.js, Python, Git, and admitted OpenCode versions.
5. Run `bun install --frozen-lockfile` and record cold-cache and warm-cache
   receipts.
6. Run `bun typecheck` and `bun test --timeout 30000 --only-failures` from
   `packages/opencode`.
7. Run `bun run test:httpapi` from `packages/opencode` on the core worker.
8. Run `bun run bench:test` from `packages/opencode`, first with one measured
   run and then with explicit `BENCH_WARMUPS` and `BENCH_RUNS` values.
9. Run `bun run profile:test` from `packages/opencode` with explicit
   `TEST_PROFILE_GLOB`, `TEST_PROFILE_LIMIT`, `TEST_PROFILE_TIMEOUT`, and
   `TEST_PROFILE_TOP` values.
10. Start one bounded `opencode run --format json` session, exercise admitted
    read and command operations, and prove every permission denial and event
    reaches the SCV receipt chain.
11. Cancel a second run at each external boundary and prove generation fencing,
    process-tree termination, and workspace cleanup.

Run the browser performance suite only on `scv-opencode-browser`. Run it
serially against a production build, preserve the emitted `BENCHMARK` and
`BENCHMARK_PAGE` JSON records, and retain optional Chrome trace artifacts by
digest. Invoke `bun run test:bench` from `packages/app`. Use
`bun run test:e2e:local` from the same package for the normal end-to-end gate.
Do not make Rust, Tauri, Windows, or macOS gates mandatory for a change that
does not reach those surfaces.

The first improvement candidate should fix a seeded, reproducible OpenCode
defect or performance regression with an existing or independently authored
test. Keep the candidate propose-only. This proves the worker and evidence
system before any Forge deployment path opens.

## Worker pool and capability routing

Run multiple workers under one Elixir scheduler. Each worker registers an
operator-admitted capability manifest containing:

- worker image and SBOM digests;
- operating system, architecture, and resource class;
- CPU count or admitted CPU class, memory and disk limits, and process limit;
- runtime, compiler, package-manager, browser, and OpenCode versions;
- supported command and network profiles;
- benchmark isolation and tracing capabilities;
- current state: `starting`, `ready`, `busy`, `draining`, `unhealthy`, or
  `offline`.

The scheduler matches a work item's required capabilities to an exact manifest.
It must not infer compatibility from a worker name. A worker claims one
execution lease with the current run generation, heartbeats while active, and
rejects stale or duplicate requests. Draining prevents new claims without
interrupting an admitted execution.

Keep one repository writer per integration history. Multiple workers may run
read-only investigation, exact-SHA tests, benchmarks, or independent evaluation
in parallel against immutable checkouts. Candidate-affecting results must bind
to one exact SHA. A parallel result from an older SHA becomes evidence for a
later decision; it cannot silently update the active candidate.

Separate the logical SCV run from its worker executions. One run may dispatch a
core type check, browser benchmark, and Rust gate to different workers while
the coordinator retains the run lease and joins their immutable receipts.
Cancel or supersede each execution independently when its result is no longer
needed.

### Worker protocol

Use a versioned, language-neutral protocol so Linux containers, owned virtual
machines, and native Windows or macOS workers implement the same boundary. Do
not require a remote worker to join the BEAM cluster.

The protocol needs these operations:

- register an admitted image and capability manifest;
- heartbeat, renew an execution claim, and report health;
- claim the next compatible execution with its run generation;
- acknowledge a requested step only after the control plane persists it;
- stream bounded progress and host-observed measurements;
- publish a terminal receipt and artifact digests;
- cancel one execution or all executions for a run generation;
- drain, retire, and reject an image.

Authenticate workers with an SCV-specific machine identity over mutually
authenticated transport. Bind every message to the SCV ID, run ID, execution
ID, generation, protocol revision, and idempotency key. Sign or MAC terminal
receipts and verify them before the coordinator changes durable state.

Let workers pull compatible work instead of accepting arbitrary commands on a
general remote-execution port. The control plane stores the request before it
becomes claimable. Large source bundles, logs, traces, and profiles move through
digest-addressed artifact storage; protocol messages carry bounded metadata and
artifact refs. Use `Req` for the Elixir HTTP client if the first protocol uses
HTTPS. Keep transport selection behind the protocol behavior so an admitted
queue can replace HTTPS without changing run semantics.

## Resource, benchmark, and statistics evidence

Measure candidate processes from outside their namespace. OpenCode output and
repository benchmark scripts provide domain metrics, but only the worker host
can provide authoritative resource use.

### Execution measurements

Record these values for each structured command and aggregate them for the run:

- monotonic start and finish times, wall duration, exit status, signal, retry,
  and cancellation reason;
- user and system CPU time, allocated CPU class, throttled CPU time, and
  throttling count;
- current and peak memory, swap use, page faults, and out-of-memory events;
- filesystem bytes read and written, workspace and cache size, disk peak, and
  inode use;
- process and thread peak, descendant count, and leaked-process findings;
- network bytes, destination classes, and denied connection count;
- standard output and error bytes, retained bytes, truncation, and artifact
  digests;
- cold, warm, or disabled cache state and relevant cache digests.

Collect cgroup or container-runtime counters before cleanup. Sample long
commands at a bounded interval and store a compact time series outside the
workspace. Candidate code cannot write or amend these measurements.

### OpenCode usage measurements

Normalize OpenCode JSON events into SCV metrics for:

- session, provider, and model IDs;
- model requests, retries, time to first event, and total completion time;
- input, output, reasoning, cache-read, and cache-write tokens;
- estimated and provider-reconciled cost;
- tool calls by type, duration, result, output size, and permission decision;
- changed files, added and removed lines, commands, checkpoints, compactions,
  and terminal reason.

OpenCode's `stats` command aggregates sessions, messages, token classes, cost,
tool use, model use, date range, cost per day, tokens per session, and median
tokens per session from its local SQLite data. Import that result only as
reconciliation evidence. SCV step receipts and the inference ledger remain the
usage authority because a candidate can influence the local OpenCode store.

### Benchmark receipts

Store every benchmark as a definition plus immutable samples. A definition
includes the repository SHA, worker image digest, resource class, operating
system and architecture, toolchain versions, command profile, dataset or
fixture digest, cache policy, warmup count, measured run count, timeout, and
environment digest.

A sample stores its raw metric records and artifacts plus normalized values.
Summaries may report minimum, maximum, mean, median, and percentiles only when
the sample count supports them. Keep failed and cancelled samples; removing
them biases the result.

For OpenCode, ingest:

- `METRIC test_suite_seconds`, `test_suite_best_seconds`, and
  `test_suite_worst_seconds` from `bench:test`;
- per-file timings, `slowest_test_file_seconds`, and `profiled_test_files` from
  `profile:test`;
- application `BENCHMARK` and `BENCHMARK_PAGE` JSON lines;
- Chrome Performance traces and any admitted CPU or visual profiles;
- SCV host measurements for the same processes.

Compare a candidate with its recorded base only when the worker image, resource
class, operating system, architecture, toolchains, benchmark definition, cache
policy, and isolation level match. Otherwise mark the comparison
`not_comparable`. Use medians from repeated runs for performance decisions.
Keep correctness gates separate from performance evidence, and do not create
machine-dependent pass thresholds for OpenCode's browser benchmarks.

Reserve the benchmark worker exclusively for a comparison window. Run base and
candidate samples on the same worker when possible, alternate their order, and
record thermal, throttling, memory-pressure, and background-load invalidation
signals. Do not publish an improvement when environmental noise exceeds the
definition's admitted envelope.

## Durable execution model

An SCV remains logically active while its work occurs in bounded runs. The
coordinator repeats this sequence:

1. Wake on a durable work item, admitted signal, or bounded poll interval.
2. Acquire the repository's single-writer lease and increment its generation.
3. Select one work item against the current policy, budget, and integration
   head.
4. Start a bounded run with a fresh model context and isolated workspace.
5. Persist every requested tool step before execution.
6. Commit an honest terminal run result, including `no_change`, `refused`, or
   `budget_exhausted`.
7. If the run produced a candidate, advance it through gates and deployment as
   a separate durable state machine.
8. Observe the outcome, update the work item, release the lease, and return to
   idle.

This model supports continuous operation without infinite prompts, unbounded
mailboxes, permanent workspaces, or one process whose death loses the plan.

### Context and checkpointing

Start each run with bounded, source-linked context:

- the exact base SHA and SCV integration ref;
- the admitted work-item objective and evidence refs;
- the SCV program and policy digests;
- relevant repository paths, symbols, and recent commits;
- focused test failures or sanitized operational facts;
- prior attempts for the same work-item fingerprint;
- current token, command, diff, time, and deployment budgets.

Store compact checkpoints after investigation, plan selection, each mutation,
each test group, commit, gate, and deployment. A checkpoint is structured state,
not a transcript dump. It should identify facts, evidence refs, decisions,
changed paths, remaining work, and unresolved risks.

If context grows beyond its admitted limit, start a new provider response from
the latest durable checkpoint. Do not trust a model-authored summary without
the source refs needed to verify it.

## SCV program

Define a versioned `OpenAgents.SCV.Program` artifact with a calculated digest
and an admitted digest, following the repository's existing persona and role
artifact discipline without making an SCV a persona.

The SCV program should require this method:

1. State the observed problem and its evidence.
2. Read the relevant implementation, tests, invariants, and documentation.
3. Define the smallest verifiable outcome.
4. Add or identify a failing test before changing behavior.
5. Make a focused change.
6. Run the narrowest useful check, then the required candidate gate.
7. Inspect the final diff for unrelated or policy-protected changes.
8. Commit once the candidate is coherent.
9. Report uncertainty, omitted work, and exact receipts.

Repository files, issues, test output, comments, commit messages, dependency
metadata, and incident descriptions remain untrusted input. They cannot change
the SCV program, tool authority, budget, protected paths, risk class, gate, or
deployment policy.

## Work discovery and selection

An SCV should optimize against observable product and engineering outcomes. It
should not make changes to remain busy.

### Initial work sources

Admit these sources first:

- operator-created SCV work items;
- reproducible failing tests from the owned gate;
- compile warnings and static contract failures;
- typed, recurring incidents with sanitized evidence;
- documented TODO items that name an expected result and owner-approved scope;
- focused coverage gaps for high-risk code when the work item names the missing
  behavior;
- measurable performance regressions with a stable benchmark.

Delay broad dependency updates, external vulnerability feeds, speculative
refactoring, and free-form issue ingestion until their authority and network
contracts are explicit.

### Admission score

Score a work item with host-owned data:

- user or operator impact;
- reproducibility and evidence quality;
- confidence that the repository contains the fix;
- expected diff and deployment risk;
- estimated test and inference cost;
- recurrence and age;
- collision with active human work;
- cooldown after a prior failed attempt.

The model may recommend a score, but host code calculates the admitted score
and selects the next item. Deduplicate work by a stable fingerprint over the
repository, evidence class, affected surface, and normalized problem code.

### Valid idle behavior

When no item clears the admission threshold, an SCV remains idle. Idle is a
healthy state. Avoid goals such as "improve the codebase" without a measurable
problem because they reward churn, test rewriting, and style-only diffs.

## Workspace and Git model

### Exact base

Create each workspace from an exact commit in the WAL-backed Forge repository.
Do not copy the running image tree into a writable directory and do not clone
from GitHub.

Use a linear SCV integration ref, initially
`refs/heads/scv/integration`. Each run:

1. Reads the ref and its durable WAL position.
2. Records the exact base SHA in the run.
3. Checks out that SHA detached in a fresh workspace.
4. Creates `refs/heads/scv/runs/<run-id>` for its candidate.
5. Pushes with an expected-old-SHA compare-and-swap condition.

Only one repository-writing SCV runs at first, but the compare-and-swap remains
required. It catches operator changes, restore races, and future concurrency.

### Keeping improvements

Do not base each run on the default branch or current image independently. A
candidate deployed from a run branch can be absent from the next default-branch
clone. The SCV integration ref must advance only after the candidate reaches
its admitted terminal state:

- For a source-only candidate, advance after its source gate passes.
- For a runtime candidate, advance after Forge marks it `live` and the
  observation window passes.
- For a reverted or failed candidate, leave the integration ref on its
  predecessor.

Advance the integration ref through the normal authenticated Forge push path so
the WAL remains ref authority. Use compare-and-swap against the recorded base.
Do not update a bare repository ref directly from application code.

Before Forge becomes canonical, keep an SCV in propose-only mode and reconcile
its run refs through the existing GitHub review process. After the ADR 0007
cutover, decide whether `scv/integration` becomes the default branch or merges
into it through another policy-controlled fast-forward. Do not operate two
writable canonical histories.

### Workspace lifecycle

Keep a run workspace until its candidate reaches a terminal result and retain
only bounded diagnostic artifacts afterward. Remove it after success, refusal,
failure, cancellation, or rollback. Never reuse a dirty workspace for another
run.

## Tool and command design

Reuse repository read, grep, list, exact-edit, write, and commit semantics where
they fit. Add SCV-specific tools for:

- `git status`, diff, log, show, merge-base, and blame projections;
- file creation, deletion, and rename with path and byte bounds;
- focused test discovery and execution;
- Mix help and admitted Mix tasks;
- OpenCode runs through the admitted OpenCode adapter;
- repository-defined Bun, Node.js, Python, Rust, browser, and Mix commands
  through capability-specific profiles;
- formatting and final diff inspection;
- checkpoint and candidate submission.

Do not expose a raw shell-string tool. The executor should receive an executable
name, argument list, working directory, environment profile, time limit, and
output limit as structured data. Invoke it without a shell.

A small command allowlist is safer but may be too restrictive for useful coding
work. Use policy profiles instead:

- A read profile admits bounded Git and source-inspection commands.
- A focused-test profile admits exact repository-owned test entry points and
  repository tasks after validating their options.
- A candidate-gate profile admits only the immutable gate definition.
- A networked profile remains disabled in the first release.

Validate environment variables against an allowlist and build a fresh
environment. Never inherit the coordinator's complete environment. Redact
output before persistence and retain full output only in an operator-only,
short-lived store with a digest in the receipt.

Promotion, deployment, rollback, policy changes, budget increases, and
integration-ref advancement are host actions. Do not advertise them as model
tools.

## Durable records

Prefer separate tables over extending user-facing work rows.

### `scvs`

Store one logical SCV identity per repository:

- repository;
- status: `disabled`, `idle`, `running`, `paused`, or `circuit_open`;
- admitted program and policy revisions and digests;
- integration ref and admitted head SHA;
- owner node, lease generation, and lease expiry;
- current run and candidate IDs;
- budget window counters;
- last healthy and last terminal timestamps.

### `scv_work_items`

Store durable candidate work:

- source and source reference;
- stable deduplication fingerprint;
- bounded title, objective, and sanitized evidence refs;
- admitted risk ceiling and repository scope;
- priority inputs and calculated score;
- status: `discovered`, `admitted`, `running`, `completed`, `deferred`,
  `refused`, or `failed`;
- attempt count, cooldown, and terminal reason.

### `scv_runs`

Store one bounded execution episode:

- SCV, work item, base SHA, integration WAL position, and generation;
- program, policy, tool-catalog, evaluator, and gate digests;
- model and provider adapter IDs;
- requested worker capabilities, benchmark definitions, and comparison base;
- phase and terminal status;
- token, cost, tool, command, time, CPU, memory, disk, and diff usage;
- structured checkpoint and bounded report;
- candidate ID and error code;
- start and completion timestamps.

### `scv_steps`

Store every provider and tool boundary in order:

- sequence, provider response and call IDs, and prior-response ID;
- tool version, artifact digest, arguments digest, and output digest;
- requested, claimed, terminal, and uncertain timestamps;
- executor identity, status, error code, and receipt refs;
- run generation and idempotency key.

Store large input and output only in a bounded, access-controlled artifact
store when diagnosis requires it. Database rows should contain redacted
excerpts and digests.

### `scv_worker_images`

Store admitted immutable worker manifests:

- image, SBOM, Dockerfile, base image, source, and build receipt digests;
- operating system, architecture, toolchains, OpenCode runtime, and supported
  capability names;
- default resource bounds and permitted command and network profiles;
- admission, retirement, and vulnerability-review state;
- creation and immutable admission timestamps.

### `scv_workers`

Store the current worker registration and lease surface:

- stable worker ID, admitted image ID, resource class, and capabilities digest;
- state, health, drain request, and last heartbeat;
- current execution, run generation, claim expiry, and coordinator owner;
- boot identity and monotonic registration generation;
- bounded health details without hostnames, credentials, or internal addresses
  in operator projections.

### `scv_executions`

Store one dispatch to one worker:

- run, step, worker image, required capabilities, and exact repository SHA;
- execution generation, idempotency key, claim, start, heartbeat, cancellation,
  and terminal timestamps;
- command profile and redacted environment digest;
- exit, signal, timeout, cancellation, and uncertainty result;
- resource summary, output, event stream, and artifact refs.

### `scv_benchmark_definitions`

Store the admitted comparison contract:

- stable name and revision;
- repository paths, structured commands, metric parsers, fixture digests, and
  required capabilities;
- warmup, repetition, serial-execution, cache, timeout, and tracing rules;
- normalized metric names, units, direction, and decision policy;
- operator admission and immutable definition digest.

### `scv_benchmark_runs` and `scv_benchmark_samples`

Store the benchmark execution and its samples:

- definition, base or candidate SHA, worker image, resource class, toolchain,
  cache, and environment digests;
- sample ordinal, warmup flag, status, raw metric refs, normalized metrics, and
  host resource summary;
- aggregate statistics, comparison result, confidence policy, and
  `not_comparable` reasons;
- retained trace, profile, and diagnostic artifact refs.

### `scv_resource_samples`

Store compact host-observed measurements for long executions:

- execution ID, monotonic offset, and sample interval;
- CPU, throttling, memory, swap, filesystem, process, and network counters;
- cgroup or runtime source and collection error;
- immutable sample and summary digests.

### `scv_candidates`

Store the immutable candidate decision:

- run, base SHA, candidate SHA, run ref, and changed paths;
- diff digest, line and byte counts, and semantic risk findings;
- focused-test and gate receipt refs;
- policy decision and policy digest;
- source integration, Forge target, build, deploy, and predecessor refs;
- observation window, measurements, terminal result, and rollback target;
- immutable timestamps for each transition.

Use database constraints and triggers for forward-only terminal states and
immutable receipt fields. Treat PubSub and UI projections as hints.

## Run state machine

Use a state machine that distinguishes source construction from deployment:

```text
queued
  -> claiming
  -> investigating
  -> editing
  -> focused_testing
  -> candidate_committed
  -> candidate_pushed
  -> gating
  -> policy_review
  -> source_admitted
  -> promoting
  -> building
  -> deploying
  -> observing
  -> completed
```

Every nonterminal state may move to `failed`, `refused`, `cancelled`,
`budget_exhausted`, or `superseded` where appropriate. A deployed candidate may
move from `observing` to `reverted`. `no_change` is a terminal result from
investigation or focused testing.

Do not store one generic `running` status and infer the operation from logs.
Recovery and operator controls need the exact durable phase.

## Change policy

An SCV's most important code is the host-owned change classifier. It should
combine changed paths, diff structure, AST-level findings where practical,
Forge's build classification, and explicit protected-surface rules. A path
allowlist alone cannot recognize an authorization change hidden in a general
module.

### Recommended risk classes

| Class | Examples | Initial action |
| --- | --- | --- |
| Source-only | Documentation, comments, tests that add coverage, and development-only diagnostics | Require human review first. After a separate source-only policy admission, gate and advance the SCV integration ref without creating a fleet target when runtime output is unchanged. |
| Low-risk runtime | Focused bug fix in an explicitly admitted module, no interface or state-shape change, direct-load classification, and strong regression test | Human promotion first; staging autodeploy after policy proof. |
| Moderate runtime | New route, changed API shape, process-state behavior, broad refactor, or cross-context behavior | Require human review and the complete exact-SHA release gate. |
| Structural | Dependencies, assets, runtime configuration, migrations, releases, module deletion, native code, relup, or rolling replacement | Require human review. Admit staging automation only in a later policy revision with independent evidence. |
| Protected | SCV policy, Forge control, authentication, authorization, secrets, billing, data rights, invariant weakening, or release-gate weakening | Never auto-approve. Require an external operator path and independent evaluation. |

### Protected surfaces

The initial policy should refuse automatic promotion when a candidate changes:

- `AGENTS.md`, `INVARIANTS.md`, the SCV program, SCV policy, or SCV evaluator;
- `.githooks/`, `ops/ci/`, release-gate code, coverage floors, or test filters;
- `OpenAgents.Forge`, deployment providers, boot convergence, or release code;
- authentication, authorization, token, vault, secret, route-authority, or
  operator modules;
- migrations, schemas with durable-state meaning, or database triggers;
- provider credential handling, inference pricing, budgets, or metering;
- memory consent, data rights, publication visibility, or private-data bounds;
- dependencies, lockfiles, Dockerfiles, Terraform, runtime configuration, or
  production infrastructure;
- existing tests whose removal or weakening reduces a protected assertion.

An SCV may propose changes in these areas on its run branch, but the candidate
must stop at human review. The automatic lane must evaluate the complete diff,
including generated files and renames.

### Policy independence

Evaluate a candidate with the policy revision that existed at the run's base
SHA and a host-installed minimum policy. If a candidate changes policy code,
tests, or configuration, those changes cannot affect its own decision.

Use a two-key rule for later policy expansion: an operator admits the new
policy digest, and an independent evaluator proves its regression corpus. An
SCV can author a policy change, but it cannot supply either approval key.

## Candidate gates

Run checks in increasing order of cost and stop on the first failure:

1. Confirm workspace cleanliness and exact base ancestry.
2. Validate changed paths, diff bounds, generated artifacts, and protected
   surfaces.
3. Run formatting and focused regression tests.
4. Run the repository's admitted compile or type-check profile with warnings as
   errors where the toolchain supports it.
5. Run the repository's final precommit profile. Use `mix precommit` for
   `openagents.com` and the exact package-scoped Bun gates for OpenCode.
6. Commit and push the exact candidate SHA.
7. Run the required exact-SHA release gate in a fresh checkout.
8. Verify that the gate definition digest matches the base policy.
9. Have Forge build and classify the exact pushed SHA independently.
10. Compare Forge's manifest and structural findings with the SCV policy
    decision.

The final gate must run after commit because the repository's release receipts
bind an exact SHA. Run it in a fresh checkout so ignored files, a dirty worktree,
or the SCV's build cache cannot change the result.

For a low-risk automatic candidate, require all of these facts:

- the candidate descends from the admitted integration head;
- focused tests prove the reported defect or improvement;
- no protected surface changed;
- the repository's admitted final gate passes without retries or modified
  thresholds;
- the exact-SHA gate passes in the trusted evaluator;
- Forge independently classifies the complete candidate as `direct_candidate`;
- every changed runtime module matches the narrower SCV allowlist and Forge's
  operator-owned allowlist;
- the deployment budget and cooldown admit another target;
- no active incident, deploy, rollback, or human freeze blocks promotion.

## Automatic promotion

Keep push and promotion separate. A pushed SCV candidate should wake an SCV
policy evaluator, not `OpenAgents.Forge.Targets` directly.

Add a typed promotion principal such as:

```text
principal_type: scv
principal_id: <stable-scv-id>
policy_digest: <admitted-policy-digest>
candidate_id: <immutable-candidate-id>
gate_receipt_ref: <exact-sha-gate-receipt>
decision_digest: <complete-policy-input-digest>
```

The promotion API should accept either an authenticated operator receipt or an
admitted SCV receipt. It should verify the principal and evidence server-side,
then insert the same append-only Forge target used by a human promotion.

This amendment preserves the useful boundary that a push never promotes
itself. The model cannot promote. The repository tools cannot promote. The SCV
coordinator can request promotion only after host code has produced the
admitted receipt.

Record the promotion authority class explicitly in the target schema. Do not
overload a display string such as `operator:scv` because it would make audits
and authorization ambiguous.

## Deployment and verification

### Deployment sequence

After an admitted SCV promotion:

1. Wait for Forge to build the exact SHA and persist its receipt.
2. Require the build classification to match the SCV policy decision.
3. Let Forge select and execute the admitted deployment strategy.
4. Wait for the target and terminal deploy receipt from durable state, not only
   PubSub.
5. Start a post-deployment observation window after the target reaches `live`.
6. Run candidate-specific probes plus common health and readiness checks.
7. Compare bounded operational measurements with the recorded predecessor
   baseline.
8. Mark the candidate complete and advance the integration ref only after the
   observation window passes.

An SCV must never call BEAM loading functions or cloud deployment APIs itself.
Forge owns those effects and their rollback contracts.

### Observation contract

Define the expected signals before promotion. Use candidate-specific signals
where possible:

- the new regression test remains green against the packaged or live target;
- `/healthz` and deployment readiness remain healthy;
- fleet revision and artifact identities remain consistent;
- affected error codes do not regress;
- latency, memory, mailbox, and restart measurements remain within an admitted
  envelope;
- no new anomalous incident correlates with the candidate;
- the candidate's intended product outcome is observable when a safe synthetic
  probe exists.

Avoid a single global "error rate" gate that may miss a focused regression or
react to unrelated traffic. Store baseline interval, candidate interval,
sample size, missing-data result, and comparison policy in the candidate.
Missing required data should refuse admission rather than count as success.

### Rollback

Forge already reverts a failed deployment transaction before it marks a target
`live`. Post-live regression needs a second path: promote the exact predecessor
as a new target with an `scv_automatic_rollback` receipt, run the normal Forge
pipeline, and verify convergence.

Open the SCV circuit when any automatic candidate:

- requires post-live rollback;
- cannot verify rollback;
- leaves fleet identity divergent;
- creates an anomalous incident in a protected plane;
- exceeds its observation budget without enough evidence.

After the circuit opens, an SCV may continue read-only diagnosis if policy
allows it, but it cannot push, integrate, promote, or deploy until an operator
records a resume receipt.

## Control-loop stability

Continuous improvement can become an unstable feedback loop. Add these
controls from the first autonomous release:

- One active repository-writing run and one active candidate per repository.
- A cooldown between live candidates.
- A daily deployment budget and a separate rollback budget.
- A stable work-item fingerprint and retry backoff.
- A limit on changed files, lines, bytes, commits, and modules.
- A maximum number of attempts before operator review.
- A ban on immediately undoing and redoing the same change without new
  evidence.
- A predecessor comparison that detects oscillation between two SHAs.
- A change-frequency cap per subsystem.
- A freeze during incidents, migrations, operator maintenance, or fleet
  degradation.
- An operator pause that takes effect before the next external effect and a
  kill action that cancels current provider and executor work.

Do not use deployment count or lines changed as an SCV success metric. Prefer
resolved reproducible failures, prevented incidents, retained regression
tests, measured performance improvement, rollback-free observation windows,
and operator acceptance.

## Budgets

Use nested budgets:

- **Step budget:** input and output bytes, provider tokens, command output,
  command duration, and retries.
- **Run budget:** model calls, tool calls, continuations, wall time, CPU, memory,
  disk, changed files, diff size, and commits.
- **Candidate budget:** gate time, build attempts, deployment attempts,
  observation duration, and rollback attempts.
- **Window budget:** daily tokens, estimated cost, runs, pushes, promotions,
  deployments, and rollbacks.

Store the budget snapshot on the run before execution. A later configuration
increase must not widen an active run. When a run reaches a bound, refuse new
effects, request a tool-free bounded report when possible, and commit an honest
`budget_exhausted` result.

Start with conservative staging values and tune them from receipts. A useful
initial posture is one 45-minute run at a time, one candidate in flight, a
15-minute post-live observation window, at most four automatic staging
deployments per 24 hours, and an immediate circuit open after one rollback.
Keep these settings operator-owned and runtime-validated instead of hard-coding
them in a prompt.

## Recovery and idempotency

Use PostgreSQL as the run fence, following the existing work recovery contract:

- Claim a run under a row lock, record `owner_node`, increment `generation`,
  and set a bounded lease.
- Require the current generation on every checkpoint and terminal update.
- Reclaim only after the prior lease expires or its node is proven absent.
- Keep completed steps immutable.
- Resume only from committed outcomes.

Classify effects by recovery behavior:

| Effect | Recovery rule |
| --- | --- |
| Repository reads and deterministic analysis | Safe to repeat against the recorded SHA |
| Provider planning call | Safe to replace with a new call from a committed checkpoint; do not claim the interrupted response completed |
| File edit in an isolated workspace | Re-read and verify the expected digest before repeating |
| Test or compile command | Safe to repeat in a clean candidate workspace |
| Commit | Resolve by the run's tree digest and recorded ref before creating another commit |
| Push | Resolve the run ref and WAL receipt before retrying with compare-and-swap |
| Integration-ref advance | Resolve the WAL position and expected predecessor; never repeat blindly |
| Promotion | Deduplicate by candidate ID and promotion-decision digest |
| Deployment | Forge target and deployment IDs are authority; an SCV only observes or requests rollback |

If the executor dies during a command whose external effects cannot be
resolved, mark the step `uncertain`, fail the run closed, and require a new
workspace. Do not infer success from partial output.

## Security boundaries

### Service identity

Give an SCV separate, narrow identities for:

- provider use and usage accounting;
- coordinator-to-executor requests;
- Forge fetch;
- run-ref push;
- promotion receipt signing or verification;
- read-only operational measurements.

Do not reuse a browser session, user API token, machine pairing token, Forge
operator token, release cookie, or cloud deployment identity.

### Repository content and prompt injection

Treat all repository and work-item text as data. Host code must enforce:

- tool names and versions;
- exact repository and workspace roots;
- command profiles and arguments;
- environment variables and network access;
- path and output bounds;
- policy and gate digests;
- promotion and rollback admission.

A comment that says to ignore policy, expose credentials, weaken tests, or
deploy directly is an input-quality incident, not an instruction.

### Candidate execution

Assume candidate tests can read every mounted file and connect to every allowed
network destination. Use a disposable database with synthetic data, an empty
home directory, no forwarded SSH socket, no cloud metadata access, and no inherited
credential helpers. Pin dependencies before disabling external network access
for candidate execution.

### Data minimization

An SCV needs code and content-free operational facts, not user data. Incident
inputs should carry typed codes, affected component, recurrence, timestamps,
and sanitized stack or test refs. Never attach prompts, messages, memory,
transcripts, OAuth data, or arbitrary production rows.

## Observability and operator controls

Add an operator-only SCV surface with stable IDs and bounded projections. Show:

- SCV status, policy and program revision, lease generation, and integration
  head;
- active and recent work items, runs, candidates, and budgets;
- current phase, elapsed time, and cancellation state;
- worker pool health, admitted image digests, capabilities, resource classes,
  active executions, queue pressure, and drain state;
- changed paths and diff summary after a candidate exists;
- focused tests, exact-SHA gate, Forge build, target, deployment, and observation
  receipts;
- resource summaries, comparable benchmark results, OpenCode usage totals, and
  retained trace or profile refs;
- terminal result, rollback state, and circuit reason;
- **Pause**, **Resume**, **Cancel run**, **Reject candidate**, **Require human
  review**, and **Open diff** controls.

Do not expose raw prompts, private incident content, credentials, internal node
names, full build logs, or unrestricted command output. Public changelog entries
may name an SCV as the source role only after the existing repository visibility
policy admits the candidate.

Emit content-free telemetry for:

- work discovery and admission;
- run, provider, tool, and command duration;
- token and cost use;
- worker claims, queue time, utilization, health, resource use, and out-of-memory
  results;
- benchmark samples, comparison eligibility, regressions, and improvements;
- candidate refusal reasons;
- gate and build outcomes;
- promotion, deploy, observation, and rollback results;
- lease recovery, stale generation refusal, and circuit changes.

## Runtime configuration

Add typed, fail-closed settings such as:

```text
OPENAGENTS_FEATURE_SCV
OPENAGENTS_SCV_MODE=observe|propose|staging_auto|production_auto
OPENAGENTS_SCV_REPOSITORIES=anomalyco/opencode
OPENAGENTS_SCV_PROGRAM_REVISION=<revision>
OPENAGENTS_SCV_POLICY_REVISION=<revision>
OPENAGENTS_SCV_PROCESS_ROLE=coordinator|worker
OPENAGENTS_SCV_EXECUTOR=<adapter>
OPENAGENTS_SCV_EXECUTOR_QUEUE_DIR=<absolute-path>
OPENAGENTS_SCV_WORKSPACE_DIR=<absolute-path>
OPENAGENTS_SCV_WORKER_IMAGES=<admitted-manifest-digests>
OPENAGENTS_SCV_OPENCODE_IMAGE=<admitted-manifest-digest>
OPENAGENTS_SCV_MAX_WORKERS=<bounded-integer>
OPENAGENTS_SCV_MAX_ACTIVE_RUNS=1
OPENAGENTS_SCV_MAX_ACTIVE_REPOSITORY_WRITERS=1
OPENAGENTS_SCV_WORKER_CPU=<bounded-resource-class>
OPENAGENTS_SCV_WORKER_MEMORY_BYTES=<bounded-integer>
OPENAGENTS_SCV_WORKER_DISK_BYTES=<bounded-integer>
OPENAGENTS_SCV_RESOURCE_SAMPLE_MS=<bounded-integer>
OPENAGENTS_SCV_RUN_TIMEOUT_MS=<bounded-integer>
OPENAGENTS_SCV_BENCHMARK_RETENTION_MS=<bounded-integer>
OPENAGENTS_SCV_ARTIFACT_RETENTION_MS=<bounded-integer>
OPENAGENTS_SCV_DAILY_TOKEN_BUDGET=<bounded-integer>
OPENAGENTS_SCV_DAILY_COST_MICROUSD=<bounded-integer>
OPENAGENTS_SCV_DAILY_DEPLOYMENTS=<bounded-integer>
OPENAGENTS_SCV_DEPLOY_COOLDOWN_MS=<bounded-integer>
OPENAGENTS_SCV_OBSERVATION_MS=<bounded-integer>
```

The runtime boundary should reject:

- any enabled mode without admitted program and policy digests;
- a worker whose image, SBOM, capability, or command-profile digest is not
  admitted;
- an OpenCode adapter without an admitted OpenCode image and explicit
  permissions;
- a worker process role that also starts the Phoenix endpoint, application
  Repo, Forge control plane, or deployment coordinators;
- an executor path under `/tmp` in staging or production;
- an automatic mode before Forge deployment, boot convergence, durable
  artifacts, and isolated staging are enabled;
- `production_auto` while production deployment remains globally disabled;
- multiple active runs in the first policy revision;
- multiple repository writers for one integration history;
- a benchmark comparison across incompatible provenance;
- a deployment budget without an observation window and rollback authority;
- an SCV repository that is absent from the configured Forge repositories.

Readiness should report only enabled mode, admission status, circuit state, and
whether dependencies validate. It must not print paths, URLs, credentials,
work-item content, prompts, or internal identities.

## Suggested module layout

Keep one module per file.

```text
lib/openagents/scv.ex
lib/openagents/scv/driver.ex
lib/openagents/scv/driver/open_code.ex
lib/openagents/scv/environment.ex
lib/openagents/scv/instance.ex
lib/openagents/scv/work_item.ex
lib/openagents/scv/run.ex
lib/openagents/scv/step.ex
lib/openagents/scv/candidate.ex
lib/openagents/scv/worker_image.ex
lib/openagents/scv/worker.ex
lib/openagents/scv/worker_supervisor.ex
lib/openagents/scv/worker_client.ex
lib/openagents/scv/worker_runner.ex
lib/openagents/scv/runner.ex
lib/openagents/scv/runner/local.ex
lib/openagents/scv/execution.ex
lib/openagents/scv/benchmark_definition.ex
lib/openagents/scv/benchmark_run.ex
lib/openagents/scv/benchmark_sample.ex
lib/openagents/scv/resource_sample.ex
lib/openagents/scv/program.ex
lib/openagents/scv/policy.ex
lib/openagents/scv/change_classifier.ex
lib/openagents/scv/budget.ex
lib/openagents/scv/coordinator.ex
lib/openagents/scv/recovery.ex
lib/openagents/scv/context.ex
lib/openagents/scv/provider_loop.ex
lib/openagents/scv/tool_catalog.ex
lib/openagents/scv/workspace.ex
lib/openagents/scv/executor.ex
lib/openagents/scv/executor/open_code.ex
lib/openagents/scv/executor/sidecar.ex
lib/openagents/scv/executor_protocol.ex
lib/openagents/scv/worker_scheduler.ex
lib/openagents/scv/resource_collector.ex
lib/openagents/scv/benchmark_parser.ex
lib/openagents/scv/gate.ex
lib/openagents/scv/promoter.ex
lib/openagents/scv/observer.ex
lib/openagents/scv/circuit.ex
```

Use test adapters under `test/support`. Keep Forge changes in
`lib/openagents/forge/` when they generalize promotion principals or receipts;
do not make Forge import the SCV context.

## Implementation phases

### Phase 0: Amend contracts

1. Add an ADR for policy-authorized SCV promotion.
2. Amend `SELF-EDIT-001`, `docs/architecture.md`, and the route-authority ledger
   to distinguish human and SCV promotion receipts.
3. Define the first SCV program, policy, protected surfaces, risk classes, and
   evaluator corpus.
4. Define service identities and secret inventory entries.
5. Keep the feature disabled.

**Exit criteria:** Documentation and tests agree on who can admit an SCV
candidate, which changes can qualify, and how the operator stops the system.

### Phase 1: Observe and queue

1. Add SCV, work-item, run, step, candidate, worker, execution, resource, and
   benchmark schemas with database guards.
2. Add the coordinator, lease, budgets, recovery, pause, and circuit state.
3. Ingest operator work items and sanitized owned-gate failures.
4. Run selection and planning without repository writes.
5. Add the capability scheduler, worker registration, operator surface, and
   content-free telemetry without starting candidate commands.

**Exit criteria:** An SCV runs continuously in `observe` mode, survives process
and node loss, deduplicates work, spends within budget, and performs no external
effect.

### Phase 2: Build candidates

1. Build and admit `scv-opencode-core` by digest before any generic language
   worker.
2. Add the isolated executor protocol, OpenCode adapter, capability scheduler,
   worker leases, and resource collector.
3. Add exact Forge checkout, workspace confinement, the durable OpenCode tool
   transport, SCV tools, OpenCode event receipts, command profiles, and
   candidate-code sandboxing.
4. Register multiple `scv-opencode-core` workers, but retain one repository
   writer for the OpenCode integration history.
5. Run the fixed OpenCode validation workload, ingest its native benchmarks,
   and prove credential, permission, cancellation, and generation boundaries.
6. Add focused tests, commit resolution, run-ref push, WAL receipt linking, and
   cleanup.
7. Keep every candidate propose-only.

**Exit criteria:** An SCV can use OpenCode internally to reproduce, test, patch,
commit, and push a bounded OpenCode candidate. Multiple workers can execute
exact-SHA read and gate work without creating multiple writers. Resource and
benchmark receipts remain complete across crash tests, and no uncertain push
or command becomes success.

### Phase 3: Qualify and review OpenCode

1. Add the independent change classifier and protected-surface enforcement.
2. Add immutable focused-test, repository precommit, exact-SHA release-gate,
   benchmark, and evaluator receipts.
3. Run the OpenCode runtime qualification and self-targeting proof against the
   inspected baseline.
4. Add human review from the SCV candidate surface without a deployment action.
5. Reconstruct the complete chain from work evidence through OpenCode session,
   worker executions, resource samples, candidate push, exact-SHA gate, and
   benchmark comparison.

**Exit criteria:** A human can review a propose-only OpenCode candidate with all
evidence visible. The admitted OpenCode runtime remains separate from the
candidate checkout, and every refused class stops before source admission.

### Phase 4: Pilot `openagents.com`

1. Build and admit an `scv-openagents` capability image with the repository's
   pinned Elixir, Erlang, Mix, asset, database, and test toolchains. Keep the
   admitted OpenCode runtime as the model and tool-loop process.
2. Run the fixed fixture defect through focused tests, `mix precommit`, the
   exact-SHA release gate, and independent policy evaluation.
3. Add human promotion from the SCV candidate surface.
4. Reconstruct the complete chain from work evidence to the Forge deploy and
   observation receipts.

**Exit criteria:** A human can review and promote a low-risk
`openagents.com` candidate with all evidence visible, and every refused class
stops before promotion.

### Phase 5: Automate isolated staging

Start only after ADR 0007's Forge-canonical cutover and the isolated staging
deployment gates pass.

1. Add typed SCV promotion principals and decision receipts.
2. Admit only the low-risk direct-load class.
3. Add post-live observation, automatic predecessor promotion, cooldown, daily
   deployment budgets, and the circuit breaker.
4. Run failure injection for provider, worker, WAL, database, build, fleet,
   health, observation, and rollback failures.
5. Hold the staging SCV through a defined soak with no unexplained state.

**Exit criteria:** Staging proves repeated exact-SHA improvements and deliberate
failure cases without mixed revisions, lost commits, unreceipted effects, or
continued deployment after rollback.

### Phase 6: Expand admitted scope

Expand one independent policy revision at a time. Possible later admissions
include broader direct-load modules, source-only integration, relup candidates,
and rolling replacement in isolated staging. Require a new regression corpus,
operator approval, and soak for each expansion.

Production autonomy requires a separate plan and approval after production
deployment itself becomes authorized. Do not infer production approval from a
successful staging SCV.

## Test plan

### Lifecycle and recovery

- Prove single-writer lease acquisition, renewal, expiry, and stale-generation
  refusal.
- Kill the coordinator during every phase and recover from durable state.
- Prove completed steps and terminal runs cannot change.
- Prove duplicate work evidence, provider events, executor responses, pushes,
  and promotion requests do not repeat effects.
- Prove uncertain commands fail closed.

### Workspace and executor

- Refuse absolute paths, traversal, symlink escape, invalid refs, stale bases,
  oversized files, and output overflow.
- Prove every run starts from the recorded exact SHA in a clean workspace.
- Prove candidate code receives no coordinator, Forge operator, database,
  cloud, or user credential.
- Prove network and environment profiles fail closed.
- Prove cancellation terminates descendant processes and cleans the workspace.
- Prove the target checkout cannot change the admitted OpenCode runtime.
- Prove OpenCode home and XDG data never cross run or worker boundaries.
- Prove candidate commands cannot read or reuse the inference grant before
  enabling autonomous authority.

### Workers and scheduling

- Refuse unadmitted image, SBOM, capability, resource, and command-profile
  digests.
- Match every execution to its required operating system, architecture,
  toolchain, browser, and tracing capabilities.
- Prove worker heartbeat expiry and drain behavior cannot duplicate an
  execution.
- Run read-only exact-SHA executions on multiple workers while one writer owns
  the integration history.
- Supersede late results from an older candidate without rewriting their
  immutable receipts.
- Prove a platform-specific gate never runs on an incompatible worker.

### Model and tools

- Validate SCV program and tool-catalog digests at boot.
- Reject parallel tool calls when the host supports only serial execution.
- Persist a tool request before execution and continue only from its committed
  outcome.
- Force a bounded report on token, continuation, command, and wall-clock limits.
- Run adversarial repository text that asks an SCV to expose secrets, weaken
  gates, expand authority, or deploy directly.
- Refuse OpenCode automatic-permission flags, project plugins, unadmitted Model
  Context Protocol servers, and automatic language-server downloads.
- Reconcile OpenCode session statistics against SCV steps and the inference
  ledger without trusting the local SQLite store as authority.

### Resources and benchmarks

- Compare cgroup or runtime CPU, memory, disk, process, and network summaries
  with known fixture workloads.
- Prove candidate code cannot amend host-observed resource samples.
- Parse OpenCode `METRIC`, `BENCHMARK`, and `BENCHMARK_PAGE` records and retain
  raw artifacts by digest.
- Refuse comparisons when image, resource class, platform, toolchain, benchmark
  definition, cache policy, or isolation differs.
- Retain failed, cancelled, timed-out, and out-of-memory samples.
- Prove benchmark processes run serially when the definition requires it.

### Change policy

- Cover every source-only, low-risk, moderate, structural, and protected class.
- Refuse test deletion, assertion weakening, skipped tests, coverage-floor
  reduction, gate edits, renamed protected files, and generated protected
  output.
- Evaluate with the base policy when the candidate changes policy code.
- Require both the narrower SCV allowlist and Forge allowlist.
- Prove an unknown or conflicting classification fails closed.

### Git and receipts

- Prove compare-and-swap run-ref and integration-ref updates.
- Prove a run includes prior admitted SCV changes.
- Prove a failed or reverted candidate does not advance the integration ref.
- Resolve a crash after push from the WAL receipt without pushing twice.
- Reconstruct work item, run, steps, commit, push, gate, target, build, deploy,
  observation, and rollback by immutable refs.

### Deployment

- Prove a push alone never promotes.
- Refuse an SCV promotion without an admitted policy, exact-SHA gate, candidate
  decision, and budget.
- Prove an operator freeze wins every promotion race.
- Prove superseded-target handling and one candidate in flight.
- Inject canary, fleet, readiness, observation, and rollback failures.
- Open the circuit after one rollback and require an operator resume receipt.

### End-to-end proof

Create a fixture defect with a stable failing test. An SCV should:

1. Admit the work item.
2. Read the relevant code and invariant.
3. Add or select the regression test.
4. Make the smallest patch.
5. Pass focused checks and the repository's admitted final gate.
6. Commit and push an exact SHA to its run ref.
7. Pass the independent exact-SHA gate and change policy.
8. Produce a policy-bound promotion receipt.
9. Reach `live` through Forge's transactional lane.
10. Pass the observation window and advance the integration ref.

Repeat with an injected post-live regression. The second proof must promote the
predecessor, verify restoration, leave the integration ref unchanged, and open
the circuit.

## Recommended first release

Ship the first SCV with this deliberately narrow posture:

- one repository: OpenCode, initially anchored to the inspected `dev` baseline;
- one logical SCV, one active run, and one repository writer;
- multiple registered `scv-opencode-core` workers for read-only investigation,
  exact-SHA gates, and benchmark execution;
- `scv-opencode-core` as the first admitted image, with browser, Rust, Tauri,
  Windows, and macOS images added only when a required gate needs them;
- `observe` and `propose` modes only;
- operator-created work items plus reproducible owned-gate failures;
- a dedicated SCV program, tool catalog, service principal, and budget ledger;
- an OpenCode executor behind a sidecar with no production secrets or general
  candidate-command network access;
- explicit OpenCode permissions, isolated XDG state, and no automatic
  permissions or unadmitted project extensions;
- run branches and complete receipt chains;
- source, diff, package-scoped type-check, focused-test, HTTP API, resource, and
  benchmark receipts;
- no automatic promotion, integration-ref advance, or deployment.

This release validates the lifecycle, polyglot worker, OpenCode runtime,
sandbox, Git, resource, benchmark, and evidence contracts without granting
deployment authority. After it succeeds, target `openagents.com` with an Elixir
capability image and the same worker protocol. The next release can add
human-reviewed SCV candidates. Staging autodeploy should follow only after the
Forge-canonical and isolated-fleet prerequisites pass.

## Acceptance criteria for staging autonomy

Do not describe an SCV as autonomous until all of these conditions hold:

- An SCV resumes across coordinator and worker loss without duplicate effects.
- Every candidate descends from and conditionally advances one linear
  integration history.
- Candidate code runs without production or operator credentials.
- Candidate code cannot read an inference grant or replace the admitted
  OpenCode runtime.
- Every execution binds an admitted worker image, capability manifest, resource
  class, and host-observed resource receipt.
- Performance decisions use comparable benchmark definitions and preserve raw
  samples, including failures.
- Host policy, not model output, determines risk, gates, budgets, and promotion.
- Protected changes cannot approve themselves.
- A push cannot directly create a target.
- Every automatic target carries an admitted SCV principal, policy digest,
  candidate ID, exact-SHA gate receipt, and decision digest.
- Forge independently builds, classifies, deploys, and receipts the SHA.
- Post-live verification uses predefined evidence and treats missing evidence as
  failure.
- Automatic rollback promotes and verifies the exact predecessor.
- One rollback opens the circuit and stops further external effects.
- An operator can pause, cancel, reject, and resume an SCV without editing code
  or restarting the fleet.
- The complete staging failure matrix and soak pass against exact retained
  receipts.

An SCV that satisfies these criteria can make rapid iterations without making
the model, workspace, or running process the source of truth. Git commits,
policy decisions, gates, Forge targets, deployment receipts, and verified
runtime state remain the authority at every step.
