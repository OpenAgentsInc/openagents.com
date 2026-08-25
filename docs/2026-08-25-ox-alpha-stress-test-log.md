# Ox Alpha Stress Test & High-Throughput Token Benchmark Log

Date: 2026-08-25
Status: In Progress
Author: OpenAgents Coder & Christopher David

## 1. Objectives & Context

As discussed in Episode 275 ("Parallelizing Ox Alpha Stress Testing"), the objective is to determine the maximum sustainable tokens per second (TPS) and parallel capacity of `stealth/ox-alpha` across available providers (OpenRouter, OpenCode Zen, Nous Portal, Venice) without degrading into rate limit errors (`429`), quota exhaustion, or merge conflicts.

Initial findings are collected and logged here before running live backlog burns on video.

---

## 2. Benchmark & Concurrency Ladder Run Receipts

### Baseline Probe (Concurrency = 2)
- **Model / Lane:** `ox-alpha` (via OpenAgents inference proxy -> OpenRouter `stealth/ox-alpha`)
- **Task:** 300-word architectural analysis of swarm scaling & token economics
- **Result:**
  - 2 of 2 workers completed cleanly.
  - Per-worker generation latency: ~18-22s.
  - Estimated output generation: ~800 tokens/worker (including hidden reasoning).
  - Effective aggregate generation rate: ~75–90 tokens/sec across 2 lanes.
  - HTTP status: 200 OK (no 429s).

### Concurrency Ladder Step 1 (Concurrency = 4)
- **Model / Lane:** `ox-alpha`
- **Task:** 250-word scaling analysis on generation ceilings, prompt caching, and throughput bottlenecks
- **Result:**
  - 4 of 4 workers completed concurrently without dropouts.
  - System load: 4.47 (16 idle CPU threads available, memory clean).
  - Effective aggregate generation rate: ~160–190 tokens/sec across 4 lanes.
  - Error rate: 0.0% (0 / 4 failed).

---

## 3. Key Lessons Learned & Bottleneck Hierarchy

1. **Output Generation vs. TPM/Context Prefill:**
   - Single-agent output decode rate sits comfortably around 20–30 TPS.
   - The primary bottleneck in agentic loops is **input token volume and TPM ceilings**, not output decode speed. A 50k-token repository context re-sent across 4 agents consumes 200k input tokens per step, rapidly hitting Free-tier TPM ceilings (e.g., Nous Free tier observed at 500k TPM = max 2–3 active heavy workers).

2. **Prompt Caching is Mandatory for Fan-Out:**
   - 80–90% of prefix data (system prompts, tool definitions, file headers) is static across sibling workers.
   - Seeding workers with shared context prefixes ensures cache hits, minimizing time-to-first-token (TTFT) and saving API quota.

3. **Rate Limits & Provider Topologies:**
   - **OpenRouter:** Free model pool has a documented 20 RPM limit, plus daily request quotas (50/day before $10 lifetime credit; 1,000/day after).
   - **Nous Portal:** Observed 50 RPM / 500K TPM on Free plan; paid tiers scale up to 1,600 RPM / 16M TPM.
   - **OpenCode Zen (`x-preview-f-free`):** Free Ox Alpha endpoint can be subject to upstream availability (`503` under load).

4. **Next Step for Cloud Computers / Box Infrastructure:**
   - To scale past 8 concurrent agents safely on complex repositories, tasks must be isolated to separate git worktrees or cloud sandbox containers (Box / Cloud Computer leases) to avoid workspace lock contention and serial merge bottlenecks.

---

## 4. Next Ladder Steps Planned

- [x] Concurrency 2: Verified (~80 TPS)
- [x] Concurrency 4: Verified (~180 TPS)
- [ ] Concurrency 8: Test short burst synthesis across 8 workers
- [ ] Concurrency 15: Maximum planned fan-out test with Box/worktree isolation

## 5. Box / Cloud Computer Fleet Integration Plan

### Architecture & Current Substrate
The backend in `openagents.com` already holds the complete Box runtime and delegation primitives:
1. **Core Client & Fleet (`OpenAgents.Box`, `OpenAgents.Box.Fleet`, `OpenAgents.Box.Fanout`):**
   - Implements bounded multi-box allocation with labels, queues, and cost ceilings (Issue #109).
   - Manages active box caps per conversation (default 2, budgeted grant up to 10/15).
2. **Durable Runs (`OpenAgents.BoxRuns`):**
   - Asynchronously runs OpenCode / Coder commands on remote sandboxes (Issue #107) with resumption and bounded output tailing.
3. **Forge Issue Assignment (`OpenAgents.Forge.Assignments`):**
   - Delivers short-lived, branch-scoped credentials to a box container (Issue #108) so a remote OpenCode harness can clone, implement, run checks, and push a branch.
4. **Unified Delegation Layer (`OpenAgents.Delegations`):**
   - Provides a single seam across local harnesses and remote Box targets (`target_type: "box"`).

### Next Steps for Fan-Out Execution
1. **Bridge Coder Session with Box Fleet Fan-out:**
   - File a dedicated issue in Project 6 to wire `openagents coder` delegation directly to the remote Box fan-out controller (`POST /api/v1/conversations/:id/boxes/fanout` and `POST /api/v1/delegations/dispatch`).
2. **Execute Multi-Box Ox Alpha Run:**
   - Request 4-8 cloud boxes in parallel, dispatching OpenCode with `stealth/ox-alpha` against distinct backlog issues.
   - Collect and compare end-to-end cloud latency, TPS, and receipt delivery against local runs.

### Concurrency Ladder Step 2 (Concurrency = 8)
- **Model / Lane:** `ox-alpha` (8 parallel child coding agents)
- **Task:** Prompt caching optimization and TTFT reduction analysis under multi-tenant load
- **Result:**
  - 8 of 8 children completed concurrently with zero dropouts.
  - Per-child generation: ~750–1,200 tokens (output + reasoning).
  - Effective aggregate generation rate: **~350–410 tokens/sec** across 8 parallel streams.
  - Machine state: Load average 4.75, memory healthy, zero HTTP 429s or rate limit errors.
  - Error rate: 0.0% (0 / 8 failed).
