# Repository storage

**Date:** 2026-08-21
**Commit measured:** `5116bfe5d8ef` (`openagents/main`, the forge)
**Question:** How does this application store Git repositories today? Is the SCV's repository storage different from the way the main repository is stored and synchronized, and should it be? What should you build, in what order, to make the whole thing sound?
**Method:** direct reading of `lib/openagents/forge/` (`repos.ex`, `wal.ex`, `wal/gcs.ex`, `sync.ex`, `pushes.ex`, `git_http.ex`, `browse.ex`, `janitor.ex`, `mirror_watch.ex`, `supervisor.ex`, `boot_converge.ex`), `lib/openagents/repositories.ex` and `lib/openagents/repositories/`, `lib/openagents/scv/`, `lib/openagents/tools/repository.ex` and the repository tool family, `lib/openagents_web/router.ex`, `lib/openagents_web/plugs/forge_git_auth.ex`, `lib/openagents/runtime_config.ex`, `config/`, `Dockerfile`, `rel/`, `infra/staging/`, `ops/`, `docs/openagents-cli/`, `INVARIANTS.md` (REPOSITORY-001 and REPOSITORY-002), and `ops/ci/push-remote-check.sh`, plus an exhaustive search of `lib/` for every process that runs `git` or writes to disk. Every architectural claim cites a file and line current at the measured commit. Claims the repository cannot settle are collected in section 8 with the command that would settle them, rather than repeated as fact.

---

## 0. Summary

There is **one** repository store, not several. The durable authority is the Forge write-ahead log in object storage; every node keeps a disposable bare-repository cache under `/var/lib/openagents/forge/repos/<storage-key>.git`. The GitHub importer, the Git smart HTTP transport, the code-browsing pages, the coding-job tools, and the SCV all read and write through that one store. The imported repository and the `openagents.com` repository that this application runs from are the same kind of object in the same store, distinguished only by an allowlist and a mirror URL.

So the premise behind the owner's question is the wrong way round. The SCV does not have its own repository storage. It clones from the same bare repository the web server serves (`lib/openagents/scv/workspace.ex:12`, `:28`), and there is no inbound "main repo sync" for it to differ from — the GitHub import is explicitly one-time (`INVARIANTS.md:1781`), and the only other GitHub traffic is an outbound mirror push (`lib/openagents/forge/pushes.ex:240`).

The real split is not between SCV and the main repository. It is between **durable state disk** and **container `/tmp`**, and the codebase draws that line inconsistently. `OpenAgents.RuntimeConfig` refuses to boot in staging or production if `forge_data_dir`, `coding_jobs_dir`, `forge_wal_dir`, or `ra_data_dir` sit under `/tmp` (`lib/openagents/runtime_config.ex:634`, `:998`). The two largest transient writers are exempt from that rule and default to `/tmp` anyway: the GitHub import workspace (`lib/openagents/repositories/importer.ex:657`) and the Git RPC stdin file that every clone and every push writes (`lib/openagents/forge/git_http.ex:375`). The SCV workspace root is exempt too (`lib/openagents/scv/workspace.ex:59`, `config/runtime.exs:213`). In the staging topology, `/var/lib/openagents` is a dedicated 100 GiB volume bind-mounted into the container (`infra/staging/templates/fleet-startup.sh.tftpl:16`, `:24`, `:203`), while `/tmp` is the container's writable layer on the 20 GB boot disk that also holds every Docker image (`infra/staging/main.tf:655`). An import therefore fills the small disk while the large one sits idle.

The owner-supplied assessment is right that imports run on live application nodes and that every node materializes a full cache. It is wrong or overstated on several checkable points, most importantly: the bundle upload does not need a third temporary copy, the import is a depth-1 snapshot rather than full history, `/var/lib/sarah-forge` is not the host path in this repository, and the `docker image prune` that "recovered 2.887 GB per node" was added on 2026-08-21 to a staging Terraform template that has never been applied. Section 4 itemizes all of it.

One failure mode outranks all of the disk findings, and it is not about disk. The GitHub mirror pushes with `--mirror`, a force push of every ref (`lib/openagents/forge/pushes.ex:240`), and the drift watcher that triggers it compares the two `main` values for equality with no ordering test, classifying a mirror that is *ahead* as lag and force-overwriting it (`lib/openagents/forge/mirror_watch.ex:73`, `:82`). It then reports "current" and records no incident. As of the measured commit, the forge and GitHub have diverged in exactly that direction. `INVARIANTS.md:1794` (REPOSITORY-002) now guards the cause by refusing pushes to any non-forge remote; the mechanism itself is unchanged. Section 3.1 traces it.

The first things to build are small, and none of them is sharding: teach the mirror to refuse an ahead mirror, move transient repository writes onto the durable volume, put a ceiling on the import retry loop, and check free space before an import starts instead of discovering `ENOSPC` from `git`'s stderr.

---

## 1. How repository data is stored today

### 1.1 The shape of the system

```
                       durable authority
                 ┌───────────────────────────────┐
                 │  GCS bucket <project>-         │
                 │  openagents-forge-wal          │
                 │    forge/wal/<key>/index.json  │  ← CAS on generation
                 │    forge/wal/<key>/entries/*   │  ← immutable payloads
                 └───────────────────────────────┘
                    ▲            ▲            │
       append entry │            │ append     │ replay entries
       (receive_pack)│           │ (git_bundle)│ (seq > applied_seq)
                    │            │            ▼
  ┌─────────────────┴──┐   ┌─────┴──────┐   ┌──────────────────────────────┐
  │ Path B             │   │ Path C     │   │ Path A: node-local cache      │
  │ git smart HTTP     │   │ GitHub     │   │ /var/lib/openagents/forge/    │
  │ push (receive-pack)│   │ import     │   │   repos/<storage-key>.git     │
  └────────────────────┘   └────────────┘   │ (state disk, one per node)    │
                                            └──────────────────────────────┘
                                              ▲     │        │         │
                     serve clone/fetch ───────┘     │        │         │
                     (Path B, upload-pack)          │        │         │
                                                    │        │         │
                     browse pages ──────────────────┘        │         │
                     (Forge.Browse)                          │         │
                                                             │         │
                     Path E: coding-job clone ───────────────┘         │
                     /var/lib/openagents/coding-jobs/job-<id>          │
                     (state disk, local clone, hardlinked)             │
                                                                       │
                     Path F: SCV workspace ────────────────────────────┘
                     /tmp/openagents-scv-workspaces/<execution-id>
                     (boot disk, --no-local, full object copy)

                     Path D: mirror push ── git push --mirror ──▶ GitHub
                     (one-way, best effort, allowlisted repos only)
```

PostgreSQL holds repository identity, membership, lifecycle state, provisioning work, and push receipts. It never holds Git objects or refs; `lib/openagents/forge/pushes.ex:138` states the rule directly, and the receipts are derived from the WAL rather than written beside it.

### 1.2 Path A — the write-ahead log and the node-local bare repositories

The authority is `OpenAgents.Forge.WAL`. Each repository has one JSON index document and a series of immutable entry objects; a push appends one entry and then advances the index through a compare-and-swap on the storage generation, so two nodes can never both believe they advanced the same ref (`lib/openagents/forge/wal.ex:4`). The production adapter is `OpenAgents.Forge.WAL.Gcs`, keyed under `forge/wal/<repo>/` (`lib/openagents/forge/wal/gcs.ex:174`) in the bucket named by `OPENAGENTS_FORGE_WAL_BUCKET` (`config/runtime.exs:390`). The staging Terraform names that bucket `<project>-openagents-forge-wal` (`infra/staging/main.tf:457`).

The node-local copy is a plain bare repository at `Path.join([data_dir(), "repos", repo <> ".git"])` (`lib/openagents/forge/repos.ex:38`), with `data_dir/0` resolving to `OPENAGENTS_FORGE_DATA_DIR` or `/var/lib/openagents/forge` (`lib/openagents/forge/repos.ex:15`, `config/config.exs:208`, `config/runtime.exs:372`). The module is explicit that this is a cache: "Ref truth is the WAL … everything here can be deleted and re-materialized from it" (`lib/openagents/forge/repos.ex:3`).

Freshness is a single integer. Each bare repository stores the highest WAL sequence it has applied in a file named `openagents-wal-seq` (`lib/openagents/forge/repos.ex:114`, `:127`). `OpenAgents.Forge.Sync.ensure_fresh/2` reads the index, replays every entry above that number, then force-converges refs to the index's ref map (`lib/openagents/forge/sync.ex:71`). Replay is format-dependent (`lib/openagents/forge/sync.ex:88`):

