# walgit and the forge: two implementations of one architecture

**Date:** 2026-08-24
**Subject:** `walgit` at commit `8e3ece5` ("walgit: initial public release", 68,231 lines of Rust across eight crates) compared with `OpenAgents.Forge` at commit `b5eb4ee` (15,519 lines of Elixir across 55 modules in `lib/openagents/forge/`).
**Question:** Both systems put a write-ahead log in object storage, make it the only ref authority, and treat every node's disk as a cache. What did each build on top of that, what does the other's shape reveal, and where does walgit's design expose a weakness in ours?
**Method:** direct reading of both implementations. On our side: `lib/openagents/forge/` — chiefly `wal.ex`, `wal/gcs.ex`, `wal/local.ex`, `sync.ex`, `pushes.ex`, `git_http.ex`, `git_plane.ex`, `verification.ex`, `independence.ex`, `janitor.ex`, `receipt_repository.ex`, `anchor.ex` — plus `INVARIANTS.md` (`REPOSITORY-002`, `REPOSITORY-003`, `EXIT-001` through `EXIT-006`) the disclosure in `docs/forge-operator-independence.md` and `docs/forge-exit-rehearsals.md`, and the audits in `docs/2026-08-21-repository-storage-architecture-audit.md`, `docs/2026-08-23-forge-wal-anchoring.md`, and `docs/2026-08-23-invariant-proof-audit.md`. On walgit's side: its Rust crates, protobuf schema, and simulation tests, with its `README.md`, `AGENTS.md`, `GOAL.md`, and `docs/` read second so that intent never stood in for implementation.
**Status:** Comparison only. No implementation changed. Follow-ups in section 7 are proposals, not decisions.

---

## 0. How to read the citations

Paths in code font that begin `lib/`, `test/`, `ops/`, `config/`, `docs/`, or `infra/` are this repository. Every other path — anything under `crates/`, `web/`, or a walgit-relative `docs/` name given as "walgit's `docs/…`" — belongs to the walgit repository at commit `8e3ece5`, which is a read-only reference clone and not part of this repository's history.

One word collides. `docs/taxonomy.md` defines **checkpoint** as a proposed save point in a thread, linked to a forge commit. walgit's checkpoint is something else entirely: a folded snapshot of a repository's log. This document says **log checkpoint** for walgit's object and never uses the bare word for it.

## 1. What the two systems share

Tobi Lütke published walgit over a weekend as a single Rust binary that hosts Git repositories in front of an S3 or GCS bucket with no database, no leader, and no local state that matters. It is an implementation of the architecture Cursor described in *Git at any scale*, whose system is called Continuity; walgit keeps that post verbatim in its `docs/reference/cursor-git-at-any-scale.md`.

Our forge is the same architecture, reached independently and written in Elixir. The agreement is at the level of mechanism, not vocabulary, and it holds on six points.

**The log in object storage is the only ref authority; disks are caches.** `lib/openagents/forge/wal.ex:5` states it in the first sentence of the moduledoc: "The WAL in object storage is the source of truth for git refs; node disks are only a cache." walgit's `GOAL.md` states the same thing as its first numbered goal, and its `AGENTS.md` principle I asks of every change, "If every instance is wiped now, what is lost?" — the required answer being "warmth". `lib/openagents/forge/sync.ex:4` is the same claim from the reader's side: "the bare repo on disk is a projection of the WAL, never authority."

**A compare-and-swap on one small document is the only commit point, and it is the consensus.** Our CAS is a GCS generation precondition: `cas_index/3` uploads the index with `ifGenerationMatch`, and GCS itself rejects a stale write with a `412` that maps to `{:error, :cas_conflict}` (`lib/openagents/forge/wal/gcs.ex:46`, `:65`). walgit's is the same primitive on `manifest.pb` through its own `ObjectStore` trait, with `PutMode::Create` for the first write and a version token afterwards. Neither system elects anything. Both accept a push on any node, and both let the CAS decide which one wins. `lib/openagents/forge/wal.ex:8` puts it exactly: "Because the index CAS serializes all pushes, two nodes can never both believe they advanced the same ref."

**A push is acknowledged only after the log accepts it.** `lib/openagents/forge/pushes.ex:2` names the rule and its source in the same breath: "apply locally, persist to the WAL, and only then ack — 'we never acknowledge a push until it has been fully persisted.'" If the log refuses the entry, local refs are rolled back and the client sees a failed push (`lib/openagents/forge/pushes.ex:114`). walgit's `AGENTS.md` §2.2 ends its write path with "Never ACK before the bucket ACKs."

**A losing writer refetches and retries rather than failing.** `lib/openagents/forge/pushes.ex:104` re-synchronizes and retries once on `:cas_conflict`. walgit refetches on a `412`, re-validates every ref's old value, re-sequences, and retries with jittered backoff.

**Both wrap the stock `git` binary rather than reimplementing pack logic.** `lib/openagents/forge/git_http.ex:3` credits the source of the idea directly: "wrapping the stock git binary ('Spokes got that exactly right' — standard packfiles, upstream clients, no custom object format)". walgit's decision D2 keeps upstream `git` for delta-compressing repack, bitmaps, bundle creation, and normal upload-pack, and admits `gix` only where it is measured faster and correct.

**A node that has never seen a repository materializes it from the log.** Ours replays entries onto an empty bare repository and can rebuild from sequence zero (`lib/openagents/forge/sync.ex:73`, and `INVARIANTS.md`, `REPOSITORY-003`). walgit loads the log checkpoint's ref snapshot and replays the tail above it.

That is a real convergence, and it is the reason the rest of this document is worth writing. The two systems then diverge almost completely, because they were built to answer different questions.

---

## 2. Feature by feature

Every row cites where the claim was checked. A walgit row was checked in its Rust sources, its protobuf schema, or its tests; where its own documentation says something the code does not do, the row says so.

