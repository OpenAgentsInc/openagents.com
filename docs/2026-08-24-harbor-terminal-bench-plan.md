# Harbor and Terminal-Bench: the Gym

Date: 2026-08-24

Status: plan. Companion to `docs/2026-08-24-benchmark-workbench-agentx.md`,
whose effectiveness axis (axis 2) this document re-bases on Harbor. Read
from the clone at `projects/repos/harbor` (v0.16.x, Apache-style OSS from
the Terminal-Bench creators).

## 0. The Gym framing

This is not only measurement. Harbor and Terminal-Bench are the **Gym**:
the training ground where the coder's capability work proves itself
against graded tasks, the way a model proves itself against an RL
environment. Concretely, three loops run through the same suites:

1. **Extend the coder.** A new capability lands with a Gym delta: the
   suite score before and after, on the same recipe. A capability that
   moves no score is questioned; a graded task class the coder cannot
   pass yet is a capability backlog item.
2. **Test multi-model swapping.** The same suite per compute-mix lane —
   each catalog model through the proxy, and Fable through the
   foreign-harness delegation lane beside the stock claude-code adapter —
   turns "which lane should this task class route to" into an
   evidence-backed policy instead of a vibe, and eventually feeds the
   routing policy itself.
3. **Test plugins.** The same suite with and without a plugin loaded;
   provenance-stamped `tool.ran` steps in the ATIF make the delta
   attributable to the exact plugin digest. A plugin's Gym delta is the
   registry's first honest quality signal.

RewardKit closes the far end of the loop: the same trials become RL
rollouts when optimization work begins — candidates, never
auto-promotions, per the standing law.

**The surface** shipped with this plan (`310dac1`): `gym_runs` records
graded runs idempotently by recipe digest, the bench harness posts them
through `POST /api/v3/gym/runs`, and `/gym` — a sidebar entry under
Projects — renders the scoreboard. Operator-only on every path for now:
the operator allowlist is the whitelist, deliberately, rather than a
second gating mechanism; widening it later is a decision, not a default.
The Gym project (project 14) tracks the lane.

## 1. What Harbor is

Harbor is the official harness for Terminal-Bench 2.0 and a general
framework for evaluating agents in container environments: a task is a
container image plus an instruction plus a verifier; an agent is installed
into the environment, runs against the instruction, and the verifier
grades the outcome. One command runs a whole benchmark:

```sh
harbor run --dataset terminal-bench@2.0 --agent claude-code \
  --model anthropic/claude-opus-4-1 --n-concurrent 4
```

What makes it the right effectiveness engine for the workbench rather
than anything hand-rolled:

- **The registry is 80 datasets**, not one: Terminal-Bench 2.0 first, and
  then SWE-bench (plus multilingual/pro/smith variants), Aider Polyglot,
  OSWorld, GAIA, CyberGym, tau3-bench, and 70 more, all runnable through
  the same contract (`registry.json`).
- **48 agent adapters already exist** — Claude Code, Codex, Gemini CLI,
  Goose, Grok Build, Cursor, Devin, Hermes among them — which means the
  competitive baseline table is free: the same task set, the same grader,
  our agent beside the field.
- **ATIF is its trajectory format.** The spec the coder already exports
  (`rfcs/0001-trajectory-format.md` lives in this repo); adapters write
  `trajectory.json` in ATIF after each trial, and `harbor-atif2otel`
  projects it to OpenTelemetry. Our `/export` speaks this natively,
  including the plugin-provenance system steps shipped as
  `OpenAgentsInc/openagents#32`.
- **Environments are pluggable** — local Docker plus ~30 providers
  (Daytona, Modal, E2B, GKE, EC2…) behind one interface with network
  policies (allowlist/no-network, probed rather than assumed) and
  resource policies. This is the same shape as the cloud-computer lane's
  owner-hosted/managed split, and a later OpenAgents environment provider
  is a natural (not urgent) extension.
- **RewardKit** turns the same trials into RL rollouts (judges, criteria,
  rewards) — the optimization loop waiting at the end of the measurement
  loop.

## 2. The adapter contract, precisely

`BaseInstalledAgent` (src/harbor/agents/installed/base.py) is what an
`openagents coder` adapter implements:

- `install(environment)` — in-container install; for us,
  `npm install -g @openagentsinc/cli` (a pinned version).