- `receive_pack` entries are replayed by re-running the original `git receive-pack --stateless-rpc` request body (`lib/openagents/forge/sync.ex:162`).
- `git_bundle` entries are downloaded to a temporary file and applied with `git bundle unbundle`, then the shallow boundary file is rewritten (`lib/openagents/forge/sync.ex:114`).
- `empty_import` entries do nothing.

**Materialization is lazy for reads and eager cluster-wide after an import.** Every read path calls `ensure_fresh` before touching the repository: ref advertisement (`lib/openagents/forge/git_http.ex:61`), `upload-pack` (`:68`), `receive-pack` (`lib/openagents/forge/pushes.ex:39`), and the browse pages (`lib/openagents/forge/browse.ex:53`). A node that has never seen a repository therefore builds the whole thing inline inside the first HTTP request that asks for it. Separately, `Sync.ensure_cluster_fresh/3` fans the same work out to every connected node over `:erpc` (`lib/openagents/forge/sync.ex:40`), with the member list being `[Node.self() | Node.list()]` (`lib/openagents/cluster.ex:20`) — that is, all three fleet nodes, not a subset. The only caller is the import's final stage (`lib/openagents/repositories/importer.ex:167`). Node boot does **not** pre-warm repositories; `OpenAgents.Forge.BootConverge` only handles beam artifacts (`lib/openagents/forge/boot_converge.ex:349`).

Nothing evicts a bare repository. `OpenAgents.Forge.Janitor` prunes stale coding-job clones and stale beam tars, and its moduledoc says outright that it "never touches bare repos or the WAL" (`lib/openagents/forge/janitor.ex:16`). The only deletion is explicit, at repository delete time (section 1.7).

Nothing repacks one either. There is no `git gc`, `git repack`, or `git prune` call anywhere in `lib/`. The bare repositories accumulate whatever `receive-pack` and `bundle unbundle` leave behind, subject only to git's own automatic housekeeping, which the code neither configures nor disables.

### 1.3 Path B — Git smart HTTP

Three routes, one plug, one pipeline whose only member is the auth plug (`lib/openagents_web/router.ex:48`, `:191`), plus a legacy `/git` forward (`:200`). `Plug.Parsers` is configured with `pass: ["*/*"]` and no `body_reader` (`lib/openagents_web/endpoint.ex:56`), and git's content types match no parser, so the body arrives at `OpenAgents.Forge.GitHTTP` unread.

Authorization runs before the body is read, and anonymous reads of public repositories are allowed with no credential (`lib/openagents/forge/git_http.ex:223`). Writes require a user with write membership, an operator token, or a machine with an explicit `write` grant (`lib/openagents/forge/git_http.ex:234`). Unknown repositories return 404 to authenticated principals and a Basic challenge to anonymous ones, so existence does not leak (`lib/openagents/forge/git_http.ex:278`).

The body handling is the part that matters for storage:

- The request body is accumulated in the process heap in 8 MiB chunks and then flattened with `IO.iodata_to_binary/1`, so peak heap is roughly twice the body (`lib/openagents/forge/git_http.ex:335`).
- The ceiling is `@max_body_bytes 512 * 1024 * 1024` (`lib/openagents/forge/git_http.ex:30`). The check happens after each append, so a request can overshoot by one chunk before the 413.
- `content-encoding: gzip` bodies are inflated whole with `:zlib.gunzip/1` and no output cap (`lib/openagents/forge/git_http.ex:354`). This is already recorded as the top security finding S1 in `docs/2026-08-21-full-codebase-audit.md`.
- The buffered body is then written **whole to a second copy on disk**, at `Path.join(System.tmp_dir!(), "forge-rpc-…")`, so `git` can read it from stdin (`lib/openagents/forge/git_http.ex:373`). Each in-flight RPC costs body-size in RAM and body-size in `/tmp`.
- The response is equally unbounded. `run_git_service/4` uses `System.cmd/3` (`lib/openagents/forge/git_http.ex:386`), which collects the subprocess's entire stdout into one binary, and `upload_pack/3` hands that binary straight to `send_resp/3` (`lib/openagents/forge/git_http.ex:89`). Cloning an N-gigabyte repository materializes an N-gigabyte packfile in BEAM memory. There is no `send_chunked` anywhere in the Git path and no cap on the output.

There are no rate limits and no concurrency limit on `upload-pack`. The only serialization is the per-repository `:global.trans` around pushes (`lib/openagents/forge/pushes.ex:32`). `System.cmd/3` takes no timeout, so a hung `git` subprocess holds its request process indefinitely.

The push barrier is correct and worth preserving: `Pushes.do_handle/5` applies the pack locally, persists to the WAL, and only then acknowledges; if the WAL refuses the entry, local refs are rolled back to their pre-push values and the client sees a failure (`lib/openagents/forge/pushes.ex:57`, `:82`).

### 1.4 Path C — the one-time GitHub import

The import is durable work claimed from an outbox table, not a background task tied to a request. `OpenAgents.Repositories.Provisioner` polls every second, claims one row with `FOR UPDATE SKIP LOCKED`, and executes it in-process (`lib/openagents/repositories/provisioner.ex:72`, `:131`). The provisioner starts under `OpenAgents.Forge.Supervisor` on **every** node that has the forge feature enabled (`lib/openagents/forge/supervisor.ex:20`, `lib/openagents/runtime_supervisor.ex:62`). So yes: imports run on live application servers, and which server runs a given import is whichever one wins the row.

`OpenAgents.Repositories.Importer.copy_snapshot/6` runs six named stages (`lib/openagents/repositories/importer.ex:124`):

1. `prepare_workspace` — `mkdir_p` plus `chmod 0700` on a directory named `openagents-import-<import-id>-<n>` under `Application.get_env(:openagents, :repository_import_temp_dir, System.tmp_dir!())` (`lib/openagents/repositories/importer.ex:656`).
2. `initialize_source` — `git init --bare <workspace>/source.git` (`:198`).
3. `fetch_source` — one `git fetch --force --prune --depth=1 --no-tags --no-recurse-submodules` for `refs/heads/*` and `refs/tags/*`, using a GitHub token delivered through a `GIT_ASKPASS` script and a `0600` file inside the workspace, never on the command line (`:204`–`:232`).
4. `verify_snapshot` — refuses with `:source_changed` unless both the ref map and a SHA-256 digest over `(name, type, sha)` match what was frozen at request time (`:262`).
5. `create_payload` — `git bundle create <workspace>/snapshot.bundle --all`, then a size check against `@default_maximum_bundle_bytes 20 * 1_024 * 1_024 * 1_024` (`:12`, `:306`, `:313`).
6. `append_wal` then `materialize_cache` — the bundle is streamed into the WAL as a single `git_bundle` entry without loading it into the heap (`:604`, `lib/openagents/forge/wal.ex:99`, `lib/openagents/forge/wal/gcs.ex:29`), then `Sync.ensure_cluster_fresh/2` warms every connected node (`:167`).

Three properties of this design are easy to get wrong when reasoning about disk:

- **The snapshot is shallow.** `--depth=1` means the stored copy is tip commits only, with a `shallow` boundary file preserved through the bundle (`lib/openagents/repositories/importer.ex:633`, `lib/openagents/forge/sync.ex:144`). The CLI documentation states this plainly (`docs/openagents-cli/command-reference.md`), and `INVARIANTS.md:1781` records that the import "schedules no later synchronization". A 1 GB GitHub repository does not imply a 1 GB import; it implies whatever its tip trees and blobs weigh.
- **The upload does not need a third copy.** `put_payload/3` passes `{:file, bundle_path}` to `WAL.put_entry_file/3`, which digests and uploads the existing file in 1 MiB chunks (`lib/openagents/repositories/importer.ex:604`, `lib/openagents/forge/wal/gcs.ex:264`).
- **The workspace is released last, not before the warm.** `File.rm_rf(temporary_directory)` sits in the `after` block of `run_import/3` (`lib/openagents/repositories/importer.ex:53`), which runs only after `materialize_cache` finishes. The importing node's own replay downloads the bundle *again* into the same temporary root (`lib/openagents/forge/sync.ex:116`). For a snapshot of size `S`, peak usage on the importing node's `/tmp` is therefore about `3S`: `source.git`, `snapshot.bundle`, and the replay download — plus about `S` on the state disk for the materialized bare repository. Every other node peaks at about `S` on `/tmp` and `S` on the state disk.