| Capability | walgit | Verified at | Forge | Verified at |
| --- | --- | --- | --- | --- |
| Ref authority | WAL in an S3 or GCS bucket | `crates/walgit-proto/proto/walgit/v1/wal.proto:27` | WAL in a GCS bucket | `lib/openagents/forge/wal.ex:5` |
| Commit point | CAS on `manifest.pb` | `crates/walgit-wal/src/publish.rs:1067` | CAS on the index by GCS generation | `lib/openagents/forge/wal/gcs.ex:46` |
| Acknowledgment order | Bucket first, then the client | walgit's `AGENTS.md` §2.2 | Bucket first, then the client; refs roll back otherwise | `lib/openagents/forge/pushes.ex:114` |
| Pack handling | Stock `git` for repack, bitmaps, bundles, and upload-pack by default | `crates/walgit-git/src/lib.rs:2445` | Stock `git` for every service | `lib/openagents/forge/git_http.ex:559` |
| Smart HTTP v0 | Yes, always through the stock `git` subprocess | `crates/walgit-server/src/smart.rs:768` | Yes | `lib/openagents/forge/git_http.ex:57` |
| Protocol v2 | Implemented in walgit: capabilities, `ls-refs` with prefixes, `fetch`, `object-info`, `bundle-uri` | `crates/walgit-server/src/smart.rs:139`, `:202` | Available by delegation: `GIT_PROTOCOL` is passed to the stock binary, which negotiates v2 | `lib/openagents/forge/git_http.ex:554`, `:68` |
| Log entry payload | Content-addressed packfile with `.idx`, and `.rev`/`.bitmap`/`.commit-graph` side files | `crates/walgit-proto/proto/walgit/v1/wal.proto:96` | The raw `receive-pack` request body, or a `git bundle`, or a ref-only record | `lib/openagents/forge/sync.ex:346` |
| Log checkpoints | Yes: folded ref snapshot plus pack inventory, on 256 entries, an 8 MiB tail, or one hour | `crates/walgit-wal/src/checkpoint.rs:38`, `:172` | None | absent from `lib/openagents/forge/` |
| Compaction | Geometric fold published as a `COMPACT` entry; replicas download the result | `crates/walgit-server/src/ops.rs:673`, `crates/walgit-wal/src/publish.rs:1000` | None | absent from `lib/openagents/forge/` |
| Index or manifest growth | Bounded: head pointer, checkpoint pointer, live pack set, log segment pointers | `crates/walgit-proto/proto/walgit/v1/wal.proto:27` | Unbounded: the full entry list with each entry's whole ref map | `lib/openagents/forge/wal.ex:12`, `:335` |
| Read freshness | One conditional `GET`, `304` to serve locally, optional freshness window | walgit's `docs/ROUNDTRIPS.md` §2 | Two unconditional `GET` requests plus the whole index body, every read | `lib/openagents/forge/wal/gcs.ex:37`, `:251` |
| Round-trip budget | Pinned by test: push 5, warm refs 1, cold refs 2, checkpoint 4 | `crates/walgit-server/tests/sim.rs:1645` | None | absent from `test/` |
| Serving refs without objects | Yes: refs sync level writes refs offline before packs exist | `crates/walgit-wal/src/sync.rs:929` | No: the advertisement runs `git upload-pack --advertise-refs` on the local bare repository | `lib/openagents/forge/git_http.ex:68` |
| Repository larger than the node | Served: remote reader over 1 MiB range reads with a block LRU | `crates/walgit-wal/src/remote.rs:28`, `:82` | Not served, and not refused early either | no counterpart to `check_fits` |
| `bundle-uri` | Yes: calendar slots, weekly full plus chained dailies and hourlies, two lists, blobless family | `crates/walgit-bundle/src/schedule.rs:19`, `crates/walgit-bundle/src/render.rs:117` | None; `git bundle` is used only as an internal entry payload | `lib/openagents/repositories/importer.ex:328`, `lib/openagents/forge/git_plane.ex:553` |
| Git LFS | Batch API, objects in the bucket, optional read-through from an upstream | walgit's `docs/LFS.md`; `crates/walgit-server` LFS routes | None. Import copies pointer files and warns | `lib/openagents/github.ex:125`, `lib/openagents_web/live/repository_import_live.ex:121` |
| Push policy | Per-repository rule language at `policy.json`: protected refs, groups, fast-forward only, bypass | walgit's `docs/POLICY.md`; decision D16 | Protected branches bind assignment credentials only; any other write principal may move any ref | `lib/openagents/forge/git_http.ex:284`, `:299` |
| Placement | Configured serve and maintain globs; unplaced object work answers `503` with `Retry-After` | walgit's `AGENTS.md` D30 | Every connected node warms every repository | `lib/openagents/forge/sync.ex:43` |
| Cross-instance mutex | CAS lease with TTL at `leases/<name>.pb`, used for compaction and bundle builds | `crates/walgit-store/src/coord.rs:298`, `crates/walgit-server/src/ops.rs:735` | Node-local `:global.trans` only; nothing coordinates across nodes but the CAS | `lib/openagents/forge/sync.ex:101` |
| Maintenance loop | One bounded unit per pass in priority order: checkpoint, repair, bundles, compaction, reverse index, fsck | `crates/walgit-server/src/maintain.rs:271`, `:396` | Cache retention and receipt re-derivation; never touches the WAL | `lib/openagents/forge/janitor.ex:15`, `:53` |
| Connectivity audit | `git fsck --connectivity-only` every 7 days, report at `fsck.pb`, gated on the pack set fitting locally | `crates/walgit-server/src/ops.rs:217`, `crates/walgit-server/src/maintain.rs:400` | On demand: `Verification.verify/2` walks `rev-list --objects` over exportable refs | `lib/openagents/forge/verification.ex:29` |
| Automatic repair | Fetches missing objects from `upstream.git` and publishes them; nothing happens without an upstream | `crates/walgit-git/src/repair.rs:74`, `crates/walgit-server/src/maintain.rs:286` | Rebuild from sequence zero; the recovery path is forbidden from consulting the mirror | `lib/openagents/forge/sync.ex:255`, `INVARIANTS.md` `EXIT-003` |
| Shallow state | None on the server; a shallow-seeded repository is a repository with missing objects | `crates/walgit-git/src/receive.rs:95`; no `graft` in `crates/` | Recorded per entry and reconciled against the objects held | `lib/openagents/forge/sync.ex:161`, `INVARIANTS.md` `REPOSITORY-003` |
| Log tamper-evidence | None. No chain, no per-entry digest, no signature; content addressing is a naming convention, unverified on read | `crates/walgit-proto/proto/walgit/v1/wal.proto:141`; `crates/walgit-wal/src/sync.rs:330` | Chained: each entry commits to its predecessor, and entry bytes are re-hashed against the recorded key | `lib/openagents/forge/wal.ex:269`, `lib/openagents/forge/verification.ex:18` |
| Published commitment to the log | None | no anchor, digest, or attestation surface in `crates/` | Hourly document at `/.well-known/openagents-forge-anchor.json`, itself chained by `previous_digest` | `lib/openagents/forge/anchor.ex:74`, `lib/openagents_web/router.ex:390` |
| Verification without a database | Not applicable; there is no database | walgit's `GOAL.md` §1 | Proven: the verifier's compiled import table must not reach Ecto, Postgrex, or `OpenAgents.Repo` | `INVARIANTS.md` `EXIT-002` |
| Events out | Bridge tails the log from a durable cursor and posts webhooks, exactly once per repository, sequence, and ref | walgit's `AGENTS.md` D32 | PubSub broadcast and a background mirror task, both fired from the push path | `lib/openagents/forge/pushes.ex:428` |
| Per-repository settings | Published as a `SETTINGS` entry and carried inline on the manifest | `crates/walgit-proto/proto/walgit/v1/wal.proto:64` | PostgreSQL rows in `repositories` | `lib/openagents/repositories/repository.ex:20` |
| Durable state outside the bucket | None | walgit's `AGENTS.md` principle I | PostgreSQL: issues, projects, receipts, memberships, auth | `docs/taxonomy.md`, the layer diagram |

