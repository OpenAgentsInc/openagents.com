# Cloud computer scale architecture audit

**Date:** 2026-08-22  
**Status:** Architecture recommendation  
**Tracking issue:** [#34, Assess Cloudflare Computer patterns for OpenAgents cloud computers](https://openagents.com/OpenAgentsInc/openagents.com/issues/34)

## Executive decision

OpenAgents should let one chat own 10–30 **logical computers**, but it should not create 10–30 Google Compute Engine (GCE) virtual machines when the chat starts. A logical computer must be a durable workspace and policy record. Compute must be a temporary, metered runtime lease that OpenAgents allocates only while work runs.

OpenAgents already has most of the necessary control-plane concepts across two repositories:

- `openagents.com` owns conversations, text and voice parity, authority snapshots, budgets, durable `work_jobs`, progress projection, and reports.
- The private `openagents` monorepo owns managed-sandbox lifecycle contracts, Google Cloud provisioning, capacity policy, checkpoint concepts, execution receipts, and an Agent Computer Firecracker implementation.

OpenAgents should connect these systems through one provider-neutral cloud-computer API. It should not build a third computer scheduler inside Phoenix.

The runtime recommendation has two tracks:

1. Make a hardened, pooled Firecracker provider on dedicated nested-virtualization GCE hosts the strong-isolation target for arbitrary repositories and tools. Reuse the existing Firecracker code, but do not expose it to multi-tenant fan-out until it runs under `jailer` or an equivalent containment layer, enforces cgroups and egress policy, uses copy-on-write images, and passes host-loss and residue tests.
2. Qualify GKE Agent Sandbox as the standard-density provider. Its gVisor isolation, `SandboxClaim`, warm-pool, and snapshot patterns match chat fan-out well and remove part of the custom host scheduler burden. However, the current Google interface uses `gcloud beta`, `v1alpha1` custom resources, and GKE 1.35.2 or later. OpenAgents should not make it the only production provider until it passes the same acceptance suite as Firecracker.

Keep the existing one-GCE-VM-per-managed-sandbox provider as a low-concurrency fallback and forensic isolation class. It is not the fan-out provider.

Cloudflare Computer provides useful workspace, synchronization, lifecycle, and routing patterns. OpenAgents should adopt those semantics, not Cloudflare's Durable Object, SQLite, FUSE, container, or Cap'n Web implementation.

## Audit scope and evidence

This audit answers the following question:

> If one ordinary chat can request 10, 15, 20, or 30 computers, how should OpenAgents provide those computers without coupling chat fan-out to GCE instance count, exhausting shared quota, weakening isolation, or creating a second orchestration system?

The audit inspected these snapshots:

- `openagents.com` at `7b2253af8534cc0bd68b46c16268dd95680d1f32`.
- The private `OpenAgentsInc/openagents` monorepo at local committed revision `3c9a714ed30aaf10a885c963b0a88b01d85b5bc3`. The working tree contained unrelated local state, so this audit made no changes there and makes no deployment claim for that revision.
- Cloudflare Computer at `de87919a4fd37242e960e13b7b3ba802d1eef0a0`.
- Read-only Google Cloud resource and quota observations for the production project on 2026-08-22.
- Current Google Cloud documentation linked in [Sources](#sources).

The audit treats documentation in Cloudflare Computer as directional when the repository labels a feature unimplemented or forward-looking. It distinguishes those descriptions from behavior present in source.

## What OpenAgents has now

### The Phoenix control plane

`openagents.com` already has the durable work authority that a cloud computer needs:

- `OpenAgents.Work.Job` stores the conversation and owner, text or voice surface, work kind, immutable authority and budget snapshots, lifecycle state, usage, owner node, and generation fence in `work_jobs` (`lib/openagents/work/job.ex`).
- `OpenAgents.ComputerAgentJobs` gives connected customer machines one owner-scoped entry point. Both the model tool and API use it, which prevents text, voice, and API authorization from drifting (`lib/openagents/computer_agent_jobs.ex`).
- The work supervisor can relocate durable jobs after node loss. Progress projections do not replace the durable job record.
- The SCV path already models work that runs on OpenAgents capacity. It creates a disposable workspace and runs a bounded coding process, but the current runner is local to the Phoenix host and an interrupted SCV cannot reattach (`lib/openagents/work/scv_server.ex`, `lib/openagents/scv/workspace.ex`, and `lib/openagents/scv/run.ex`).

These primitives should remain the user-facing admission and reporting path. Text and voice must call the same cloud-computer service and persist the same authority, budget, target, and usage data. The `surface` field may affect presentation; it must not select a different backend or policy.

### The managed-sandbox control plane

The private `openagents` monorepo already contains a provider-neutral managed-sandbox contract and a live GCE provider (`crates/oa-codex-control/src/managed_sandbox_runtime.rs`). It includes:

- Owner, tenant, work-unit, sandbox, generation, profile, budget, capability, and time-to-live bindings.
- Capacity policy with maximum and concurrent capacity.
- A durable local provider journal written before provider effects.
- Deterministic resource references and idempotent request fingerprints.
- Readiness, stop, cleanup, checkpoint, and forensic residue concepts.
- Network rules that deny general ingress and egress while admitting narrowly scoped control traffic.
- A production path that creates a dedicated GCE instance, disk, and firewall set for each sandbox.

The current provisioning profile uses `e2-small` and caps concurrent managed sandboxes at two (`scripts/cloud/provision-managed-sandbox-runtime.sh`). That profile offers a clear isolation boundary for private preview work. It cannot serve 15 concurrent computers efficiently because every computer consumes an instance, regional CPU quota, persistent-disk operations, firewall operations, startup latency, and cleanup work.

The provider currently counts active resources by listing GCE instances. A high-fan-out scheduler needs transactional reservations in its own database and a reconciler against Google Cloud. Enumerating cloud resources during admission cannot prevent concurrent over-allocation reliably.

### The Agent Computer Firecracker path

The private monorepo also has a live Firecracker provisioner (`crates/oa-codex-control/src/cloud_vm.rs`). It gives each run a deterministic virtual-machine reference, a copied root filesystem, a TAP device and subnet, a vsock channel, and targeted teardown.

The implementation is a useful starting point, but it is not a dense multi-tenant pool yet:

- Each guest reserves 4 vCPUs and 8 GiB of memory. Fifteen simultaneous guests require 60 vCPUs and 120 GiB before host overhead. Thirty require 120 vCPUs and 240 GiB.
- The observed live Agent Computer host is an `n2-standard-4` instance. It cannot host the requested fan-out.
- Provisioning copies the complete writable root filesystem for every run instead of using a shared read-only base plus a copy-on-write overlay.
- The code launches Firecracker directly. Its own comment states `NOT jailer`. The surrounding architecture materials describe jailer, seccomp, cgroup, and chroot containment, but the live launch path does not provide that boundary.
- The guest network receives general network-address-translation egress in the inspected path. Multi-tenant production needs a default-deny egress broker and metadata protection that the runtime cannot bypass.

OpenAgents should close these gaps before it raises concurrency. MicroVMs reduce the blast radius of an untrusted guest kernel, but they do not replace host process containment, resource controls, network policy, or a cleanup proof.

### Current Google Cloud headroom

The 2026-08-22 read-only quota snapshot for `us-central1` showed:

| Quota | Limit | Observed use |
| --- | ---: | ---: |
| Regional CPUs | 3,000 | 105 |
| N2 CPUs | 3,000 | 44 |
| VM instances | 6,000 | 35 |
| In-use IP addresses | 575 | 16 |
| Persistent disk capacity | 102,400 GiB | 120 GiB |
| SSD persistent disk capacity | 40,960 GiB | 4,310 GiB |
| Snapshots | 10,000 | 31 |

This snapshot shows enough quota for a controlled pilot. It does not justify direct allocation from chat requests:

- Google states that quota does not guarantee zonal or regional resource availability.
- The project already runs production, staging, GKE, control, and sandbox workloads. Cloud computers share failure and quota domains with them.
- One chat that requests 30 one-vCPU VMs converts one user action into 30 instance creates, 30 disks, 30 cleanup paths, and multiple control-plane API calls.
- A stopped GCE VM still consumes the VM instance quota. A logical computer cannot be represented by a stopped VM if OpenAgents expects large cold fleets.
- Nested virtualization needs supported machine families such as N2. E2 does not support the Firecracker host role.
- Google documents a 10% or greater CPU performance penalty for nested virtualization, with workload-dependent input/output overhead. Capacity and cost tests must measure the outer host and the guests together.

Quota must cap an internal reservation system. It must not serve as that reservation system.

## What Cloudflare Computer gets right

[Cloudflare Computer](https://github.com/cloudflare/computer) separates a durable `Workspace` from execution backends. A Durable Object and SQLite-backed virtual file system hold authoritative workspace state. A container or worker backend connects lazily when execution needs it. The container runs `computerd`, mounts or mirrors workspace state, executes commands, emits sequenced events, and synchronizes changes back.

The following implemented patterns transfer well to OpenAgents:

- **One workspace API over multiple backends.** Callers use one runtime interface, while server policy selects a container, shell, or module backend. Cloudflare's documentation correctly states that backend selection is routing, not authorization.
- **Durable authority outside the runtime.** A container can disappear without becoming the owner of durable files or execution identity.
- **Lazy runtime allocation.** Reading metadata or inspecting a cold workspace does not require a running container.
- **Reverse connection from runtime to control plane.** The runtime dials the owner with a workspace-scoped secret. This avoids opening a general inbound administration surface.
- **A synchronization bracket.** Command execution follows `push -> spawn -> events/result -> pull`.
- **Idempotent synchronization and explicit command ambiguity.** Cloudflare retries synchronization safely. If the transport fails after a command may have started, it does not replay the command automatically.
- **Runtime generation fences.** Execution identifiers remain bound to the runtime process that accepted them. A replacement runtime cannot accidentally accept an operation intended for its predecessor.
- **Sequenced, retained events.** Callers can reattach, observe bounded output, cancel, and dispose execution handles.
- **Replace broken sessions.** A dead transport invalidates the backend connection instead of leaving a partially trusted channel in service.
- **Measured filesystem tradeoffs.** The repository publishes benchmark data instead of assuming that a durable virtual file system performs like local disk.

These semantics match OpenAgents' existing `work_jobs`, generation fences, durable reports, and event projections.

## What OpenAgents should not copy

OpenAgents should not copy these Cloudflare-specific choices:

- **Durable Object and SQLite workspace authority.** OpenAgents already uses PostgreSQL for durable control state and Google Cloud Storage (GCS) for artifacts and checkpoints. Adding a separate database authority per computer would split operations and recovery.
- **A database-backed FUSE tree for all workload data.** Cloudflare's own benchmark reports a full `npm install` at 124.7 seconds on its workspace mount, compared with 63.9 seconds on container ext4 and 34.3 seconds on `tmpfs`. Its 64 MiB sequential copy and read cases are tens of times slower than local filesystems. OpenAgents should restore a checkpoint to local disk, run against local disk, and checkpoint changed data back to GCS.
- **One durable owner object paired to one container.** At OpenAgents' requested scale, one chat may hold 30 logical computers while only a subset runs. Durable ownership and runtime allocation must have independent cardinality.
- **Cloudflare's wire stack.** Cap'n Web and Cloudflare bindings solve Cloudflare deployment concerns. OpenAgents can preserve the protocol semantics over its existing authenticated control service, WebSocket, or HTTP streaming transports.
- **Preview features as production dependencies.** Cloudflare labels mount sources as unimplemented and hibernation behavior as forward-looking in the inspected snapshot. OpenAgents should require source and acceptance evidence before relying on either behavior.

## Pattern decisions

| Cloudflare pattern | Decision | OpenAgents implementation |
| --- | --- | --- |
| Durable workspace separated from runtime | Adopt | PostgreSQL workspace record plus GCS checkpoints and content manifests |
| One runtime API over backends | Adopt | Provider-neutral managed-sandbox API called by Phoenix |
| Backend routing is not authorization | Adopt | Resolve the runtime class after authority, budget, and policy admission |
| Lazy backend connection | Adopt | Create a runtime lease only for active execution or an explicit warm request |
| Reverse-dial control channel | Adopt | Runtime receives a short-lived, generation-bound credential and dials the control plane |
| Revisioned push and pull | Adapt | Restore a checkpoint to local disk, record a start watermark, and upload an incremental terminal checkpoint |
| Idempotent sync, no blind command replay | Adopt | Give each command an idempotency key and explicit `not_dispatched`, `may_have_started`, and terminal outcomes |
| Runtime UUID and event sequence fences | Adopt | Bind every command and event stream to `workspace_id`, `lease_id`, and `generation` |
| Retained execution events | Adopt | Persist bounded event metadata and artifact references; project live events through Phoenix PubSub |
| Database-backed FUSE as the work disk | Reject | Use local ext4 or equivalent copy-on-write storage while the runtime is active |
| One workspace owner per running container | Reject | Allow many cold logical workspaces and a smaller set of active leases |
| Cloudflare-specific storage and RPC | Reject | Keep PostgreSQL, GCS, `Req`, and the existing OpenAgents control service |

## Runtime options

| Runtime | Isolation | Fan-out fit | Operational cost | Recommendation |
| --- | --- | --- | --- | --- |
| One GCE VM per computer | Strong VM boundary | Poor. Instance, disk, firewall, startup, and cleanup costs scale linearly with computers. | High | Keep for low-concurrency forensic or strong-isolation work. Do not use as the default. |
| Firecracker on dedicated GCE hosts | MicroVM kernel boundary with high density after hardening | Strong after the scheduler, images, network, and host isolation support density. | Medium to high because OpenAgents owns hosts and the microVM control plane. | Use as the strong-isolation target. Harden the existing implementation before multi-tenant use. |
| GKE Sandbox and GKE Agent Sandbox | gVisor user-space kernel boundary | Strong scheduling model. Claims and warm pools map well to 10–30 logical computers. | Medium. GKE handles placement, but the Agent Sandbox surface is new. | Run a qualification track and use it for the standard class if it passes. Keep a second provider until the interface matures. |
| Cloud Run jobs | Container boundary for finite tasks | Good for one-shot parallel tasks, not retained interactive computers. | Low to medium | Use for bounded SCV-style jobs that need no listener or reattachment. Do not present a job as a computer. |
| Containers on Phoenix application nodes | Shared host kernel and secrets | Poor risk boundary and competes with the web fleet. | Low initial effort, high incident risk | Do not use. |
| Customer-connected computers | Customer-controlled isolation and capacity | Does not consume OpenAgents quota, but availability depends on the customer. | Low OpenAgents compute cost | Keep as an explicit user-selected target. Do not silently fall back to it. |

### Recommended runtime classes

Expose product-oriented profiles instead of provider names:

- `standard`: starts with 1–2 vCPUs and 2–4 GiB, local copy-on-write scratch, controlled network access, and a bounded lifetime. Qualify GKE Agent Sandbox and Firecracker against the same contract.
- `strong`: hardened Firecracker or dedicated GCE, selected for arbitrary native code, higher-risk tools, or stronger isolation requirements.
- `batch`: a one-shot Cloud Run or SCV execution with no promise of an interactive retained runtime.

Do not expose `gce_vm`, `firecracker`, `gvisor`, or a region as chat tool choices. Policy and capacity should select providers after admission. Store the resolved provider and image digest in receipts.

## The logical computer model

A logical computer should survive runtime loss and spend no compute while cold. Its durable record needs at least:

- `id`, `owner_id`, `conversation_id`, and a user-visible label.
- `state`: `cold`, `queued`, `starting`, `active`, `stopping`, `failed`, or `destroyed`.
- `generation`, current `runtime_lease_id`, and last accepted event sequence.
- Runtime profile, capability set, network policy, authority snapshot, and budget snapshot.
- Current checkpoint reference, checkpoint digest, base image digest, and workspace revision.
- Creation, last-use, idle-expiry, maximum-lifetime, and destruction timestamps.
- Accumulated vCPU-seconds, memory-GiB-seconds, storage byte-hours, network bytes, and provider operations.

A separate runtime-lease record should contain:

- Provider, region, zone or cluster, host or sandbox reference, and generation.
- Reserved vCPU, memory, scratch capacity, and network class.
- Reservation, start, readiness, heartbeat, expiry, release, and cleanup timestamps.
- A short-lived credential digest and runtime attestation or readiness evidence.
- Terminal disposition and zero-residue evidence.

Commands need their own durable identity. A command record should distinguish:

- Admitted but not dispatched.
- Dispatched with an acknowledgement.
- Transport lost and command may have started.
- Running with a last accepted sequence.
- Completed, failed, cancelled, timed out, or lost.

This distinction prevents a controller restart from rerunning a destructive command.

## Capacity and quota model

### Separate inventory from concurrency

For a request to create 15 computers, OpenAgents should create 15 logical workspace records immediately. It should activate only the number admitted by the chat, tenant, and global concurrency budgets. The remaining computers stay cold or queued and show that state in chat.

A conservative private-preview policy could start with:

- 30 logical computers per chat.
- Four active `standard` runtimes per chat by default.
- Eight active runtimes for an explicitly admitted high-fan-out operation.
- Two active `strong` runtimes per chat until density and isolation evidence supports more.
- A small global warm pool, such as two to four runtimes per active region, instead of a warm pool for each chat.

These are initial safety limits, not product promises. Load tests and observed queue time should set later values.

### Admit through hierarchical reservations

One serializable admission transaction should reserve capacity across these scopes:

1. Command and runtime profile.
2. Logical computer.
3. Conversation.
4. User and tenant.
5. Provider class and region.
6. Global OpenAgents safety limit.

The scheduler should use its own reservation rows and database locks. A reconciler should compare those reservations with provider state, recover leaked leases, and fail closed when quota observations become stale.

Calculate an effective provider limit as the minimum of:

- The configured safety ceiling.
- Observed provider quota minus reserved headroom.
- Host, cluster, or regional allocatable capacity.
- Budget and rate limits.
- Any temporary incident or drain limit.

Reserve at least 25% of the observed quota or configured provider ceiling for the existing application, cleanup, replacements, and operational recovery. OpenAgents should set a lower fixed ceiling during private preview even when the Google quota is much larger.

### Use realistic profiles

The current Firecracker profile allocates 4 vCPUs and 8 GiB per computer:

| Active computers | Guest vCPUs | Guest memory |
| ---: | ---: | ---: |
| 4 | 16 | 32 GiB |
| 15 | 60 | 120 GiB |
| 30 | 120 | 240 GiB |

A 1-vCPU, 2-GiB standard profile changes the same planning envelope to 15 vCPUs and 30 GiB for 15 active computers, or 30 vCPUs and 60 GiB for 30. Host overhead, checkpoint traffic, image caches, and warm capacity remain additional.

OpenAgents must benchmark real coding workloads before changing the profile. The purpose of the smaller profile is to define the fan-out question accurately, not to assume that every workload fits.

### Control start storms

When a chat requests 15 simultaneous starts, the scheduler should:

1. Reserve the admitted bundle atomically.
2. Start runtimes through a bounded worker pool.
3. Apply jitter and provider operation limits.
4. Stream per-computer queue and readiness state.
5. Release unused reservations if any start fails or exceeds its deadline.
6. Continue admitting queued computers fairly instead of letting one chat consume every free slot.

Use weighted fair queuing across tenants and conversations. Do not let a large chat block cleanup, health probes, or production application recovery.

## Recommended architecture

```text
Chat tool or API
       |
       v
Phoenix admission service
  - owner and conversation scope
  - text/voice-neutral policy
  - authority and budget snapshot
  - durable work job
       |
       v
Cloud-computer control adapter
       |
       v
Managed-sandbox control plane
  - logical workspace
  - quota and capacity reservation
  - provider routing
  - lease and generation fence
  - command and event journal
       |
       +---------------------+----------------------+------------------+
       |                     |                      |                  |
       v                     v                      v                  v
Firecracker pool       GKE Agent Sandbox      Dedicated GCE      Cloud Run job
strong class           standard candidate     forensic class     batch class
       |                     |                      |                  |
       +---------------------+----------------------+------------------+
                             |
                             v
                  Local runtime filesystem
                             |
                  checkpoints and artifacts
                             |
                             v
                     GCS + PostgreSQL
```

Phoenix should use `Req` to call the managed-sandbox control service. That adapter should expose create, list, start, execute, attach, cancel, stop, checkpoint, restore, fork, and destroy operations. It should return stable OpenAgents references and typed errors instead of provider responses.

The Phoenix tool family should operate on logical computers:

- `computer_create`
- `computer_list`
- `computer_run`
- `computer_stop`
- `computer_destroy`

The existing connected-computer tools can share names only if each call includes an explicit target reference and the server resolves the target type. Never infer “customer machine” versus “OpenAgents cloud computer” from text versus voice or from which route received the request.

## Workspace and checkpoint design

Use PostgreSQL for control metadata and GCS for workspace checkpoints and large artifacts. A runtime should:

1. Boot from a pinned, signed base image.
2. Restore the current checkpoint into local copy-on-write storage.
3. Run tools against the local filesystem.
4. Upload an incremental, content-addressed checkpoint at explicit boundaries and at bounded intervals.
5. Commit the new checkpoint reference with a generation compare-and-swap.
6. Retain the previous checkpoint until the new checkpoint passes integrity checks.

Do not mount the full dependency tree from a remote database-backed filesystem. Cache base images, toolchains, and common dependency layers on the host or cluster. Keep secrets outside checkpoints. A restored runtime must receive new short-lived credentials.

A checkpoint can support stop, resume, fork, host replacement, and post-incident analysis. It does not make in-flight command replay safe. The command journal still needs an explicit ambiguity state.

## Security requirements before fan-out

The pooled providers must pass these gates before OpenAgents enables multi-tenant use:

1. Run Firecracker under `jailer` or a documented equivalent with namespaces, cgroups, seccomp, a read-only host view, dedicated runtime users, and bounded device access.
2. Enforce hard CPU, memory, process, file-descriptor, scratch, network, and wall-clock limits per lease.
3. Block the Google metadata service from guests unless a narrowly scoped broker provides a required capability. Never pass a host service-account identity into a guest.
4. Default-deny egress. Route allowed source control, package, model, and OpenAgents control traffic through an observable policy broker.
5. Give each lease a generation-bound, short-lived credential. Remove bootstrap secrets from the environment after the runtime connects.
6. Keep runtime hosts separate from Phoenix, databases, control credentials, and customer-connected-computer controllers.
7. Prove teardown removes processes, TAP devices, mounts, overlays, cgroups, credentials, temporary firewall state, and scratch data.
8. Drain and replace a host after repeated isolation or cleanup failures.
9. Encrypt checkpoints with a workspace-scoped key and enforce owner and tenant scope on every restore and fork.
10. Record image, kernel, runtime, policy, and checkpoint digests in an operator-visible receipt.

GKE Agent Sandbox must meet the same contract. gVisor reduces host-kernel exposure, but OpenAgents must still use non-root containers, drop Linux capabilities, prevent service-account token mounts, set resource limits, forbid privileged and host namespaces, and restrict network access.

## Failure and recovery contract

The control plane should define these outcomes before implementation:

- **Controller restarts before dispatch:** Resume the command from the durable admitted record.
- **Controller loses the acknowledgement after dispatch:** Mark the command `may_have_started`. Reattach by command and runtime identity; do not start a replacement command automatically.
- **Runtime transport fails:** Invalidate the connection. Reconnect only to the same runtime generation; otherwise report the execution as lost.
- **Runtime dies between checkpoints:** Restore the last committed checkpoint in a new generation. Report any uncheckpointed file loss.
- **Host dies:** Reconcile all leases on the host, release reservations only after provider evidence, and restore eligible workspaces elsewhere.
- **Checkpoint upload succeeds but database commit fails:** Reuse the content-addressed object on retry and commit it with a generation check.
- **Database commit succeeds but acknowledgement is lost:** Return the already-committed checkpoint or command result by idempotency key.
- **Quota or capacity observation is stale:** Queue new work and preserve cleanup capacity.
- **Budget expires:** Stop the command, take a bounded terminal checkpoint if policy allows, and release the lease.
- **Cleanup cannot prove zero residue:** Quarantine the host or sandbox resource and open an incident. Do not return that capacity to the pool.

## Implementation plan

### Phase 0: Consolidate contracts

1. Define one `cloud_computer.v1` contract in the private control plane for logical workspaces, leases, commands, events, checkpoints, and receipts.
2. Reuse the managed-sandbox ownership, budget, capability, TTL, generation, and cleanup concepts.
3. Add a provider interface that can represent dedicated GCE, pooled Firecracker, GKE Agent Sandbox, and Cloud Run batch work.
4. Replace provider-side instance enumeration as the admission authority with durable reservations and a reconciler.

### Phase 1: Connect Phoenix

1. Add a cloud-computer target to the existing Work path instead of creating a parallel job system.
2. Add logical-computer and runtime-lease records or stable references that `work_jobs` can own.
3. Implement one `Req` client and one service entry point used by text, voice, tools, and API routes.
4. Project bounded live events through the existing conversation activity path and persist terminal reports and usage.
5. Keep cloud-computer tools disabled until the runtime acceptance gates pass.

### Phase 2: Harden the Firecracker pool

1. Replace direct Firecracker launch with `jailer` or an equivalent documented boundary.
2. Add cgroup, namespace, process, storage, and network enforcement.
3. Replace full root-filesystem copies with immutable base images and copy-on-write overlays.
4. Add a host agent that reports allocatable capacity, health, active leases, image-cache state, and cleanup evidence.
5. Add a small global warm pool and deadline-bound startup.
6. Run hosts in a dedicated managed instance group with drain, replacement, and zone-spread behavior.

### Phase 3: Qualify GKE Agent Sandbox

1. Create a private test cluster or node pool on the required GKE version.
2. Implement the same provider contract with `SandboxTemplate`, `SandboxWarmPool`, `SandboxClaim`, and `Sandbox` resources.
3. Test tool compatibility, startup time, checkpoint behavior, network policy, observability, and cleanup.
4. Treat memory-and-filesystem snapshot support as experimental until the GKE add-on owns the documented snapshot controller path. The current documentation describes a manual controller installation as a temporary step.
5. Compare cost, operator work, density, and incident recovery with the hardened Firecracker provider.
6. Promote it to `standard` only if it passes and keep provider fallback explicit.

### Phase 4: Raise fan-out in evidence-backed steps

1. Start with two active cloud computers per chat.
2. Qualify four, eight, fifteen, and thirty logical computers, while increasing active concurrency separately.
3. Record startup, queue, execution, checkpoint, restore, and cleanup percentiles for each profile.
4. Raise limits only after quota, fairness, isolation, and residue reports pass at the next level.

## Acceptance suite

Before a chat can activate 15 computers, require one exact-candidate report that covers:

- 30 logical computers in one chat with no compute allocated while all are cold.
- 15 concurrent standard runtimes with bounded startup and no provider API storm.
- Fair scheduling when multiple chats request the same fan-out.
- Controller restart before dispatch, after dispatch, during streaming, and during checkpoint commit.
- One runtime crash and one complete host loss.
- Reattachment without duplicate commands or cross-generation event delivery.
- Default-deny egress, metadata denial, and scoped broker access.
- Cross-tenant filesystem, process, network, credential, and checkpoint isolation tests.
- CPU, memory, process, disk, time, and network exhaustion tests.
- Cleanup and zero-residue evidence after success, failure, cancellation, timeout, and host drain.
- Quota saturation with reserved cleanup and production headroom intact.
- Text and voice requests producing the same backend admission, authority, budget, receipts, and outcomes.
- Billing and usage totals matching provider observations within a documented tolerance.

Track at least these service-level indicators:

- Queue time and cold-start time by runtime class.
- Active, cold, queued, failed, leaked, and quarantined computers.
- Host allocatable and reserved CPU, memory, and scratch capacity.
- Quota age, safety headroom, and denied admissions.
- Command ambiguity, duplicate-dispatch prevention, and reattachment rates.
- Checkpoint duration, bytes, restore duration, and integrity failures.
- Cleanup duration and zero-residue failures.
- Runtime cost per active minute and per completed job.

## Direct answers

### Should OpenAgents use Cloudflare Computer's patterns?

Yes. Adopt its separation of durable workspace from runtime, one provider-neutral execution API, lazy runtime allocation, reverse-dial control, generation fences, sequenced events, idempotent synchronization, and explicit no-replay boundary.

Do not copy its Durable Object, SQLite, FUSE, Cap'n Web, or one-owner-to-one-container implementation. Those choices fit Cloudflare's platform and do not solve OpenAgents' Google Cloud quota and shared-infrastructure constraints.

### Should OpenAgents use microVMs?

Yes, for the strong isolation class and arbitrary user code. The existing Firecracker path makes this an extension of current work. It needs security and density changes before multi-tenant production.

MicroVMs should not become the product model. A computer remains a logical workspace, and the scheduler can lease a Firecracker microVM, a GKE sandbox, a dedicated GCE VM, or a batch runtime based on policy.

### Can one chat have 15 computers?

Yes. Create 15 logical computers, then admit a bounded number of active runtime leases. A normal chat should start with four active leases, while an explicitly budgeted high-fan-out operation can request more. The UI and chat transcript should show cold, queued, starting, active, and terminal states.

### Can one chat have 30 active computers?

The architecture supports it, but current infrastructure does not qualify it. The present one-GCE-per-sandbox profile caps at two, and the observed Firecracker host cannot run the existing 4-vCPU, 8-GiB guest profile at that density. OpenAgents must complete the pooled-provider, quota-broker, isolation, and load-test work first.

### What should OpenAgents build next?

Build the provider-neutral logical-computer and lease contract, then connect Phoenix to the existing managed-sandbox control plane. Harden the existing Firecracker provider and qualify GKE Agent Sandbox behind the same interface. Do not add another direct GCE provisioning path to `openagents.com`.

## Sources

### OpenAgents source

- `openagents.com`: `lib/openagents/work/job.ex`, `lib/openagents/computer_agent_jobs.ex`, `lib/openagents/work/scv_server.ex`, `lib/openagents/scv/workspace.ex`, and `lib/openagents/scv/run.ex`.
- Private `openagents` monorepo: `specs/openagents/managed-agent-sandboxes.product-spec.md`, `docs/khala-code/2026-07-06-agent-computers-strategy.md`, `docs/khala-code/2026-07-06-agent-computer-isolation-posture.md`, `crates/oa-codex-control/src/managed_sandbox_runtime.rs`, `crates/oa-codex-control/src/cloud_vm.rs`, and `scripts/cloud/provision-managed-sandbox-runtime.sh`.

### Cloudflare source

- [Cloudflare Computer repository](https://github.com/cloudflare/computer)
- `README.md`
- `docs/02_sync_protocol.md`
- `docs/05_runtime_interface.md`
- `docs/07_injected_service.md`
- `docs/11_lifecycle.md`
- `docs/16_code_execution.md`
- `docs/19_performance.md`
- `packages/computer/src/workspace.ts`
- `packages/computer/src/backends/container/cloudflare-container.ts`
- `packages/computerd/src/cli/computerd.ts`

### Google Cloud documentation

- [Compute Engine allocation quotas](https://docs.cloud.google.com/compute/resource-usage)
- [Nested virtualization overview](https://docs.cloud.google.com/compute/docs/instances/nested-virtualization/overview)
- [Cloud Run quotas and limits](https://docs.cloud.google.com/run/quotas)
- [Create Cloud Run jobs](https://cloud.google.com/run/docs/create-jobs)
- [About GKE Sandbox](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/sandbox-pods)
- [Install GKE Agent Sandbox](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/how-install-agent-sandbox)
- [Use GKE Agent Sandbox snapshots](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/agent-sandbox-pod-snapshots)