Failure handling has two gaps. Commit `41a8655` ("Report repository import storage failures") added string matching on `git` output for `"no space left on device"` and `"disk quota exceeded"`, mapping both to `:insufficient_storage` (`lib/openagents/repositories/git_failure.ex:4`, `:18`) and then to the error code `"insufficient_storage"` on the import row (`lib/openagents/repositories/importer.ex:542`). But `Provisioner.fail/1` overwrites the repository's own field with the constant `"provisioning_failed"` (`lib/openagents/repositories/provisioner.ex:224`), so the repository page's failure banner shows the generic code (`lib/openagents_web/live/code_repo_live.ex:204`) while the specific one is only visible on the import detail list (`:400`). And the outbox has **no attempt ceiling**: `claim_next/0` re-claims any `failed` row whose `retry_at` has passed (`lib/openagents/repositories/provisioner.ex:82`), the backoff saturates at 300 seconds (`:263`), and `ProvisioningOutbox` validates `attempt_count` without bounding it (`lib/openagents/repositories/provisioning_outbox.ex:49`). A repository that cannot be imported retries forever, and every retry repeats stages 1 through 5 in full.

A stale-workspace sweeper does exist. `OpenAgents.Repositories.ImportWorkspaceJanitor` runs every 15 minutes and removes up to 100 directories matching the import workspace pattern that are older than 2 hours (`lib/openagents/repositories/import_workspace_janitor.ex:8`, `:19`, `:32`). That covers crash-left workspaces; it does nothing for a retry loop that keeps recreating them inside the window.

### 1.5 Path D — the outbound GitHub mirror

After a successful push, `mirror_async/1` starts a supervised task that runs `git push --mirror <url>` from the bare repository (`lib/openagents/forge/pushes.ex:215`, `:240`). It is one-way, best effort, and never load-bearing for the forge; a failure only logs. `OpenAgents.Forge.MirrorWatch` compares the forge's `main` with the mirror's every five minutes, retries the push on any difference, and raises a degraded incident once per lag episode past 15 minutes (`lib/openagents/forge/mirror_watch.ex:26`, `:68`). Both only consider repositories in `Repos.allowed_repos()` with a configured URL (`lib/openagents/forge/mirror_watch.ex:54`, `lib/openagents/forge/pushes.ex:252`), and `:forge_mirror_urls` has no default, so this path is inert unless an operator configures it.

Two properties of this path deserve to be stated plainly, because "best effort" understates what it does.

- **`--mirror` is a force push of every ref.** It updates non-fast-forward and deletes remote refs that the local bare repository does not have. Whatever is on the mirror is replaced by the forge's state, unconditionally.
- **The drift test cannot tell "behind" from "ahead".** `drift?/1` compares the two `refs/heads/main` values for equality and classifies every inequality as `:behind` (`lib/openagents/forge/mirror_watch.ex:73`). A mirror carrying a commit the forge has never seen is therefore treated as lag, and `check_repo/3` responds by calling `Pushes.mirror_now/1` immediately (`lib/openagents/forge/mirror_watch.ex:82`).

This is the enforcement context for `INVARIANTS.md:1794` (REPOSITORY-002), added at the measured commit: development pushes go to the forge, never to the mirror, because the forge is the authority and GitHub is a projection of it. `ops/ci/push-remote-check.sh` and `.githooks/pre-push` refuse a push to any non-forge remote. Section 3.1 covers what happens when a push reaches GitHub anyway.

### 1.6 Paths E and F — working clones

These are checkouts, not storage. Both clone from the same node-local bare repository, and both diverge from each other on every dimension that matters.

| | Path E: coding job | Path F: SCV Codex run |
| --- | --- | --- |
| Entry point | `OpenAgents.Tools.Repository.ensure_workspace/1` (`lib/openagents/tools/repository.ex:51`) | `OpenAgents.SCV.Workspace.prepare/3` (`lib/openagents/scv/workspace.ex:20`) |
| Destination | `coding_jobs_dir()/job-<job-id>`, default `/var/lib/openagents/coding-jobs` (`lib/openagents/tools/repository.ex:30`) | `<temporary_root>/openagents-scv-workspaces/<execution-id>` (`lib/openagents/scv/workspace.ex:59`) |
| Filesystem | dedicated state disk | container `/tmp` on the boot disk |
| Durable-path validation | required when work or computers are enabled (`lib/openagents/runtime_config.ex:441`) | none; `:temporary_root` is hard-set to `System.tmp_dir!()` in every environment (`config/runtime.exs:213`, `config/config.exs:63`) |
| Clone flags | `git clone --quiet <bare> <dir>` — a local clone, so git hardlinks the object store | `git clone --no-local --no-checkout` then `checkout --detach <sha>` — `--no-local` deliberately disables hardlinking, forcing a full object copy (`lib/openagents/scv/workspace.ex:21`) |
| Which repositories | `openagents.com` only; the module hardcodes `@repo` (`lib/openagents/tools/repository.ex:22`) | any repository, by `storage_key` |
| Freshens the cache first | yes, `Sync.ensure_fresh(@repo)` (`lib/openagents/tools/repository.ex:57`) | no |
| Deleted when | job reaches a terminal status (`lib/openagents/work.ex:522`, `lib/openagents/work/coding.ex:94`) | the run's `after` block and `terminate/2` (`lib/openagents/scv/codex_run.ex:75`, `:82`) |
| Swept if that fails | yes — hourly, 24-hour retention, skipping active jobs (`lib/openagents/forge/janitor.ex:65`) | **no sweeper of any kind exists** |
| Reachable today | yes, from the repository tool family | no — `OpenAgents.SCV.CodexRuns.start/5` has no caller in `lib/` (`lib/openagents/scv/codex_runs.ex:13`) |

Neither clone has a depth limit, a size limit, a free-space check, or a timeout; `System.cmd/3` accepts none. The other SCV executors never clone at all — `Executor.OpenCode` and `Executor.CodexAppServer` receive an existing absolute directory and only validate it (`lib/openagents/scv/executor/open_code.ex:791`, `lib/openagents/scv/executor/codex_app_server.ex:766`). The one relevant Mix task, `Mix.Tasks.Openagents.Scv.Opencode`, defaults `--repo` to `File.cwd!()` and never fetches anything.

The SCV path reads the bare repository but never writes to it: `Workspace.destroy/1` refuses any path that is not a direct child of the workspace root (`lib/openagents/scv/workspace.ex:49`). The single cross-call from a working-clone path that writes into forge state is `Sync.ensure_fresh(@repo)` on the coding lane.

For completeness, two roots that look like repository storage and are not: the baked source tree returned by `source_dir/0` (`lib/openagents/tools/repository.ex:26`), which is the read-only image copy of the running code, and the beam artifact cache under `<forge data dir>/beams` (`lib/openagents/forge/boot_converge.ex:400`), which shares the state disk with the bare repositories and is swept on its own schedule.

### 1.7 Deletion

`Repositories.delete_owned_repository/4` takes the repository's push lock, deletes every WAL object under the repository's prefix, then asks each member of `[node() | Node.list()]` to remove its local bare repository, and only then deletes the row — a failure on any connected node rolls the whole transaction back (`lib/openagents/repositories.ex:304`, `:366`, `:388`). That is a careful design with one hole: a node that is disconnected at that moment is not in `Node.list()`, never receives the request, and keeps the bare repository indefinitely. Nothing reconciles orphaned caches when it rejoins, because nothing enumerates the cache directory at all.

### 1.8 Where the bytes land

| What | Path | Filesystem in the staging topology | Bounded by | Cleaned up by |
| --- | --- | --- | --- | --- |
| WAL index and entries | `forge/wal/<key>/` in GCS | object storage | nothing | repository deletion only |
| Bare repository cache | `/var/lib/openagents/forge/repos/<key>.git` | 100 GiB state disk | nothing | repository deletion only |
| Beam artifacts | `/var/lib/openagents/forge/beams/*.tar` | 100 GiB state disk | 24-hour retention | `Forge.Janitor` |
| Coding-job clone | `/var/lib/openagents/coding-jobs/job-<id>` | 100 GiB state disk | nothing | job terminal plus `Forge.Janitor` |
| Import workspace | `/tmp/openagents-import-<id>-<n>` | 20 GB boot disk | 20 GiB bundle cap, checked after the bundle is written | job `after` block plus `ImportWorkspaceJanitor` |
| WAL replay bundle | `/tmp/openagents-import-<n>.bundle` | 20 GB boot disk | nothing | `after` block in `unbundle_entry/4` |
| Git RPC stdin file | `/tmp/forge-rpc-<n>-<hash>` | 20 GB boot disk | 512 MiB | `after` block in `run_git_service/4` |
| SCV workspace | `/tmp/openagents-scv-workspaces/<id>` | 20 GB boot disk | nothing | run `after` block only; **nothing** after a crash |
| Docker images and container layers | Docker data root | 20 GB boot disk | nothing | `docker image prune` in the fleet startup script |