---

## 3. What walgit has that we do not, and whether we should want it

Each item carries a judgment. Some of these we should want; some are answers to a problem we do not have. The distinction matters more than the list.

### 3.1 Log checkpoints and compaction — want, and want first

**What walgit does.** A log checkpoint writes `checkpoints/<seq>/refs.pb` and `checkpoint.pb`, then CASes the manifest to advance `min_seq` and drop every folded log segment (`crates/walgit-wal/src/checkpoint.rs:232`). Cold start becomes snapshot plus tail. Compaction folds fresh packs geometrically under a lease and publishes the result as a `COMPACT` entry naming what it supersedes, so replicas download the compacted pack instead of repacking (`crates/walgit-server/src/ops.rs:673`, `crates/walgit-wal/src/publish.rs:1000`).

**Should we want it.** Yes, and ahead of everything else in this section. Section 5.1 states the cost we pay without it.

**What it would cost here.** More than it looks, because the coupling is in the index format. `next_seq/1` is `length(entries)` (`lib/openagents/forge/wal.ex:335`), so a folded list changes what a sequence number means. `EXIT-002`'s `entry_sequence_broken` finding quantifies over the contiguous run from zero, and `EXIT-005`'s chain walks the entry list to recompute links, so both invariants move with the format. A checkpoint would have to carry enough for the chain to remain checkable across the fold, or the chain's start moves and `chained_from` has to mean "since the checkpoint" rather than "since the contract landed". That is a design question, not a refactor, which is why this document proposes it rather than performing it.

Two things make it cheaper than the full walgit shape. We do not need compaction to make reads cheap, because we do not serve repositories that stress pack lookup; we need it to stop the log from growing. And a first version could fold the index alone — a checkpoint object holding the ref map at a sequence, with the index carrying a pointer and only the tail — without touching packs at all. That alone removes the download-everything and upload-everything costs.

### 3.2 Git LFS — want, or refuse honestly

**What walgit does.** A batch API and basic transfer with objects in the bucket, plus optional read-through from an upstream LFS server for imported repositories.

**What we do.** Nothing. `OpenAgents.GitHub.lfs_warning_inputs/3` computes a one-time warning at import (`lib/openagents/github.ex:125`), and the import screen tells the person that "Git LFS pointer files are copied, but Git LFS objects are not included in this release" (`lib/openagents_web/live/repository_import_live.ex:121`).

**Should we want it.** The scale argument does not apply to us, but the correctness argument does: an imported repository that used LFS is broken at the blob level, and the current answer is a warning rather than a refusal. This is a product gap in the import surface, not a git-hosting gap.

**What it would cost here.** An LFS batch endpoint plus object storage under the WAL prefix is small; `WAL.put_object/3` already exists (`lib/openagents/forge/wal.ex:59`) and the artifact path already stores content-addressed blobs beside the log (`lib/openagents/forge/wal.ex:162`). The larger question is whether LFS objects are WAL entries — they are not, in walgit, and they should not be here either, because they are not part of the ref record.

### 3.3 Protocol v2 — we mostly have it, and our moduledoc disagrees with itself

**What walgit does.** It implements v2 itself: the capability advertisement is hand-written (`crates/walgit-server/src/smart.rs:139`), and `upload_pack_v2` dispatches `ls-refs`, `fetch`, `object-info`, and `bundle-uri` (`crates/walgit-server/src/smart.rs:202`). It parses the `fetch` request — wants, haves, `done`, `filter`, `deepen`, `deepen-since`, `deepen-not`, `shallow`, `sideband-all` — and then, by default, re-serializes it to a stock `git upload-pack --stateless-rpc` subprocess to generate the packfile (`crates/walgit-git/src/lib.rs:2445`). Its own gitoxide engine runs only where stock git cannot: against a base pack read from the bucket.

**What we do.** `lib/openagents/forge/git_http.ex:3` calls the module "Git smart-HTTP v0", and `:19` says the `Git-Protocol` header "is passed through so protocol v2 works". Both the advertisement and the RPC set `GIT_PROTOCOL` in the stock binary's environment (`lib/openagents/forge/git_http.ex:554`, and the advertisement at `:68`), which is how v2 is served over smart HTTP. Read together, the two lines of the moduledoc disagree, and the first one is the one people quote.

**Should we want walgit's version.** No. We inherit v2 negotiation, ref prefixes, filters, shallow, and `sideband-all` from the stock binary at no cost. The reason walgit implements the protocol itself is the reason in section 5.4: it wants to answer `ls-refs` from the log without a materialized repository. Until we want that, implementing v2 buys nothing.

**What to do instead.** Correct the moduledoc's first line, and settle the behavior with evidence rather than reading — see follow-up 7.6.

### 3.4 `bundle-uri` — want later, and not for the reason it exists