- A run command built from the instruction, with prompt-template support;
  for us, `openagents coder --plain` fed the instruction, on a lane that
  works headless in a container (an API-key/base-URL model connection via
  Harbor's `ModelConnectionSpec`, or the account lane where a token can
  be provisioned; the offline refusal must never look like a task
  failure).
- **Typed error patterns**: Harbor classifies agent failures
  (rate-limited, usage-exhausted, context-window, overloaded, safety
  refusal, auth) from output patterns so retry policy can target them —
  `--retry-include ApiRateLimitError`. The adapter must map the CLI's
  typed errors and exit codes onto these classes; our exit-code
  discipline makes that mechanical.
- `populate_context_post_run` — write `logs_dir/trajectory.json` in ATIF.
  The coder's existing exporter is the implementation; the adapter runs
  `/export` (or reads the export the session already wrote) and copies it
  out.
- **Capabilities**: declare `atif=True` on day one. `resume` maps to
  `--resume --last`; `load_atif_trajectory` (seeding a session from an
  ATIF file, which the Claude Code adapter implements bidirectionally) is
  exactly the foreign-session import direction of
  OpenAgentsInc/openagents.com#198 — declare it when that lands, not
  before.
- **No fork needed to start**: `harbor run --agent` accepts a custom
  import path (`create_agent_from_import_path`), so the adapter can live
  in our tree and run against upstream Harbor immediately. Upstreaming it
  to Harbor's 48-adapter roster is the distribution move — every Harbor
  user gains `-a openagents-coder` — and worth doing once the adapter is
  stable.

## 3. What we measure, and what stays ours

Harbor produces graded trials with ATIF trajectories. The workbench's own
layer on top stays exactly as specified: score floors in a thresholds
file (a run below floor fails the gate), digest-pinned recipes (CLI
version, model catalog revision, plugin set, dataset@version), receipted
results in `bench-results`, and **cost per accepted outcome** as the
headline — computable directly because every trial's ATIF carries token
metrics and the model catalog carries pricing.

The comparative matrix the compute mix wants falls out of Harbor's
design:

| Comparison | How |
| --- | --- |
| Our coder across house lanes | `-a openagents-coder` per catalog model through the proxy |
| Our coder vs the field | Same dataset, Harbor's stock adapters (claude-code, codex, goose…) |
| Fable via us vs Fable native | `-a openagents-coder` on the foreign-harness lane vs `-a claude-code` — measuring what our orchestration adds or costs |
| Plugin value | Same suite with and without a plugin loaded; provenance-stamped `tool.ran` steps in the ATIF make the delta attributable |

Start with `terminal-bench@2.0` because it is agent-agnostic terminal
work — closest to what the coder is for — then widen to SWE-bench and
Aider Polyglot from the same registry with zero new harness code.

## 4. Sequencing

1. **The adapter** (`OpenAgentsInc/openagents#35`): out-of-tree
   `BaseInstalledAgent` subclass, ATIF out, typed error mapping, pinned
   install. Acceptance: `harbor run -d terminal-bench@2.0 -a <import
   path>` completes trials locally on Docker with graded results and
   valid ATIF trajectories.
2. **The baseline** (folds into `OpenAgentsInc/openagents#34`): a scored
   Terminal-Bench 2.0 run per compute-mix lane beside the stock
   claude-code adapter, published to `bench-results` with thresholds set
   from the first honest numbers.
3. **Cadence**: per-release gate and weekly trend, as the workbench spec
   already states.
4. **Later, recorded not filed**: upstream the adapter to Harbor;
   `load_atif_trajectory` once #198's import half exists; an OpenAgents
   cloud-computer environment provider; RewardKit rollouts feeding the
   optimization loop (GEPA-style, candidates never auto-promoted).

## 5. Division of labor with AgentX

Unchanged from the workbench spec, now with the right engine in each
seat: **AgentX measures the serving side** (how the compute mix carries
coder-shaped traffic per dollar — axis 1), **Harbor measures the agent**
(does the coder finish graded tasks, at what cost — axis 2), and the
thread-to-WEKA exporter (axis 3, #218) feeds AgentX-style replay with our
own consented traffic. Harbor's ATIF trials are also raw material for
axis 3's cousin: consented trajectories are the corpus the registry
strategy wants, in the format we already speak.