The staging topology is explicit about the disks. Three nodes, named individually and pinned by a Terraform test to exactly three (`infra/staging/main.tf:8`, `infra/staging/tests/safety.tftest.hcl:13`). Each gets a 20 GB `pd-balanced` boot disk running Container-Optimized OS (`infra/staging/main.tf:626`, `:655`) and a separate `pd-balanced` state disk defaulting to 100 GiB (`infra/staging/main.tf:631`, `infra/staging/variables.tf:85`). The startup script formats the state disk `ext4` if needed, mounts it at `/var/lib/openagents`, creates the subdirectories, and chowns them to `nobody` (`infra/staging/templates/fleet-startup.sh.tftpl:16`–`:33`). The application container is started with exactly one volume, `--volume "$state_root:$state_root"` (`infra/staging/templates/fleet-startup.sh.tftpl:203`). Nothing in the repository relocates Docker's data root, and the `Dockerfile` sets no `TMPDIR`, so container `/tmp` and every image layer live on the boot disk.

---

## 2. Same or different: the verdict

**One durable store, one transport, one importer. Keep them unified — they already are, and the unification is the strongest thing about this design.**

Treat the GitHub import as a *writer* to the WAL rather than a storage path of its own. That is exactly what it is: it produces one entry in the same log, in a different format (`"git_bundle"` instead of `"receive_pack"`), replayed by the same `Sync.apply_entry!/2` switch (`lib/openagents/forge/sync.ex:88`). Because it lands in the log rather than beside it, an imported repository is immediately clonable, browsable, pushable, deletable, and recoverable through the identical machinery, with no second code path to keep correct. Resist any proposal to give imports their own storage.

**The main repository is not special, and it should not become special.** `openagents.com` is a row in `repositories` like any other, with the historical string `openagents.com` grandfathered as its `storage_key` so existing WAL objects stay authoritative (`INVARIANTS.md:1774`). It differs in exactly three ways, all of them policy rather than storage:

- It is the only entry in `:forge_repos` (`config/config.exs:221`), which gates the legacy no-owner Git path (`lib/openagents/forge/git_http.ex:189`), the mirror watcher (`lib/openagents/forge/mirror_watch.ex:54`), and the deployment target check (`lib/openagents/forge/targets.ex:480`).
- It is the only repository the coding tools may edit, because `OpenAgents.Tools.Repository` hardcodes it (`lib/openagents/tools/repository.ex:22`).
- It is the only one likely to have a mirror URL configured.

None of that is a storage difference, and none of it should grow into one.

**There is no inbound repository synchronization at all.** The import is one-time by invariant (`INVARIANTS.md:1781`) and by product copy (`lib/openagents_web/live/repository_import_live.ex:87`). GitHub traffic after that is outbound only. So the owner's framing — "the main repo sync" versus "how the SCV stores repos" — describes two things that do not exist as separate mechanisms. Say so, and the question resolves.

**Working clones are a genuinely different concern and should stay separate from the store — but they should converge with each other.** A checkout is disposable, node-local, and has a natural owner and lifetime; a stored repository is durable, replicated, and outlives every process. Collapsing them would be a mistake. But there is no defensible reason for the two existing checkout mechanisms to disagree on all four of the decisions in the table in section 1.6, and where they disagree, the SCV made the worse choice each time: a non-durable root that the runtime configuration contract elsewhere forbids, `--no-local` so every run copies the whole object database instead of hardlinking it, no sweeper, and no free-space check. The right shape is one workspace module with one configurable durable root, one clone policy, one reaper, and one admission check, used by both lanes. That is a small refactor today because the SCV lane has no caller yet (`lib/openagents/scv/codex_runs.ex:13`); it will be a migration once it does.

**The mirror stays separate.** It is an export with no read path, and folding it into the store would only couple the WAL to a third party's availability. Separate does not mean unguarded: because it force-pushes and cannot detect a mirror that is ahead (section 3.1), the boundary needs a lease, not just a direction.

---

## 3. Failure modes, ranked

Ranked by likelihood times blast radius, each traced to code.

### 3.1 The mirror silently force-overwrites a mirror that is ahead of the forge (conditional, but the largest blast radius here)

This is the only failure mode in this document that destroys data rather than consuming a resource, and as of the measured commit the forge and GitHub have genuinely diverged: GitHub carries a commit that was pushed directly to it and that the forge's WAL never recorded.

The mechanism is three lines. `drift?/1` compares the forge's `refs/heads/main` with the mirror's and classifies *any* inequality as `:behind`, with no ordering test (`lib/openagents/forge/mirror_watch.ex:71`–`:73`). `check_repo/3` responds to `:behind` by calling `Pushes.mirror_now/1` at once (`lib/openagents/forge/mirror_watch.ex:82`). `mirror_now/1` runs `git push --mirror` (`lib/openagents/forge/pushes.ex:240`), which force-updates every ref and deletes any the forge lacks. The GitHub-only commit is overwritten. The recheck on the next line then returns `:current`, so the watcher publishes "current" to the status page and records no incident (`lib/openagents/forge/mirror_watch.ex:84`–`:86`). The same tick that destroys the commit also reports that everything is fine.

Blast radius, stated honestly: any commit that reached the mirror but not the forge is lost from every surface this system controls. It was never in the WAL, so no replay recovers it; it is not in any bare repository, so no node holds it; there is no receipt, no incident, and no log line naming it. It survives only in GitHub's own retention of unreachable objects, recoverable by SHA by someone who knows to look, which is not a property this system provides.

Two honest qualifications. First, the whole path is gated on `:forge_mirror_urls`, which has no default (`lib/openagents/forge/pushes.ex:252`) and is set in no configuration file in this repository, so whether it is armed in a given environment is not determinable here — see section 8. Second, the divergence itself is now guarded at the source: `INVARIANTS.md:1794` and `ops/ci/push-remote-check.sh` refuse a push to any non-forge remote, which is a fix for the cause. It is not a fix for the mechanism, which will still overwrite an ahead mirror the next time one exists for any other reason, including a manual mirror push, a GitHub-side revert, or a restore.

### 3.2 A failing import becomes a self-amplifying disk consumer (high, node-wide)

A failed import row is re-claimed forever with a backoff that saturates at 300 seconds (`lib/openagents/repositories/provisioner.ex:82`, `:263`), and there is no attempt ceiling anywhere in the outbox schema or the claim query (`lib/openagents/repositories/provisioning_outbox.ex:49`). Each retry runs a fresh depth-1 fetch and a fresh `git bundle create` into `/tmp` (`lib/openagents/repositories/importer.ex:198`, `:307`). When the failure cause *is* disk pressure, the retry loop is the thing that keeps the disk full. The 15-minute, 2-hour-retention workspace janitor cannot help inside that window (`lib/openagents/repositories/import_workspace_janitor.ex:8`). When the boot disk fills, Docker loses its data root: the application container, the Cloud SQL Auth Proxy, and the builder all lose the ability to write.

### 3.3 Import peak is roughly three times the snapshot, on the small disk (high, node-wide)

Section 1.4 traces the arithmetic: `source.git`, `snapshot.bundle`, and the replay download coexist under one temporary root that is not released until after the cluster warm (`lib/openagents/repositories/importer.ex:53`, `lib/openagents/forge/sync.ex:116`). That root defaults to `/tmp` because `:repository_import_temp_dir` is set in no configuration file, only in tests. Meanwhile `RuntimeConfig` refuses to boot if any *other* forge path is under `/tmp` (`lib/openagents/runtime_config.ex:634`, `:998`). The 20 GiB bundle ceiling (`lib/openagents/repositories/importer.ex:12`) is checked with `File.stat/1` **after** the bundle is fully written (`:311`), so it can only reject an import that has already consumed the disk it was meant to protect.

### 3.4 Clone and push are bounded by RAM, not by disk (medium likelihood, fleet-wide)