**What walgit does.** Bundles are cut on calendar cron slots as a pure function of the log: for each slot the builder resolves the highest sequence whose `created_at` is at or before the slot and replays refs to it in memory (`crates/walgit-wal/src/log_reader.rs:99`), so a bundle built late still contains the state as of its slot and a deleted bundle rebuilds identically. A weekly full carries chained dailies and hourlies above it. Two lists are served: `bundles/list` with fulls, for clones, and `bundles/catchup` without them, for fetches — the difference is one filter on an empty `base_id` (`crates/walgit-bundle/src/render.rs:117`). A separate blobless family answers `--filter=blob:none`, because git's bundle-uri client never consults a bundle's declared filter.

**Should we want it.** Not now, and the honest reason is in walgit's own measurement: for a client that fetches several times a day, upload-pack's thin pack is smaller than an hourly bundle; bundles pay off for fresh clones of a large repository and for far-behind clients. We have neither problem.

**What it would cost here.** Less than it appears, and more than it appears, in different places. We already produce bundles — the importer creates one (`lib/openagents/repositories/importer.ex:328`) and the stack ref batch path creates one per batch (`lib/openagents/forge/git_plane.ex:553`) — so the rendering machinery is partly present. What is missing is the thing that makes bundle slots a pure function of the log: an as-of-sequence ref query, which needs the checkpoint from 3.1 to be affordable. Bundle-uri is downstream of checkpoints, not parallel to them.

### 3.5 Placement — want when a repository stops fitting, not before

**What walgit does.** `[placement] serve` and `maintain` globs say which repositories a host does object work for. Refs-level reads work everywhere; a host that does not serve a repository answers its object work with `503` and a `Retry-After` before any synchronization, and names the host that does.

**What we do.** The opposite, deliberately. `Sync.ensure_cluster_fresh/3` warms the repository on every connected node (`lib/openagents/forge/sync.ex:43`).

**Should we want it.** Not yet, and the reason is that the two policies answer different questions. Ours is an availability decision: every node can serve every repository, so no request depends on routing. walgit's is a size decision: some repositories cannot fit on some hosts, so placement is the only way to have small hosts at all. The trigger for adopting placement is the first repository that does not fit a node, or a node count at which full replication wastes more than it buys. Neither has happened.

### 3.6 Leases — want exactly when we get a maintenance unit, plus one case today

**What walgit does.** A CAS-with-TTL lease at `leases/<name>.pb`, with `holder`, `purpose`, `acquired_at`, `expires_at`, and a heartbeat `epoch` (`crates/walgit-store/src/coord.rs:298`). It is used for exactly two things: compaction and bundle builds. Publishing takes no lease, because the manifest CAS already serializes it, and log checkpoints take none either, because they are deterministic for a given state — a writer that dies mid-checkpoint leaves garbage, never a hazard.

**Should we want it.** For the WAL, only when we have a maintenance unit expensive enough that running it twice matters, which means after 3.1. That restraint is worth copying: the lease is not a general coordination primitive in walgit, and adding one before there is work to serialize would invite exactly the second-authority problem `EXIT-003` exists to prevent.

There is one case today. `mirror_now/1` is a force push of every ref and cannot detect a mirror that is ahead; `docs/2026-08-21-repository-storage-architecture-audit.md` §3.1 ranks it as the largest blast radius in the system and says in as many words that "the boundary needs a lease, not just a direction". A CAS lease in the WAL bucket is a natural fit and would not make the mirror an authority, because a lease says who may write, not what is true.

### 3.7 The remote reader — an answer to a problem we do not have

**What walgit does.** For a repository whose live pack set exceeds an instance's cache budget, only the pack indexes are downloaded; pack data stays in the bucket and is read with 1 MiB range GETs through a process-wide block LRU, with delta chains resolved in process and decoded objects cached (`crates/walgit-wal/src/remote.rs:28`, `:82`, `:424`). The web API faults exactly the objects a git command will touch into the loose store and then runs unmodified git renderers. Protocol v2 fetch works against it; protocol v0 is refused with a message naming the fix, because v0 goes through the stock subprocess and stock git cannot read a pack that is not on disk (`crates/walgit-server/src/smart.rs:768`).

**Should we want it.** No. We do not host a repository we cannot materialize. The audit at `docs/2026-08-21-repository-storage-architecture-audit.md` §3.4 records that our clone and push are bounded by RAM rather than disk, and the fix for that is streaming through the existing `put_entry_file/3` and `get_entry_file/3` paths (`lib/openagents/forge/wal.ex:117`, `:141`), not range reads into pack indexes.

**What to take from it anyway.** The refusal, not the reader. walgit's `check_fits` turns a pack set larger than the budget into a `503` with a message that names the alternative, before any bytes move. We have no admission check at all; a repository too large for a node fails somewhere inside a request instead of being refused at the door.

### 3.8 The events bridge — a rule we already believe and do not yet follow

**What walgit does.** Decision D32 forbids the push path from producing side effects. A separate bridge tails each repository's log from a durable cursor at `events/cursor.json`, converts committed entries to ref events, posts them, and advances the cursor only after the webhook acknowledged, so a crash loses nothing and lag is `head_seq` minus the cursor. Its principle III states the test: "If this side effect fails, does the push?" and "Is it replayable from the cursor?"

**What we do.** `mirror_async/1` starts a supervised task from inside the push path when a mirror URL is configured (`lib/openagents/forge/pushes.ex:428`). It is best-effort and never blocks or fails the push, which satisfies the first half of walgit's test. It fails the second: a mirror push lost to a restart is not replayable from a cursor, and `INVARIANTS.md` `EXIT-003` records the operational consequence — the mirror is off today, and turning it on force-pushes over whatever direct pushes left there.

**Should we want the bridge shape.** For the mirror, yes, and it is the same fix as 3.6: a cursor plus a lease turns the mirror from a fire-and-forget side effect into a reader of the log that cannot skip and cannot double-write. Our push receipts already work this way — `Pushes.reconcile_receipts/1` re-derives them from the WAL keyed by index position (`lib/openagents/forge/pushes.ex:209`) — so the pattern is in the codebase and applied to one consumer out of two.

---

## 4. What we have that walgit does not

State the asymmetry first. walgit is a git host and nothing else; its `GOAL.md` scope section exists to keep it that way, and principle X asks of every new dependency, "Which line of `GOAL.md` §4 is this for?" Our forge is one plane of a product whose issues, projects, receipts, memberships, and authorization live in PostgreSQL. Most of what follows is therefore product rather than git hosting, and comparing it to walgit is comparing a component to a system. Two items are not, and they come first.

