# Benchmark workbench: AgentX first

Date: 2026-08-24

Status: specification

A repeatable workbench for measuring the OpenAgents agent as it evolves,
starting with AgentX — SemiAnalysis's open source (Apache 2.0) multi-turn
agentic coding inference benchmark from InferenceXv3
(`github.com/SemiAnalysisAI/InferenceX`, cloned read-only at
`projects/repos/InferenceX`; announcement article 2026-08-23). Tracked as
[project 14, Benchmark workbench](https://openagents.com/OpenAgentsInc/openagents.com/projects/14):
the serving replay is `OpenAgentsInc/openagents#33`, the effectiveness
suite `OpenAgentsInc/openagents#34`, and the trace exporter #218.

## 1. What AgentX is, and what it is not

AgentX replays anonymized real coding-agent traffic — 393 sessions drawn
from an 8,000-session, $3M proxy corpus of Claude Code and Codex use —
against an OpenAI-compatible server, preserving the four properties that
make agentic traffic unlike chatbot traffic: multi-turn accumulation, long
context (to 1M), very high prefix reuse (KV-cache hit rates above 95
percent), and sub-agent bursts with fresh context. The replay harness is
AIPerf (`inferencex-agentx-mvp` trace replay); traces are stored in the
WEKA trace format, with content tokenized into 64-token blocks and each
block replaced by a session-scoped chained hash, so matching prompt
prefixes produce matching hash prefixes without revealing content. Headline
metrics are performance per dollar versus interactivity (TPOT), TTFT, and
throughput under realistic load.

Two things AgentX is not:

- **It is not a task-success benchmark.** It measures how well a serving
  stack carries coder-shaped traffic, not whether the agent solved the
  task. Measuring "effectiveness of our agent" needs a second, graded
  axis (section 4).
- **It is not point-in-time.** InferenceX's founding argument is that
  fixed-date benchmarks go stale in days because inference software moves
  daily. The workbench inherits that: continuous runs, not a one-off
  report.

The methodology discipline in the InferenceX repo is as valuable as the
dataset, and the workbench adopts it wholesale
(`docs/eval-agentx-procedures.md` in that repo):

1. Validate scores, not file existence; every published point has a floor
   in a `thresholds.yaml` and a row whose score is never null.
2. Evidence uploads before gates evaluate (`always()` before score
   validation), so failed evidence survives.
3. Fast/smoke modes are bring-up evidence, never publishable claims, and
   are marked ineligible for reuse.
4. Configs track what real customers run, not benchmaxed images.
5. Every point carries CI provenance: the exact command, logs, and
   server-metrics exports staged as artifacts.

These are the house rules restated — receipts, falsifiable greens,
evidence over narration — which is why this benchmark is the right first
tenant for the workbench.

## 2. Why this matters to the coder push

The compute mix (`docs/2026-08-24-coder-first-cloud-complements.md`
section 5) makes OpenAgents a buyer and, later, a seller of agentic
inference. AgentX is the measurement instrument for both sides:

- **Lane 1 (house providers).** Which provider serves coder-shaped
  traffic best per dollar, and how much the inference proxy costs on top.
  The proxy currently buffers the whole SSE body, so TTFT through it is
  degraded by design — the bench will put a number on that known caveat
  and motivate the chunked-streaming work honestly.
- **Lane 2 (metered offering).** Pricing a metered offering without
  measured cost per million tokens under realistic load is guesswork.
- **Lane 3 and beyond (user compute, provider mode, owned serving).** If
  Psionic-class serving or provider-mode supply ever carries coder
  traffic, AgentX is the qualification gate — the same claim/validate
  discipline the Pylon era already established.
- **The trace flywheel.** AgentX's corpus came from a proxy in front of
  Claude Code. OpenAgents already owns the equivalent, better positioned:
  thread transcripts on the forge, consent-tiered (#205), exportable, and
  ATIF-projected. Our own traffic can become an OpenAgents trace corpus in
  the same WEKA format with the same chained-hash anonymization —
  replayable by us and, under the opt-in licensing posture, publishable.

## 3. Workbench axis 1: serving (AgentX proper)

**Goal:** a repeatable run that answers "how do the lanes of our compute
mix perform under coder-shaped load, per dollar," on demand and on a
schedule.

Shape:

- A `bench/` lane in the `openagents` monorepo: pinned AIPerf and dataset
  versions, run recipes as data, one entry point per target class.
- Targets, in order of usefulness: (a) each model catalog entry through
  `POST /api/inference/proxy` (what the coder actually experiences), (b)
  the same upstream models direct (isolating proxy overhead), (c) any
  future owned serving endpoint.
- Metrics per point: TTFT, TPOT, tokens per second at fixed concurrency
  ladders, and cost per million tokens derived from the provider's
  pricing and the grant's metered usage — the same usage records the
  leaderboard consumes, so bench numbers and billing numbers cannot
  diverge silently.
- Every run is receipted: the exact command, config digest, dataset
  digest, and results land as artifacts in a `bench-results` forge
  repository, and the run itself is a thread so the transcript is the
  provenance.
- Constraint to respect: hosted-provider terms and rate limits. AgentX at
  full concurrency is a load test; against third-party APIs the recipes
  run at bounded concurrency with provider consent where terms require
  it. Full-ladder runs are for endpoints we own.

## 4. Workbench axis 2: effectiveness (graded agent runs on Harbor)

**Goal:** a number that moves when `openagents coder` gets better or
worse, computed the same way every time.

This axis runs on **Harbor**, the Terminal-Bench 2.0 harness from the
Terminal-Bench team (`projects/repos/harbor`) — the full plan is
`docs/2026-08-24-harbor-terminal-bench-plan.md`. Harbor is the right
engine rather than a hand-rolled runner because it already is the graded
agent-effectiveness harness: an 80-dataset registry (Terminal-Bench 2.0,
SWE-bench, Aider Polyglot, and more behind one contract), 48 existing
agent adapters that make the competitive baseline free, pluggable
container environments, and — decisively — **ATIF as its native
trajectory format**, the same v1.7 the coder already exports.

Shape:

- An `openagents-coder` installed-agent adapter (out-of-tree first;
  Harbor takes a custom import path, no fork needed), writing the
  coder's own ATIF export as each trial's trajectory.
- First dataset `terminal-bench@2.0` — agent-agnostic terminal work,
  closest to what the coder is for — then SWE-bench and Aider Polyglot
  from the same registry with zero new harness code, plus an owned set
  drawn from this tracker's own closed issues later.
- Each run pins: CLI version, model catalog revision, plugin set, task
  digest. Scores validate against floors in a `thresholds.yaml`; a run
  below floor fails the gate rather than shipping a quiet regression.
- Headline metric: **cost per accepted outcome** (the episode 237/243
  vocabulary, already the house's stated favorite), alongside task
  success rate, wall-clock, tokens, and tool-call counts — all derivable
  from thread transcripts and ATIF exports the coder already produces.
- The compute mix makes this comparative for free: the same suite runs
  per lane — house models through the proxy, and foreign-harness
  delegation (Fable through Claude Code) once monorepo #25's lane exists
  — so "which lane should this task class route to" gets an evidence-
  backed answer instead of a vibe.
- Cadence: per-release for the gate, weekly for the trend line. Results
  append-only in `bench-results`; a later status-page panel reads them.

## 5. Workbench axis 3: the OpenAgents trace corpus

**Goal:** replay our own traffic shape, not only SemiAnalysis's.

- An exporter from `thread_events` to the WEKA trace format with the
  64-token chained-hash anonymization, preserving timing, sub-agent
  structure (once the nested-thread ledger exists), and prefix-reuse
  patterns while revealing no content — the same privacy construction
  AgentX uses.
- Strictly consent-gated: only threads whose tier permits it (#205,
  THREAD-002), aggregated under the opt-in licensing posture. This is the
  trace-licensing lane from the registry strategy given its first
  concrete consumer.
- Payoff: lane comparisons run against traffic that looks like OpenAgents
  users, and — if published — the corpus is a contribution back to the
  AgentX ecosystem under our own consent rules.

## 6. Non-goals

- No 2MW GPU fleet, no hardware SKU comparisons — that is InferenceX's
  job; we consume their published data for hardware questions.
- No benchmark-specific agent builds: the suite runs the shipped CLI, per
  the "measure what customers experience" rule.
- No published score without a threshold, a digest-pinned config, and
  staged evidence. A fast run is never a claim.

## 7. First issues

1. **Stand up the AgentX serving replay against the compute mix**
   (monorepo): the `bench/` lane, pinned AIPerf plus dataset, recipes for
   proxy-vs-direct per catalog model at bounded concurrency, receipted
   results into `bench-results`. Acceptance: one honest comparison table
   for two models with proxy overhead quantified.
2. **Harbor adapter for the coder** (`OpenAgentsInc/openagents#35`): the
   `BaseInstalledAgent` subclass with ATIF out and typed error mapping.
   **Effectiveness suite v1** (`OpenAgentsInc/openagents#34`, blocked by
   the adapter): Terminal-Bench 2.0 per compute-mix lane beside the stock
   adapters, with thresholds and cost-per-accepted-outcome reporting.
   Acceptance: two consecutive scheduled runs producing comparable rows,
   and one deliberate regression caught by the floor.
3. **Thread-to-WEKA trace exporter** (openagents.com): consent-gated
   export of thread transcripts in the WEKA trace format with chained-hash
   anonymization. Acceptance: an exported OpenAgents corpus replays under
   the axis-1 harness.

Later, recorded here rather than filed: a status-page trend panel over
`bench-results`; per-lane routing recommendations feeding the capability
selector; corpus publication under the licensing posture; qualification
recipes for provider-mode supply.