`upload-pack` output is collected whole by `System.cmd/3` and sent whole by `send_resp/3` (`lib/openagents/forge/git_http.ex:89`, `:386`), so a clone's memory cost equals the packfile size, with no cap and no concurrency limit. Push adds a 512 MiB heap ceiling with a roughly 2x flatten spike plus a full temp-file copy (`lib/openagents/forge/git_http.ex:30`, `:335`, `:373`), and then `Pushes.persist/4` hands the same binary to `WAL.put_entry/3` for the upload (`lib/openagents/forge/pushes.ex:112`). The gzip amplification path on anonymous `upload-pack` (`lib/openagents/forge/git_http.ex:354`) is already recorded as finding S1 in `docs/2026-08-21-full-codebase-audit.md`; an OOM there kills the whole node, not one request. No test pins any of these bounds.

### 3.5 A cold node pays full replay inside an HTTP request (medium, request-scoped becoming node-scoped)

`ensure_fresh` runs before every read (`lib/openagents/forge/git_http.ex:61`, `lib/openagents/forge/browse.ex:53`), and on a cold cache it replays the entire WAL from sequence zero (`lib/openagents/forge/sync.ex:71`). For a `receive_pack` entry the whole payload is pulled into memory before being written back out to a temp file (`lib/openagents/forge/wal.ex:118`, `lib/openagents/forge/git_http.ex:373`). There is no timeout on that work and no shedding; concurrent first-requests to the same cold repository each do the whole job independently, because nothing serializes replay the way `:global.trans` serializes pushes.

### 3.6 The durable copy succeeds while the repository reports failure (medium, confusing rather than destructive)

`materialize_cache` runs after the WAL append and is bounded by a 10-minute cluster-warm timeout (`lib/openagents/forge/sync.ex:15`, `lib/openagents/repositories/importer.ex:167`). If a node is slow or unreachable, the stage fails, `run_import/3` returns an error, and the repository is marked `failed` (`lib/openagents/repositories/provisioner.ex:220`) even though the durable data is safe. The retry is idempotent at the WAL — `append_import_once/6` finds the entry by `import_id` and returns `:ok` if the refs match (`lib/openagents/repositories/importer.ex:411`) — but only after repeating the full fetch and bundle, and `verify_snapshot/2` refuses with `:source_changed` if GitHub has moved in the meantime (`:266`). A transient warm timeout can therefore turn into a permanently unrecoverable import for a repository whose durable snapshot already exists.

### 3.7 SCV workspaces leak permanently on any abrupt stop (low today, high once the lane is wired)

The workspace is removed by an `after` block and `terminate/2` (`lib/openagents/scv/codex_run.ex:75`, `:82`). Neither runs on a `SIGKILL`, a VM reset, or a container eviction, and no reaper, TTL sweep, or boot-time orphan scan exists for `/tmp/openagents-scv-workspaces`. `ExecutionReaper` only updates database rows (`lib/openagents/scv/executions.ex:149`); it never touches disk and never stops the run. Because the clone uses `--no-local`, each leaked directory is a full independent copy of the repository's object database. This costs nothing today only because `CodexRuns.start/5` has no caller outside tests.

### 3.8 A repository deleted while a node is disconnected leaves that node holding the data (low, but it is a deletion-correctness problem)

`delete_local_caches/1` addresses `[node() | Node.list()]` (`lib/openagents/repositories.ex:388`). A partitioned node is not in that list, the row is deleted anyway, and nothing reconciles the orphan afterward. For a private repository this means content survives a user-visible delete.

### 3.9 The WAL index grows without bound and is rewritten on every push (low now, certain later)

The index carries every entry ever appended, each with a full ref map (`lib/openagents/forge/wal.ex:12`, `:196`), it is downloaded whole on every read (`lib/openagents/forge/wal/gcs.ex:37`), and it is uploaded whole on every CAS (`:46`). Push cost is therefore linear in total push count. The bucket has versioning on with no lifecycle rule (`infra/staging/main.tf:465`), so every rewrite is retained. Separately, `Forge.Janitor` reads the index of up to 1,000 ready repositories every hour, on every node (`lib/openagents/forge/janitor.ex:29`, `:54`, `:122`) — three thousand full index downloads per hour at that ceiling.

---

## 4. Where the hypothesis holds and where it does not

### 4.1 Confirmed

| Claim | Evidence |
| --- | --- |
| Imports run on the live application servers | `OpenAgents.Repositories.Provisioner` starts under the forge supervisor on every node (`lib/openagents/forge/supervisor.ex:20`, `lib/openagents/runtime_supervisor.ex:62`) and claims work with `FOR UPDATE SKIP LOCKED` (`lib/openagents/repositories/provisioner.ex:80`) |
| Object storage is the durable authority; local bare repositories are disposable caches | `lib/openagents/forge/wal.ex:4`, `lib/openagents/forge/repos.ex:3` |
| PostgreSQL stores metadata, lifecycle, and receipts, not Git objects | `lib/openagents/repositories/repository.ex:12`, `lib/openagents/forge/pushes.ex:138` |
| Bare repositories live at `<forge data dir>/repos/<storage-key>.git` | `lib/openagents/forge/repos.ex:38` |
| After an import, the system warms the repository onto every node | `lib/openagents/repositories/importer.ex:167` → `lib/openagents/forge/sync.ex:40` → `lib/openagents/cluster.ex:20`; three nodes are pinned in Terraform (`infra/staging/tests/safety.tftest.hcl:13`) and asserted for production (`ops/production/preflight.sh:131`) |
| Import temporary files, Docker data, and other application files compete for one partition | container `/tmp` and the Docker data root share the 20 GB boot disk (`infra/staging/main.tf:655`); only `/var/lib/openagents` is bind-mounted out (`infra/staging/templates/fleet-startup.sh.tftpl:203`) |
| Import bundles stream to object storage rather than loading fully into memory | `lib/openagents/repositories/importer.ex:604`, `lib/openagents/forge/wal/gcs.ex:264` |
| Pushes are acknowledged only after the WAL records them, with rollback on failure | `lib/openagents/forge/pushes.ex:57`, `:82` |
| Deletion removes both local cache data and durable WAL data | `lib/openagents/repositories.ex:366` |
| Stale import workspaces and agent working clones have cleanup processes | `lib/openagents/repositories/import_workspace_janitor.ex:19`, `lib/openagents/forge/janitor.ex:65` — but see 4.2 for the SCV exception |
| The 20 GiB import ceiling exists | `lib/openagents/repositories/importer.ex:12`; enforced at `:313` |
| Commit `41a8655` only improved error reporting | `git show --stat 41a8655` touches `git_failure.ex`, `importer.ex`, and one test; the classification is string matching on `git` output (`lib/openagents/repositories/git_failure.ex:14`) |
| The push path has a 512 MiB in-memory request limit | `lib/openagents/forge/git_http.ex:30`, `:335` |
| The index is one growing JSON document rewritten on every push | `lib/openagents/forge/wal.ex:196`, `lib/openagents/forge/wal/gcs.ex:46` |
| No Git LFS storage exists | the only LFS code is a one-time import warning built from the GitHub tree API (`lib/openagents/github.ex:125`) |
| No repository, object, ref-count, bandwidth, or concurrency quotas exist | section 5 |

### 4.2 Wrong, stale, or overstated

**"The host maps that directory from `/var/lib/sarah-forge`."** The string `/var/lib/sarah-forge` does not appear anywhere in this repository, and CI actively bans `/var/lib/sarah` paths in active source (`ops/ci/reference-check.sh:36`). The staging topology mounts a dedicated disk at `/var/lib/openagents` and bind-mounts it into the container at the same path (`infra/staging/templates/fleet-startup.sh.tftpl:16`, `:24`, `:203`). Whether a pre-existing production host still uses the older layout is not determinable here; see section 8.

**"GCS bucket `sarah-forge-wal` is the durable source of truth."** The bucket is name-templated per project as `<project>-openagents-forge-wal` (`infra/staging/main.tf:457`), asserted by the isolation validator (`ops/staging/validate-isolation.sh:108`) and exported at `infra/staging/outputs.tf:45`. The *role* described is right; the name is not the one this repository produces.

**"The production nodes each have only about 5.7 GB of root-disk space … leaving approximately 440 MB available."** Neither number appears anywhere in the repository, and no Terraform for production has ever existed in this repository's history — `infra/` contains only `infra/staging/`. The declared staging boot disk is 20 GB (`infra/staging/main.tf:659`). A single-digit free figure is consistent with a Container-Optimized OS boot disk after images, but the repository cannot confirm it. Section 8 gives the command.