### 4.1 A tamper-evident log

This is the one place where our git-hosting layer does something walgit's does not, and the gap is larger than expected.

walgit has no cryptographic chain over its log. `LogEntry` has no `prev_hash`, no digest, and no signature (`crates/walgit-proto/proto/walgit/v1/wal.proto:141`); the framing is a length prefix and a protobuf body with no checksum. Packs are named by their own trailing SHA, but that name is not verified on any read path: `download_object` checks size only (`crates/walgit-wal/src/sync.rs:330`), `install_pack` renames without `index-pack --verify`, and the remote reader never re-hashes a decoded object against the oid that was asked for. Content addressing in walgit is a naming convention, checked at client ingest by `git index-pack` and nowhere else. An operator with bucket write access can rewrite a log segment and CAS the manifest to match, and no replica has anything to notice with. Its `docs/INTEGRITY.md` does not claim otherwise; it is scoped to accidents — a bad import, an over-eager collection, a compaction that dropped objects — and states no adversary model.

Ours does more, and states its limits with the same care. Every entry carries a `link`: `sha256` over a domain tag, the previous entry's link, and a canonical encoding of the entry's own fields, computed in the one function every writer reaches the log through (`lib/openagents/forge/wal.ex:269`, `:213`). `Verification.verify/2` recomputes the chain, re-hashes each entry's bytes against the content-addressed key the index recorded, and reports `chain_link_mismatch`, `chain_link_missing`, `entry_digest_mismatch`, `entry_sequence_broken`, `served_refs_diverged`, `object_missing`, and `object_unreachable` (`lib/openagents/forge/verification.ex:13`). It reaches no database at all, and `EXIT-002` proves that structurally by reading the module's compiled import table.

The limit is stated as plainly as the property, in `EXIT-005` and in `lib/openagents/forge/wal.ex:29`: the chain makes a rewrite total rather than impossible, so an operator who recomputes every link produces a self-consistent log that a verifier with no outside commitment reports clean. While this comparison was being written, a separate lane closed the publication half. `OpenAgents.Forge.Anchor` writes a document naming each public repository's entry count, head sequence, head chain link, and ref-map digest, chained to the anchor before it by `previous_digest`, and serves it verbatim at `/.well-known/openagents-forge-anchor.json` (`lib/openagents/forge/anchor.ex:74`, `lib/openagents_web/router.ex:390`, and `docs/decisions/0008-publish-the-forge-wal-anchor-at-a-well-known-path.md`).

That module's own account of what it proves is the reason this is worth citing in a comparison document: "On its own, nothing. The operator serves the document and could serve any document." `Forge.Independence` therefore publishes `anchor_published` and `anchor_witnessed` as two separate facts and stays degraded on the second, counting anchors actually written rather than reading a configuration flag (`lib/openagents/forge/independence.ex:129`).

So the honest comparison is: we hold a property walgit has none of, we publish a commitment to it where a stranger can copy it, and we say on the same page that nobody has attested to it yet.

### 4.2 An invariant ledger with executable proofs

Both projects keep a written contract, and comparing them as artifacts is a genuine like-for-like.

walgit's is in `AGENTS.md`: ten numbered principles, each with "the tell in a PR" and "the question to answer", plus 32 decisions in force under an append-never-silently-change rule, plus nine invariants restated in `README.md`. Enforcement is review, a simulation suite with fault injection, and a cost model in `docs/ROUNDTRIPS.md` that a protocol change has to argue against. Its sharpest instrument is `healthy_request_round_trip_budgets`, which pins push at 5 requests, warm refs at 1, cold refs at 2, and a checkpoint at 4 (`crates/walgit-server/tests/sim.rs:1645`).

Ours is `INVARIANTS.md`: 123 contracts, each with a status and an entry in a proof index, and `ops/ci/docs-check.exs` fails the gate when a `Current` contract has no executable proof file, when an ID is duplicated, when the proof index and the sections disagree, or when a contract names a path that does not resolve.

The comparison is not flattering in one direction only. Our ledger is an order of magnitude larger and covers the whole product rather than one component, and it is machine-checked in ways walgit's is not. But `ops/ci/docs-check.exs` checks that a proof file exists, not that the proof can fail for the claim — and `docs/2026-08-23-invariant-proof-audit.md` exists because that gap produced four false contracts, `ADMIN-001` among them, each green while its claim was false. walgit's budget test is a better artifact than anything we have for the property it covers: it is a number, it is measured, and a regression turns it red. We should want that shape, applied to a property we care about.

### 4.3 Receipts and the deployment plane

`docs/taxonomy.md` keeps the planes apart: a push is a receipt, not a deployment, and a push never promotes itself. walgit has no counterpart to either half. Push receipts are derived from the WAL and re-derivable from it (`lib/openagents/forge/pushes.ex:209`, `INVARIANTS.md` `EXIT-003`); build, deploy, and gate receipts record what the deployment plane did; and the plane itself — promotion, build, artifact verification, hot loading, boot convergence, rolling replacement — has no analogue in a git host and should not.

One decision from that plane is worth naming here because it is the sharpest expression of the shared architecture. Commit `6a5cf7d` gave `forge_builds` and `forge_deploys` a `repository_id` foreign key and deliberately declined to give one to `forge_pushes`. The reason is in `lib/openagents/forge/receipt_repository.ex:14` and in `EXIT-003`: `forge_pushes.repo` is a storage key with a unique index, so it already names one repository, and a key only PostgreSQL could produce would not survive `reconcile_receipts/1`, which rebuilds the table from the WAL alone. `EXIT-003` records the absence as the invariant holding rather than as an omission. That is our version of walgit's "the bucket is the repository", reached from the opposite direction: walgit has no database to be tempted by, and we have one and had to name the temptation.

### 4.4 Disclosure

`Forge.Visibility` gives each repository a public level — `dark`, `pulse`, `ledger`, `glass` — governing what the transparency surfaces may show (`lib/openagents/forge/visibility.ex:6`), and `OpenAgents.Transparency` applies the same four tiers to artifacts. `Forge.Independence` publishes, on the status page, a derived answer to three questions about what the operator can do, with `degraded` as their disjunction and every claim counted from a ledger rather than restated by hand (`lib/openagents/forge/independence.ex:2`, `INVARIANTS.md` `EXIT-006`).

walgit's bundled web UI carries a health page for the WAL, which its `README.md` lists beside the tree, blob, commit, and diff views. It has no notion of disclosing what its operator can do, and for a self-hosted single-tenant binary that is a reasonable scope: the operator is the reader.

### 4.5 Everything above the git plane

Issues, projects, milestones, labels, the GitHub-shaped `/api/v3` subset, evidence chains, accepted outcomes and completion claims, the forum, memberships and API-token scopes. None of this is a comparison; it is the reason the two repositories are different sizes. walgit is 68,231 lines that host git. `lib/openagents/forge/` is 15,519 lines that host git and drive deployments, inside an application that does much more.

---

## 5. Where walgit's design exposes a weakness in ours

This is the section worth the document. Each item is a property walgit has that we lack, stated as the cost we are paying rather than as a feature we are missing.

### 5.1 The index is the log, so every read and every push carries the whole history

We have no log checkpoint and no compaction. A search of `lib/openagents/forge/` for `checkpoint`, `compact`, `snapshot`, and `repack` returns nothing in the WAL, its adapters, or the synchronizer; the only hits are unrelated — `BuildArtifact`'s BEAM compact-integer decoder, `DeploymentNode`'s prior-state snapshot, and the thread save point `docs/taxonomy.md` records as proposed. The absence is structural rather than accidental: the index document carries `"entries"`, the full ordered list of every entry ever appended with each entry's complete post-state ref map (`lib/openagents/forge/wal.ex:12`), and `next_seq/1` is `length(entries)` (`lib/openagents/forge/wal.ex:335`). Nothing can fold that list without changing what a sequence number means.

Four costs follow, and they compound.

- **Every read downloads the whole index.** `read_index/1` issues an unconditional metadata `GET` for the generation and then an unconditional media `GET` for the body (`lib/openagents/forge/wal/gcs.ex:37`, `lib/openagents/forge/wal/gcs.ex:251`). There is no conditional `GET`, no `ETag`, no `304`, and no freshness window.
- **Every push uploads the whole index.** `cas_index/3` re-encodes and re-uploads the entire document under `ifGenerationMatch` (`lib/openagents/forge/wal/gcs.ex:46`). Push cost is linear in total push count.
- **A cold node replays every entry.** `do_replay_missing/3` walks the entry list and runs one `git receive-pack` per unapplied entry, each preceded by a download of that entry's payload (`lib/openagents/forge/sync.ex:108`, `lib/openagents/forge/sync.ex:232`, `lib/openagents/forge/sync.ex:336`). There is no snapshot to start from.
- **The bucket keeps every push pack forever.** Entries are immutable and content-addressed, and nothing supersedes them.

walgit's manifest is the opposite shape and the proto comments say why. `Manifest` carries `head_seq`, `min_seq`, a `CheckpointRef`, a list of `LogSegmentRef` pointers, the live `PackRef` set, and inline settings — no entries (`crates/walgit-proto/proto/walgit/v1/wal.proto:27`). Log checkpoints fold the list: `checkpoint.rs` writes `checkpoints/<seq>/refs.pb` and `checkpoint.pb`, then CASes the manifest to advance `min_seq` and drop every folded `log_segments` entry (`crates/walgit-wal/src/checkpoint.rs:232`). Folding fires on any of three triggers — 256 entries, an 8 MiB log tail, or an hour — and it is refs-level work, so an instance that could never hold the repository's packs can still write one (`crates/walgit-wal/src/checkpoint.rs:38`, `crates/walgit-wal/src/checkpoint.rs:91`). Geometric compaction is published as a `COMPACT` entry naming the packs it supersedes, so a replica downloads the compacted pack and drops the sources instead of repacking (`crates/walgit-wal/src/publish.rs:1000`, `crates/walgit-wal/src/sync.rs:946`).

This is not a new finding. `docs/2026-08-21-repository-storage-architecture-audit.md` §3.9 already records it as "The WAL index grows without bound and is rewritten on every push", ranked low now and certain later, and adds a multiplier this comparison did not have to find: `Forge.Janitor` reads the index of up to 1,000 ready repositories every hour on every node, which is still true today (`lib/openagents/forge/janitor.ex:29`, `:54`, `:122`). What walgit adds is the demonstration that the fix is neither large nor exotic, and a worked example of the exact shape it takes.

### 5.2 There is no round-trip budget, and nothing would notice a regression