**"Docker image pruning recovered 2.887 GB per node."** Plausible as an operational observation, but the only `docker image prune` in the repository is at `infra/staging/templates/fleet-startup.sh.tftpl:159`, added by commit `2e9b3f2` on 2026-08-21 — the same day as the incident — to a Terraform root that `docs/2026-08-21-hot-deploy-gap-audit.md:97` records as never applied to any cloud environment. Whatever ran in production did not run from this file. Note also that `docker image prune` reclaims unreferenced images only; it does not reclaim stopped-container writable layers, build cache, or volumes, and the container's `/tmp` is a writable layer.

**"The import needed temporary space for … (3) temporary files while uploading the bundle."** It does not. `WAL.put_entry_file/3` digests and uploads the existing bundle in 1 MiB chunks with no intermediate copy (`lib/openagents/forge/wal.ex:107`, `lib/openagents/forge/wal/gcs.ex:264`). The third copy that does exist is different and worse: the importing node's own WAL replay downloads the bundle again into the same temporary root before the workspace is released (`lib/openagents/forge/sync.ex:116`, `lib/openagents/repositories/importer.ex:53`).

**"A 1 GB imported repository might therefore require several gigabytes temporarily on the importer and approximately another gigabyte on every cache replica."** Directionally right, quantitatively misleading. The fetch is `--depth=1 --no-tags` (`lib/openagents/repositories/importer.ex:214`), so what is stored is a tip snapshot, not history. Size the problem from the snapshot, not from the GitHub repository. The multiplier on the importer is about 3x that snapshot, and about 1x on each other node, with a further transient 1x on each node's `/tmp` during unbundling.

**"Move Git caches, import workspaces, and agent workspaces off the root filesystem onto dedicated disks."** Git caches and coding-job workspaces are already on a dedicated disk (`infra/staging/templates/fleet-startup.sh.tftpl:25`–`:32`), and `RuntimeConfig` refuses to boot otherwise (`lib/openagents/runtime_config.ex:441`, `:634`). The work that remains is narrower and therefore cheaper: import workspaces, the Git RPC stdin file, the WAL replay download, and the SCV workspace root.

**"Keep Docker storage on a different filesystem from repository data."** Already true for the durable repository data. It is not true for the transient repository data, which is the half that actually failed.

**"Reduce the current 20 GiB import ceiling until workers actually have enough disk to support it."** Correct as a goal, but the ceiling as written cannot do that job at any value: it is checked with `File.stat/1` after `git bundle create` has already written the file (`lib/openagents/repositories/importer.ex:306`–`:318`). Lowering the number without adding a pre-flight check moves the failure point but not the disk consumption.

**"Report import stages … through LiveView and the CLI."** Stages are already logged with a structured `repository_import_stage` line (`lib/openagents/repositories/importer.ex:576`), payload bytes are already logged (`:610`), every transition already broadcasts on the repository topic (`:511`), and the repository page already subscribes and re-renders (`lib/openagents_web/live/code_repo_live.ex:41`). What is missing is narrower: the stage name and byte count never reach the assigns, and the repository-level error code is flattened to `"provisioning_failed"` by `Provisioner.fail/1` (`lib/openagents/repositories/provisioner.ex:224`), discarding the `insufficient_storage` code that commit `41a8655` produced.

**"Stream Git HTTP bodies end to end (the current push path still has a 512 MiB in-memory request limit)."** Right about the push, and it misses the larger half. The **response** path is also fully buffered and has no limit at all (`lib/openagents/forge/git_http.ex:89`, `:386`), so an anonymous clone's memory cost is the packfile size. That is the unbounded one.

**"Each repository lives on two or three shard replicas, not on every server."** With three nodes, "two or three replicas" and "every server" are the same thing. Sharding cannot pay for itself at this fleet size; see stage 9.

### 4.3 Cannot be settled from the repository

The live free space on any node, the actual production disk layout and mounts, the actual production bucket names and lifecycle rules, whether any prune has ever run in production, and whether the production hosts run the startup script in `infra/staging/` or something older. Section 8 lists the commands.

---

## 5. Bounds and quotas

### 5.1 What exists today

| Bound | Value | Where |
| --- | --- | --- |
| Repositories per namespace | 100 | `lib/openagents/repositories.ex:26`, enforced under a namespace row lock at `:1186` |
| Import bundle size | 20 GiB, checked after the bundle is written | `lib/openagents/repositories/importer.ex:12`, `:313` |
| Import wall clock | 6 hours | `lib/openagents/repositories/importer.ex:11` |
| WAL CAS retries per import | 3 | `lib/openagents/repositories/importer.ex:10` |
| Cluster warm timeout | 10 minutes | `lib/openagents/forge/sync.ex:15` |
| Git request body | 512 MiB compressed, in memory | `lib/openagents/forge/git_http.ex:30` |
| Browse output caps | 1 MB blob, 500 KB diff, 64 KB message, 400 list entries | `lib/openagents/forge/browse.ex:21`–`:24` |
| Import workspace retention | 2 hours, 100 directories per sweep, every 15 minutes | `lib/openagents/repositories/import_workspace_janitor.ex:8`–`:11` |
| Coding-clone and artifact retention | 24 hours, swept hourly | `lib/openagents/forge/janitor.ex:29` |
| Build output retention | 7 days | `config/config.exs:213` |
| Durable-path contract | `forge_data_dir`, `forge_build_dir`, `forge_build_queue_dir`, `forge_artifact_dir`, `forge_wal_dir`, `ra_data_dir`, `coding_jobs_dir` must be absolute and outside `/tmp` | `lib/openagents/runtime_config.ex:441`, `:634`, `:645`, `:683`, `:998` |

### 5.2 What does not exist

- No free-space check anywhere. No `df`, no `:disksup`, no reservation, no high or low watermark, in `lib/`, `ops/`, or `infra/`.
- No per-repository size limit, no stored size, and no size column on the `repositories` schema (`lib/openagents/repositories/repository.ex:12`).
- No account-level or organization-level storage quota. The only quota is a repository *count*.
- No cache budget and no eviction for `<forge data dir>/repos`, by explicit design (`lib/openagents/forge/janitor.ex:16`).
- No attempt ceiling on provisioning work (`lib/openagents/repositories/provisioning_outbox.ex:49`).
- No timeout on any `git` subprocess; `System.cmd/3` accepts none.
- No concurrency limit or rate limit on `upload-pack`, `receive-pack`, or the browse pages.
- No cap on `upload-pack` output size or on gzip-inflated request bodies.
- No object-count, ref-count, or bandwidth accounting of any kind.
- No WAL compaction, no snapshotting, no index paging, and no `git gc`, `repack`, or `prune` call in `lib/`.
- No guard against mirroring over a mirror that is ahead. `drift?/1` tests for equality, not for ancestry (`lib/openagents/forge/mirror_watch.ex:71`), and `mirror_now/1` passes no `--force-with-lease` equivalent (`lib/openagents/forge/pushes.ex:240`).
- No lifecycle rule on the WAL bucket; versioning is on and soft delete is 7 days (`infra/staging/main.tf:456`–`:473`).
- No durable-path validation for `:repository_import_temp_dir` or the SCV `:temporary_root`, and no test pinning the 512 MiB body limit, the 413 path, or the gzip path.

---

## 6. Roadmap

Stages are ordered so that each one is independently shippable and each reduces the largest remaining risk at the time you reach it. Sizes are rough: **small** is under a day, **medium** is a few days, **large** is more than a week.

### Stop the bleeding this week

#### Stage 1 — Make the mirror refuse to overwrite work it has not seen

**What.** Teach `drift?/1` the difference between behind and ahead. Fetch the mirror's `main` into the bare repository as a hidden ref and ask `git merge-base --is-ancestor` whether the mirror's commit is reachable from the forge's, instead of comparing two SHAs for equality (`lib/openagents/forge/mirror_watch.ex:68`–`:81`). Retry the push only for `:behind`. Add a third classification, `:ahead` or `:diverged`, that records a `forge_mirror_diverged` incident at the same severity as the existing lag incident and does **not** push. Give `mirror_now/1` a lease: pass the expected remote SHA so a race between the check and the push cannot clobber a commit that arrived in between (`lib/openagents/forge/pushes.ex:240`).

**Buys.** Removes the only mechanism in this system that can silently and irrecoverably destroy committed work. Turns a divergence from a data-loss event into a reported incident that an operator can resolve deliberately.

**Costs.** One extra `git fetch` per watch tick per mirrored repository, one new incident code, and a decision about what an operator does with a diverged mirror. The push-lease change must keep the credential out of logs and out of the URL, which the current code is careful about (`lib/openagents/forge/pushes.ex:229`).

**Unblocks.** Trusting the mirror enough to leave it enabled. REPOSITORY-002 guards the common cause of divergence; this guards every other one, including manual mirroring during a forge outage, which the invariant explicitly permits as a bounded override (`INVARIANTS.md:1808`).

**Size.** Small. **Seams.** `lib/openagents/forge/mirror_watch.ex:68`–`:110`, `lib/openagents/forge/pushes.ex:232`–`:249`, `lib/openagents/incidents.ex`, `test/openagents/forge/` mirror coverage.

#### Stage 2 — Put every transient repository write on the durable volume

**What.** Give `:repository_import_temp_dir` a real production value, add a scratch root for the Git RPC stdin file instead of the unconditional `System.tmp_dir!()` at `lib/openagents/forge/git_http.ex:375`, point the SCV `:temporary_root` at the same tree instead of `System.tmp_dir!()` (`config/runtime.exs:213`), and extend `validate_forge_paths/2` (`lib/openagents/runtime_config.ex:633`) so all three are covered by the same durable-path rule that already protects the other four. Add the directory to the startup script's `mkdir -p` list (`infra/staging/templates/fleet-startup.sh.tftpl:25`).

**Buys.** The `ENOSPC` class moves off the 20 GB boot disk and onto the 100 GiB volume that was provisioned for exactly this. Docker stops competing with Git for the same bytes. The runtime configuration contract stops having three exceptions that nobody wrote down.

**Costs.** One config key, one environment variable, four call-site changes, one validator clause, one line in a Terraform template. No behavior change, no migration.

**Unblocks.** Every later stage, because after this you can reason about one disk with one budget instead of two disks with an undocumented split.

**Size.** Small. **Seams.** `lib/openagents/repositories/importer.ex:657`, `lib/openagents/forge/sync.ex:117`, `lib/openagents/forge/git_http.ex:375`, `lib/openagents/scv/workspace.ex:59`, `lib/openagents/runtime_config.ex:633`, `config/runtime.exs`, `ops/staging/gate-5-profile.sh`, `infra/staging/templates/fleet-startup.sh.tftpl`.

#### Stage 3 — Stop the retry loop from amplifying the failure

**What.** Add an attempt ceiling to `ProvisioningOutbox` and a terminal `abandoned` state, so `claim_next/0` stops re-claiming a row that has failed N times (`lib/openagents/repositories/provisioner.ex:82`). Move `File.rm_rf(temporary_directory)` from the `after` block of `run_import/3` to immediately after the `append_wal` stage succeeds, so the workspace is gone before the cluster warm downloads the bundle again (`lib/openagents/repositories/importer.ex:53`, `:166`).

**Buys.** A failing import stops being the thing that keeps the disk full. Import peak drops from about 3x the snapshot to about 2x on the importing node. An operator gets a repository that says "give up and tell me" instead of one that thrashes silently.

**Costs.** One migration for the state and counter, one changeset clause, one query predicate, one moved line. The terminal state needs a user-visible story: the repository stays `failed` and a re-import is a new outbox row.

**Unblocks.** Honest capacity planning, because import cost stops being unbounded in time.

**Size.** Small. **Seams.** `lib/openagents/repositories/provisioning_outbox.ex`, `lib/openagents/repositories/provisioner.ex:72`–`:82`, `:213`, `lib/openagents/repositories/importer.ex:29`–`:54`, a migration, `lib/openagents_web/live/repository_index_live.ex`.

#### Stage 4 — Refuse an import before it writes a byte

**What.** Add a free-space check at the `prepare_workspace` stage: read available space on the scratch root, subtract a fixed reservation, and refuse with `:insufficient_storage` before `git init`. Use the GitHub API's reported size, which the import candidate flow already fetches, as the estimate, and multiply by the peak factor from stage 3. Make `:repository_import_max_bundle_bytes` a real environment variable with a default the disk can actually hold, and move the check from after `git bundle create` to a `--max-size`-style guard on the fetch where possible. Add a per-node limit of one in-flight import.

**Buys.** The failure becomes a refusal with a reason, at zero disk cost, before it can affect anything else on the node. The 20 GiB ceiling becomes meaningful instead of decorative.

**Costs.** A small platform-specific free-space helper, one configuration key, one admission clause, and a decision about what the reservation should be. The estimate from GitHub is approximate; the reservation absorbs the error.

**Unblocks.** Raising or lowering the ceiling as a deliberate operational choice rather than a guess.

**Size.** Small to medium. **Seams.** `lib/openagents/repositories/importer.ex:124`–`:130`, `:306`–`:331`, `:622`, `lib/openagents/github.ex`, `config/runtime.exs`, `lib/openagents/runtime_config.ex`.

#### Stage 5 — Tell the truth in the interface

**What.** Carry the import's specific `error_code` onto the repository row instead of overwriting it with the constant `"provisioning_failed"` (`lib/openagents/repositories/provisioner.ex:224`). Persist the current stage name and the transferred byte count on the `repository_imports` row, which the importer already computes and logs (`lib/openagents/repositories/importer.ex:576`, `:610`), and render them where the page already subscribes and re-renders (`lib/openagents_web/live/code_repo_live.ex:41`, `:190`).

**Buys.** An operator sees `insufficient_storage` instead of `provisioning_failed`, and a user watching a large import sees progress instead of a spinner. The plumbing is already there; only the last two hops are missing.

**Costs.** A migration for two columns, a few assigns, some markup.

**Unblocks.** Support without shell access, and honest incident timelines.

**Size.** Small. **Seams.** `lib/openagents/repositories/provisioner.ex:213`–`:253`, `lib/openagents/repositories/repository_import.ex`, `lib/openagents/repositories/importer.ex:546`–`:620`, `lib/openagents_web/live/code_repo_live.ex`, `lib/openagents_web/live/repository_index_live.ex`, a migration.

### Then the structural work

#### Stage 6 — Make one working-clone mechanism

**What.** Collapse `OpenAgents.SCV.Workspace` and the workspace half of `OpenAgents.Tools.Repository` into one module with one durable root, one clone policy, one free-space check, one reaper, and one destroy guard. Adopt the better half of each: the SCV's storage-key validation, revision pinning, and cleanliness verification (`lib/openagents/scv/workspace.ex:14`–`:35`); the coding lane's durable root, `Sync.ensure_fresh` before cloning, and janitor coverage (`lib/openagents/tools/repository.ex:30`, `:57`, `lib/openagents/forge/janitor.ex:65`). Drop `--no-local` so local clones hardlink again, and extend the janitor to sweep orphaned workspaces at boot as well as hourly.

**Buys.** SCV workspaces stop leaking permanently on a hard stop, stop costing a full object-database copy per run, and stop living on the wrong disk. One reaper instead of one reaper and a gap.

**Costs.** A refactor across two subsystems that currently share nothing. Do it now, while `CodexRuns.start/5` still has no caller in `lib/` (`lib/openagents/scv/codex_runs.ex:13`) and there is no live data to migrate.

**Unblocks.** Wiring the SCV lane to a real dispatcher without importing a disk leak, which is the join described in `docs/2026-08-21-sarah-computers-and-scv-architecture-audit.md`.

**Size.** Medium. **Seams.** `lib/openagents/scv/workspace.ex`, `lib/openagents/scv/codex_run.ex:36`–`:82`, `lib/openagents/tools/repository.ex:29`–`:78`, `lib/openagents/forge/janitor.ex:65`, `config/config.exs:63`, `config/runtime.exs:213`.

#### Stage 7 — Bound the Git HTTP memory path

**What.** Stream the request body straight to the scratch file instead of accumulating it in the heap (`lib/openagents/forge/git_http.ex:335`). Replace `System.cmd/3` in `run_git_service/4` with a `Port` and stream the subprocess's stdout through `send_chunked/2` (`lib/openagents/forge/git_http.ex:386`, `:89`). Replace `:zlib.gunzip/1` with incremental inflation under a hard decompressed-byte cap, closing finding S1. Add a concurrency limit on `upload-pack` and a timeout on every git subprocess. Add tests for all four, since none exist today.

**Buys.** Removes the only remote, unauthenticated, node-killing failure mode in the repository surface. Makes maximum servable repository size a function of disk and time rather than of node RAM. Stops `receive-pack` from holding a gigabyte of heap on a large push.

**Costs.** This is the one genuinely non-trivial piece of engineering in the list. The stdin-through-a-temp-file trick exists for exact EOF semantics (`lib/openagents/forge/git_http.ex:368`); a `Port` rewrite must preserve that, and it must keep the argv-only discipline that keeps request data out of shell strings.

**Unblocks.** Repositories larger than a fraction of node memory, and dropping the 512 MiB body ceiling to something chosen for disk rather than for heap.