walgit treats bucket round trips as the performance design rather than as an implementation detail. Its `docs/ROUNDTRIPS.md` states the primitive costs it measured (60–80 ms for a small `GET` or `PUT`, 15–18 ms for a conditional `GET` that answers `304`, a free `404`, roughly one serialized write per second on a CAS'd object), tabulates the budget every operation must defend, and requires a protocol change to argue against that table. Its `AGENTS.md` principle VII makes "count the round trips" a review question, and `healthy_request_round_trip_budgets` pins the numbers in a simulation test: a healthy push at 5 requests, a warm refs read at 1, a cold refs sync at 2, a log checkpoint at 4 (`crates/walgit-server/tests/sim.rs:1645`).

We have no equivalent artifact. Our warm refs read costs two unconditional requests plus the full index body, and no test asserts a number, so a change that made it four would land silently. This is a gap in the invariant ledger's coverage as much as in the code: `INVARIANTS.md` binds correctness properties of the WAL thoroughly and cost properties not at all.

### 5.3 Reads serialize on a per-repository lock held across the network

Every read path calls `Sync.ensure_fresh/2`, which runs inside `with_repo_lock/2` — a `:global.trans` on `{{OpenAgents.Forge.Sync, repo}, self()}` over `[node()]` (`lib/openagents/forge/sync.ex:83`, `lib/openagents/forge/sync.ex:101`). Two unconditional GCS requests happen inside that lock, and so does any replay. Concurrent clones of one repository on one node therefore serialize behind each other's bucket latency, and a cold cache serializes them behind a full replay.

walgit's decision D19 exists because it hit exactly this: "one 24-minute clone once starved every info/refs for minutes". Its answer is to split the phases — the refs phase takes only `sync_mutex`, pack materialization runs on a separate bulk runtime, pack removal uses `try_write()` so a queued writer never blocks new readers, and control-plane objects never share a transport or a permit with bulk bytes.

### 5.4 Serving refs requires the whole repository on disk

`advertise/4` synchronizes the cache and then runs `git upload-pack --advertise-refs` against the local bare repository (`lib/openagents/forge/git_http.ex:63`, `lib/openagents/forge/git_http.ex:68`). A ref advertisement therefore needs every object the repository holds to be present locally, even though the WAL index already carries the exact ref map the advertisement would print (`lib/openagents/forge/wal.ex:341`).

walgit's Refs sync level answers `info/refs`, `ls-refs`, bundle lists, and its web refs endpoints from the log checkpoint's ref snapshot plus the log tail, writing refs offline with no `git update-ref` "so it works before the packs exist locally" (`crates/walgit-wal/src/sync.rs:929`). That is what lets it serve a repository larger than the instance at all, and it is also why its cold path is two requests rather than a replay.

We do not host a repository we cannot materialize, so this is not a live incident. It is a ceiling: the first repository that does not fit a node is a repository this forge cannot serve in any degraded mode, and today nothing refuses it early either — there is no counterpart to walgit's `check_fits`, which turns a pack set larger than the cache budget into a `503` before any work starts.

### 5.5 The ordinary push path enforces no ref policy

`repositories.protected_branches` exists as a column (`lib/openagents/repositories/repository.ex:20`), and `authorize_receive_pack/3` consults it — but only for an `:assignment` principal (`lib/openagents/forge/git_http.ex:284`, `lib/openagents/forge/git_http.ex:304`). Every other principal that passed the write authorization falls through the last clause to `:ok` (`lib/openagents/forge/git_http.ex:299`). An ordinary token with `forge:write` may force-push or delete any ref, including the default branch, and the protected-branch list does not apply to it.

walgit's decision D16 makes push authorization a per-repository rule language published at `policy.json`, with an envelope of `version`, `groups`, and `rules`, where `protect` is a conjunction, and a missing file means "anyone with write may move any ref" — the same default we have, but reached deliberately and with a mechanism to change it per repository.

This is the smallest item here and probably the easiest to close, and the gap between the column's name and its actual reach is exactly the kind of claim `docs/2026-08-23-invariant-proof-audit.md` was written about.

### 5.6 Nothing folds or audits the log, and nothing checks what the projection holds

We have three scheduled jobs beside the git plane and none of them looks at the repository. `Forge.Janitor` sweeps stale per-job clones and build artifacts and re-derives push receipts, and its moduledoc is explicit that it "Never touches bare repos or the WAL: those are re-materializable truth, not cache to expire" (`lib/openagents/forge/janitor.ex:15`). `Forge.MirrorWatch` exports accepted commits. `Forge.AnchorPublisher` reads each public repository's log head hourly and publishes a commitment to it (`lib/openagents/forge/anchor_publisher.ex:28`). Reading the head is not auditing the log, and none of the three would notice a projection that cannot be walked.

walgit's maintainer is a different kind of object. Its output is a pure function of `(config, WAL)`, it computes the desired state every pass and performs one bounded unit of the most important missing work, in a fixed priority order: log checkpoint, then repair, then missing bundle slots oldest first, then compaction, then reverse-index backfill, then a connectivity audit whose report is written to `fsck.pb` and consumed by the repair unit (`crates/walgit-server/src/maintain.rs:271`, `crates/walgit-server/src/maintain.rs:398`). An outage leaves no permanent hole, because a missing artifact is one that has not been built yet and the next pass builds it.

The consequence for us is section 6.

---

## 6. What walgit's design would have done about #179

On 2026-08-23 the live forge was found unable to serve a full clone of its own repository. The cause is recorded in commit `f29fb0d` and in the amendment to `REPOSITORY-003`: this repository's log was seeded from a `--depth=1` fetch, which copies one commit per ref and no ancestry, and it was written before WAL entries carried a `shallow` key. The log recorded no boundary, replay had none to write, and the projection reached disk holding a commit whose parent it did not have. Every check the forge had asked whether ref *tips* resolved, and they all did, so `EXIT-004` stayed green while a clone aborted on `c91327d6`.

Asking what walgit would have done gives four separate answers, and one of them is uncomfortable.

**Its push path would not have prevented it.** walgit's receive-pack connectivity check runs with `stop_at_existing_refs = true`, which hides everything already reachable from current refs from the walk (`crates/walgit-server/src/smart.rs:1191`, `crates/walgit-git/src/lib.rs:1487`). That is the same assumption ours makes and the same reason a shallow seed passes: the check asks whether the *new* objects connect to what is already there, not whether what is already there connects to anything.

**Its import path would have caught it, with the command our fix now uses.** `walgit import --direct` runs `verify_refs_in_packs`, which builds a scratch bare repository over the pack directory and runs `git rev-list --objects --missing=print` (`crates/walgit-cli/src/import_direct.rs:983`, called at `:458`). That scratch repository has no `shallow` file, so a shallow-seeded pack reports its absent parents as missing and the import fails closed. Our fix reaches the same place by the same route: `Sync.servable?/1` runs `git rev-list --objects --quiet --all` and `derived_boundaries/1` runs `git rev-list --all --parents --missing=print` (`lib/openagents/forge/sync.ex:192`, `:199`). The convergence is worth noticing — the traversal that would fail a clone is the only honest population for the check — but so is the timing. walgit runs it at seed time and refuses; we ran nothing at seed time and added the traversal after a person could not clone.

**Its maintainer would have found it within seven days.** The connectivity audit runs `git fsck --connectivity-only` on a cadence of `maintenance.fsck_interval`, default seven days, writes a `FsckReport` to `fsck.pb`, and sets a `walgit_repo_missing_objects` gauge per repository (`crates/walgit-server/src/ops.rs:217`, `:277`, `crates/walgit-server/src/maintain.rs:398`). walgit writes no `shallow` file and has no concept of a graft — a grep for `graft` over its crates returns nothing — so a shallow-seeded repository is, to walgit, a repository with missing objects, which is exactly what the audit reports. We had no scheduled audit of the object graph, and still do not, and that is the real difference: not that walgit is cleverer about shallow state, but that it looks.

Two caveats keep this honest. The audit is the lowest-priority unit and only runs when nothing else is due, and it is gated on the whole pack set fitting locally (`crates/walgit-server/src/maintain.rs:400`), so a repository served from the bucket is never audited on that host.

**Its repair is unavailable to us by invariant, and that is the uncomfortable part.** When the audit finds missing objects, walgit promotes a repair unit *only if* `upstream.git` is configured (`crates/walgit-server/src/maintain.rs:286`). Repair fetches the missing object IDs from that upstream with `--depth=1`, packs exactly those IDs, and publishes them as a tier-0 entry (`crates/walgit-git/src/repair.rs:74`); with no upstream, the gap sits in the gauge and nothing heals. So walgit's answer to a hole in history is *fetch it from somewhere else*.

For us, "somewhere else" is GitHub, and `EXIT-003` forbids it. The proof reads the compiled import tables of `Forge.Sync` and `Forge.Repos` and fails on a call into `Forge.MirrorWatch` or into the mirror functions of `Forge.Pushes`, precisely so a lost forge cannot quietly promote the mirror to source of truth through a fallback someone added during an incident. walgit can heal history because it never claimed the bucket was the only authority for object bytes; we claimed it, we hold it, and the price is that a hole the WAL never held stays a hole.

That is the right trade and it should stay. But it changes what our answer to #179 has to be. walgit's answer is *repair*; ours can only be *record the boundary honestly and detect the hole early*, which is what `f29fb0d` does — a derived graft so a clone succeeds and reports that history ends there, plus `object_unreachable` so the traversal that would fail a clone is the population under test. What is still missing is the third leg walgit has and we do not: something that runs the traversal on a schedule rather than on demand, so the next hole is found by the forge instead of by a person cloning.

---

## 7. Follow-ups

Each is specific enough to become an issue. None is a decision; the doc is a comparison, and `INVARIANTS.md` is not edited here.

1. **Fold the WAL index behind a checkpoint object.** Move the entry list out of the index and leave a head sequence, a checkpoint pointer, and a tail. Settle first what a fold does to `EXIT-002`'s `entry_sequence_broken`, to `EXIT-005`'s chain and its `chained_from`, and to `next_seq/1`'s definition as `length(entries)` (`lib/openagents/forge/wal.ex:335`). This is the largest item here and the prerequisite for several others. It closes `docs/2026-08-21-repository-storage-architecture-audit.md` §3.9.

2. **Make the index read conditional.** `read_index/1` issues two unconditional requests and downloads the whole body every time (`lib/openagents/forge/wal/gcs.ex:37`, `:251`). An `If-None-Match` against the stored generation, with a bounded freshness window, would make the common case one cheap request. Pair it with a test that asserts the request count, in the shape of `crates/walgit-server/tests/sim.rs:1645`.

3. **Bind the ordinary push path to `protected_branches`.** `authorize_receive_pack/3` consults the column only for an `:assignment` principal (`lib/openagents/forge/git_http.ex:284`); every other write principal falls through to `:ok` at `:299`. Decide whether the column means what its name says for every principal, and make the proof quantify over principals rather than over the assignment surface — the failure mode `docs/2026-08-23-invariant-proof-audit.md` names.

4. **Run the connectivity traversal on a schedule.** `Verification.verify/2` already computes `object_unreachable` from `rev-list --objects` over the exportable refs (`lib/openagents/forge/verification.ex:313`). Nothing runs it unattended. A periodic pass that records the result and surfaces a non-empty finding would have found #179 without a person cloning. `Forge.AnchorPublisher` is the nearest precedent for the shape — a scheduled reader of the WAL that is not on the push path and cannot fail one (`lib/openagents/forge/anchor_publisher.ex:2`) — and a companion job could reuse it. Decide where the result lives, given that it must not become a second authority.

5. **Give the mirror a lease and a cursor.** `mirror_async/1` fires from the push path and is not replayable (`lib/openagents/forge/pushes.ex:428`), and `mirror_now/1` force-pushes every ref with no way to detect a mirror that is ahead — the largest blast radius in `docs/2026-08-21-repository-storage-architecture-audit.md` §3.1. A durable cursor plus a CAS lease in the WAL bucket makes the mirror a reader of the log, the shape walgit's decision D32 requires of every side effect.

6. **Settle which protocol versions the forge actually serves, with evidence.** `lib/openagents/forge/git_http.ex:3` says v0 and `:19` says v2 works; both cannot be the headline. A `GIT_TRACE_PACKET` clone against staging that asserts the negotiated version would settle it, after which the moduledoc says one thing.

7. **Refuse a repository that cannot be materialized, at the door.** There is no counterpart to walgit's `check_fits`, so a repository too large for a node fails inside a request. A bounded admission check that answers `503` with a message naming the limit is small and independent of everything else here.

8. **Decide what the import surface promises about Git LFS.** Today it copies pointer files and warns (`lib/openagents_web/live/repository_import_live.ex:121`). Either implement the batch API with objects under the WAL prefix, or make the import refuse a repository that uses LFS. The warning is the one option that leaves a person with a repository that looks imported and is not.

---

## 8. What this document could not settle

- **Whether protocol v2 is negotiated end to end in production.** The delegation is unambiguous in the source — `GIT_PROTOCOL` reaches the stock binary on both the advertisement and the RPC — but no test or trace in this repository asserts the negotiated version. A `GIT_TRACE_PACKET` clone against the live forge would settle it. Follow-up 7.6.
- **The live size of this repository's WAL index and its entry count.** Both determine how urgent follow-up 7.1 is, and neither is readable from the repository. Reading the index object from the bucket would settle it.
- **walgit's behavior under load.** Everything here is read from its source and its simulation tests. Its `AGENTS.md` records measurements taken during its own development, and the throughput figures in the Cursor post belong to Continuity rather than to walgit. Nothing in this comparison was measured by running either system.
- **Whether walgit's stated invariants hold in practice.** Two research passes over its crates found six places where its own documentation overstates the code — including a `format_version` the proto says readers reject and no reader checks, `ENTRY_KIND_CHECKPOINT` entries that nothing writes, log-segment merging that does not exist, and a `compaction.retention_superseded` knob with no reader, meaning superseded packs accumulate in the bucket indefinitely. Those are findings about walgit's documentation, not about its correctness, and this document reports them without having run it.