**Size.** Medium. **Seams.** `lib/openagents/forge/git_http.ex:30`–`:130`, `:322`–`:400`, `lib/openagents/forge/pushes.ex:43`, `:112`, `lib/openagents/forge/sync.ex:162`, `test/openagents/forge/git_http_test.exs`.

#### Stage 8 — Give the cache a budget

**What.** Stop warming every node after an import; warm only the importing node, and let the existing lazy `ensure_fresh` on the read path hydrate the others on demand (`lib/openagents/repositories/importer.ex:167`, `lib/openagents/forge/git_http.ex:61`). Add a size index over `<forge data dir>/repos` and an eviction sweeper with a configurable budget, evicting least-recently-served first and pinning the repositories in `Repos.allowed_repos()` so the self-edit lane never loses its cache. Serialize concurrent replay of the same repository, the way pushes are serialized. Reconcile orphaned caches at boot against the repositories table, which also closes the disconnected-node deletion gap in 3.7.

**Buys.** Import cost drops from N node-copies to one. Disk usage stops being monotonically increasing, which is what makes a fixed disk size a defensible choice. A deleted private repository stops surviving on a node that happened to be away.

**Costs.** Removing the eager warm means the first read on a cold node pays full replay inline, so this stage wants stage 7's timeouts and, for repositories with long histories, stage 9's compaction. Eviction needs an access-time signal that does not exist yet.

**Unblocks.** Hosting more repository bytes than one node's disk holds, which is the first genuine scaling limit rather than an operational bruise.

**Size.** Medium. **Seams.** `lib/openagents/forge/sync.ex:39`–`:68`, `lib/openagents/forge/repos.ex`, `lib/openagents/forge/janitor.ex`, `lib/openagents/repositories.ex:388`, `lib/openagents/repositories/importer.ex:166`.

#### Stage 9 — Compact the WAL

**What.** Add a periodic compacted snapshot: pack the current state of a repository into one object, record it in the index, and retain incremental entries only after the latest snapshot. Page the index instead of rewriting one growing document per push (`lib/openagents/forge/wal.ex:196`, `lib/openagents/forge/wal/gcs.ex:46`). On a cache miss, download the latest snapshot and replay only the tail. Run `git repack` and integrity checks in the same background worker. Add a lifecycle rule to the WAL bucket so superseded entries and object versions actually expire (`infra/staging/main.tf:456`).

**Buys.** Cold-start cost becomes proportional to repository size rather than to push history. Push cost stops growing with push count. Object-storage spend stops growing without bound.

**Costs.** A new durable object format, new replay logic that must stay compatible with existing `receive_pack` and `git_bundle` entries, a backfill, and a careful argument that compaction can never lose a ref. This is the highest-risk change in the list because it touches the one thing the system currently gets unambiguously right.

**Unblocks.** Long-lived repositories with thousands of pushes.

**Size.** Large. **Seams.** `lib/openagents/forge/wal.ex`, `lib/openagents/forge/wal/gcs.ex`, `lib/openagents/forge/wal/local.ex`, `lib/openagents/forge/sync.ex:71`–`:132`, `lib/openagents/forge/pushes.ex:143`, `infra/staging/main.tf`.

### What is premature, and what would change that

Recommending shards for a system with three nodes and a handful of repositories would be worse than recommending nothing, so here is the honest version, with the trigger that would make each item earn its place.

- **Separate web, import-worker, and storage services.** Premature. The provisioner already runs as its own supervised process claiming durable work (`lib/openagents/repositories/provisioner.ex:17`); with stages 2 through 4 it stops being able to hurt its host. Split it out when import concurrency, not import safety, is the constraint — that is, when queued imports routinely wait behind each other.
- **Storage shards with two or three replicas per repository.** Premature at three nodes, where "two or three replicas" means "everywhere". Revisit when total repository bytes approach one node's disk budget after stage 8's eviction, or when the fleet exceeds roughly six nodes.
- **Routing Git operations to an owning shard.** Depends entirely on the previous item. Do not build the router first.
- **Git LFS object storage.** Premature; the import already refuses to help and warns instead (`lib/openagents/github.ex:125`). Build it when a real user's import is blocked by LFS content rather than by disk.
- **A CDN or regional cache in front of public clone traffic.** Premature. Anonymous clones are currently unmetered and unlimited (`lib/openagents/forge/git_http.ex:223`), so the first thing to build is measurement, not caching. Revisit when egress or `upload-pack` concurrency shows up in a real incident.
- **Account, object, ref-count, and bandwidth quotas.** The repository-count quota exists (`lib/openagents/repositories.ex:1186`). Add a byte quota when stage 8 gives you a size index to enforce it against; adding one before that means computing sizes on demand, which is worse than the problem.

---

## 7. What is worth preserving

An audit that lists only faults misrepresents the design. Four decisions here are better than they need to be for the current stage and should survive every stage above.

- **Refs live in exactly one place.** The WAL is authority, PostgreSQL receipts are derived from it and reconciled by sequence number (`lib/openagents/forge/pushes.ex:143`), and the bare repositories declare themselves cache (`lib/openagents/forge/repos.ex:3`). Almost every hard bug in a distributed Git host comes from having two ref authorities. This system has one.
- **The acknowledgement barrier is in the right place.** A push is not acknowledged until it is durable, and a WAL rejection rolls local refs back (`lib/openagents/forge/pushes.ex:57`, `:82`).
- **Reads degrade instead of failing.** An unreachable WAL logs and serves the local cache (`lib/openagents/forge/sync.ex:30`), and a damaged cache serves what it has rather than turning a node-local fault into a public outage (`lib/openagents/forge/browse.ex:49`).
- **Git invocations are argv-only.** No request-derived value ever enters a shell string, including in the one place `sh` is used for stdin redirection (`lib/openagents/forge/repos.ex:7`, `lib/openagents/forge/git_http.ex:381`).

---

## 8. Open questions

These could not be determined from the repository. Each is paired with the command that would settle it.

1. **Is the GitHub mirror armed in the running environment, and has it already overwritten anything?** `:forge_mirror_urls` has no default and appears in no configuration file here (`lib/openagents/forge/pushes.ex:253`), so section 3.1's failure mode is either live or inert depending on a value this repository does not carry. Settle by checking the deployed runtime configuration for that key, and by comparing GitHub's `main` with the forge's WAL head. If a commit reached GitHub and not the forge, recover it by SHA from GitHub before the next five-minute watch tick (`lib/openagents/forge/mirror_watch.ex:26`) rather than after.
2. **What are the production nodes' actual disks?** `infra/` contains only `infra/staging/`, and no production Terraform has ever existed in this repository's history. Production is described only by assertion in `ops/production/preflight.sh:105`, which expects three instances matching `^sarah-fleet-` in project `openagentsgemini`. Settle with `gcloud compute instances describe <node> --project=<project> --zone=<zone> --format='json(disks)'`.
3. **Do the production nodes have a state disk at all, and is `/var/lib/openagents` a real mount there?** The bind-mount and the dedicated disk are declared only in the unapplied staging template. Settle with `findmnt -T /var/lib/openagents` and `docker inspect <container> --format '{{json .Mounts}}'` on a node.
4. **Where does Docker actually store its data in production?** Nothing in the repository configures a data root. Settle with `docker info --format '{{.DockerRootDir}}'` and `df -hT`.
5. **Was the failing import's disk pressure on the boot disk or somewhere else?** The mechanism traced in section 3.3 predicts the boot disk. Settle by correlating the incident timestamp with `df` history, or by reproducing an import with the scratch root instrumented.
6. **What is the production WAL bucket named, and does it have a lifecycle rule?** The repository produces `<project>-openagents-forge-wal` with versioning on and no expiry. Settle with `gcloud storage buckets list --project=<project> --format=json`.
7. **Has any prune ever run on the production fleet, and from what script?** The only prune in the repository is in an unapplied staging template added the day of the incident. Settle by reading the live instance's `startup-script` metadata.
8. **How many repositories and how many total bytes exist today?** No size is recorded anywhere, so the answer is not derivable even from the database. Settle with `du -sh /var/lib/openagents/forge/repos/*` on a node and a `gcloud storage du` over the WAL prefix. Until stage 8 adds a size index, this stays a manual measurement.
9. **What should the import size ceiling be?** Stage 4 needs a number, and the number depends on answers 2, 3, and 8.
10. **Is the SCV Codex lane expected to be wired up soon?** Stage 6 is cheap now and expensive later, and the answer decides its priority.
