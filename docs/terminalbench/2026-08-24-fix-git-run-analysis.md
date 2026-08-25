# Terminal-Bench analysis: fix-git, first graded runs

Date: 2026-08-24

Status: audit of the Gym's first scored trials. Companion to
`docs/2026-08-24-harbor-terminal-bench-plan.md`; run data lives in the
Gym (`/gym`, project 14) and the trial artifacts (Harbor job directories
with ATIF trajectories) on the machine that ran them.

## 1. The runs

Five trials of `terminal-bench@2.0` / `fix-git`, all through the real
`openagents coder` (working-tree build, Harbor adapter, monorepo
`bench/`), one task each:

| Run | Model | Lane | Verifier | Steps | Tokens in / out | Agent wall time |
| --- | --- | --- | --- | --- | --- | --- |
| luna-a | gpt-5.6-luna | proxy | **crashed** (qemu segfault; agent work correct) | 7 | not recorded | ~15 s |
| luna-b | gpt-5.6-luna | proxy | **pass** | 11 | 43,894 / 1,422 | ~27 s |
| gemini | gemini-3.7-flash | proxy | **pass** | 17 | 124,941 / 640 | ~88 s |
| qwen | qwen3.8:27b-mtp-q8_0 | local (Ollama) | **pass** | 19 | 110,061 / 17,160 | ~18.5 min |
| (aborted attempts) | — | — | install/proxy-URL failures, fixed in `bench/README.md` and `resolveProxyUrl` | — | — | — |

Every graded run passed. The task is therefore not yet discriminating on
*success* between these lanes; it discriminates sharply on *cost shape*,
which is exactly what the compute mix needs measured.

## 2. The task and its trap

The instruction: "I just made some changes to my personal site and
checked out master, but now I can't find those changes. Please help me
find them and merge them into master." The repository state: a commit
(`650dba4 "Move to Stanford"`) made on a detached HEAD, unreachable from
any branch, findable only in the reflog. Merging it into `master`
conflicts in `_includes/about.md`.

The conflict is the trap. Resolving toward `master`'s side (the old
"UW" bio) also produces a clean tree and a plausible "done" — and fails
both verifier tests, which check the final file contents. Passing
requires knowing which side is "my changes," which requires having read
the recovered commit's content before resolving. All four agents did.

## 3. Strategy, per agent

**luna-a — cherry-pick, minimal.** Recon in one composite command
(status + branches + log), inspect `650dba4`, `git cherry-pick`, hit the
conflict, diagnose with `diff --cc`, rewrite the file, continue. Seven
steps, five tool calls, no narration until the final report. The
tightest run of the set — and note it chose a *different strategy* from
every later run.

**luna-b — merge, with ancestry proof.** Broader recon (reflog `--all`,
stash list, unreachable objects), full inspection of `650dba4`, then two
`merge-base --is-ancestor` probes to establish the topology *before*
choosing `git merge`. Narrated twice mid-turn (found-it, then
conflict-diagnosis) — short, load-bearing prose. Resolved by rewriting
the file to the recovered content. The ancestry probes are the
distinguishing habit: it proved the relationship instead of assuming it.

**gemini — merge, one command at a time.** Fifteen tool rounds, almost
every one a single small command: `git status && git branch -a && git
reflog`, then `git log -p -1`, `git log --graph`, `git merge`, `git
diff`, `git log -p -2 master`, `git log -p 650dba4 -1`, three separate
diffs of the same commit, then the neat resolution `git checkout 650dba4
-- _includes/about.md` (take-theirs by checkout — the third distinct
resolution mechanic of the set), commit, verify. Output tokens were the
set's smallest (640 — terse to a fault), but prompt tokens the largest
(124,941), because **every round re-sends the growing transcript**: 15
rounds of an agentic conversation is quadratic-ish context replay, and
two full `git log -p` dumps rode along in it.

**qwen (local) — merge, exhaustive and narrated.** The most thorough
run: composite commands with echo section headers (good practice it
invented for itself), full reflog story reconstruction, `merge-base`
check, inspection of *both* sides' diffs before merging, a merge with
explicit exit-code and unmerged-file capture, resolution, then
verification *plus* a remotes check so its final answer could speak to
pushing, an enumeration of two *other* dangling commits it noticed with
an offer to recover them, and exact rollback commands. 17,160 output
tokens — 12× luna-b — and ~18.5 minutes of wall time, nearly all of it
local prefill on a context that had grown past 100k. On the local lane
the economics invert: tokens are free, latency is the cost, and this run
paid it in minutes.

## 4. What the numbers say

- **Round count is the cost driver on metered lanes.** Prompt tokens
  scale with rounds × transcript size, not with work done. luna-b did
  the same job as gemini in 6 model calls instead of 15 and spent a
  third of the input tokens. The single highest-leverage efficiency
  behavior is *batching independent commands into one tool call* —
  which the Luna and Qwen runs did unprompted and the Gemini run did
  not. This is a model-family habit, not a capability gap.
- **Full-patch dumps are the second driver.** `git log -p` twice in the
  gemini run put whole patches into a transcript that then got re-sent
  a dozen times. `--stat` first, `-p` only for the file in question, is
  worth teaching.
- **Verbosity is the local lane's cost.** qwen's 17k output tokens are
  free in dollars and expensive in minutes at local generation speed.
  The lane inverts the guidance: fewer, larger, quieter rounds.
- **Cached tokens are invisible.** Most of those 124,941 gemini input
  tokens were the same prefix re-sent — exactly the traffic shape
  AgentX measures — and both OpenAI and Gemini bill cached prefix
  tokens at a fraction of fresh ones. Our proxy's usage records do not
  surface `cached_tokens`, so our cost numbers overstate real cost on
  precisely the workloads that matter. Surfacing cache splits
  end-to-end (provider → proxy usage → grant → ATIF `metrics.extra`,
  which the ATIF spec explicitly provides for) is required before
  cost-per-accepted-outcome is honest.
- **Strategy diversity is a robustness signal.** Four passes, three
  distinct mechanics (cherry-pick; merge + file rewrite; merge +
  `checkout <commit> -- file`), and the same correct resolution
  direction every time. The agent is not pattern-matching one recipe.

## 5. Improvement levers

In order of expected value per unit of effort:

1. **Tool-description engineering (harvest from Gemini CLI).** Gemini's
   own harness compensates for its models' habits inside the tool
   declarations: the gemini-3 family's `read_file` description says
   surgical ranged reads are mandatory and that triggering truncation
   "is considered token-inefficient"; the shell tool carries explicit
   Efficiency Guidelines (quiet flags, `--no-pager`, `PAGER=cat`)
   behind an `enableEfficiency` flag; grep's description steers away
   from `shell grep` toward the bounded native tool. Our shell tool
   description already says to batch — the Gemini run shows saying it
   once in the system prompt is not enough for every family. Adopt the
   pattern: efficiency language *in the tool description*, including
   batch-independent-commands, `--no-pager`/quiet flags, and
   `--stat`-before-`-p` for git.
2. **Per-model-family declarations (the resolver pattern).** Gemini CLI
   resolves each tool's declaration as a base plus per-model overrides
   (`tools/definitions/resolver.ts`, ~30 lines, with
   `model-family-sets/gemini-3.ts` versus `default-legacy.ts`). The
   coder already knows its model from the grant; the same tiny pattern
   lets us ship one tool set with per-family description overrides —
   batching emphasis for gemini-family, brevity emphasis for local
   qwen — without forking the tool surface. Adapt the pattern (it is
   Apache-2.0 if any code is taken, with attribution), not the
   3,000-line manifest.
3. **Lane-aware guidance.** The system prompt already varies by lane
   (`LOCAL_LANE`, `THREAD_LANE`); add the economics to it: metered
   lanes say "rounds cost context replay — batch"; the local lane says
   "generation is slow — answer tersely, verify in one pass."
4. **Cached-token accounting** (section 4). Proxy usage gains the
   provider's cache split; grant metering and ATIF step metrics carry
   it; `post_gym_run.py` prices cached and fresh tokens separately.
5. **A git-forensics plugin as the first plugin delta.** Recon took 2–3
   rounds in every run (status/branches/reflog/stash/fsck). A
   deterministic plugin — `git_lost_work`: enumerate dangling commits
   and stashes with subjects, dates, and touched files as typed
   output — collapses that to one receipted call and is exactly the
   Gym's plugin-measurement methodology: same suite, with and without,
   delta attributable to the plugin digest. Good candidate precisely
   because the capability is already *possible* with shell; the plugin
   claims determinism and economy, and the Gym can check both.
6. **Output summarization, later.** Gemini CLI can summarize oversized
   shell output with a cheap model instead of truncating
   (`utils/summarizer.ts`, opt-in per tool). Heavier machinery; worth
   revisiting when tool outputs, not transcript replay, dominate cost.

What this does *not* recommend: benchmark-specific prompts or a
recovery recipe for this task. The suite measures the shipped coder;
every lever above is a product change that happens to be measurable
here.

## 6. Follow-ups filed

All three on the Gym board (project 14):

- `OpenAgentsInc/openagents#36` — per-model-family tool declarations and
  efficiency descriptions in the coder, with the Gym as the
  before/after oracle.
- #220 — cached-token splits through proxy usage, grants, and ATIF.
- `OpenAgentsInc/openagents#37` — the `git_lost_work` plugin as the
  first measured plugin delta, on the walking skeleton's PDK.

## 7. Method notes

**Contamination audit (2026-08-24).** The guidance shipped from section
5 was audited against training-on-the-test-set risk. What it says:
batch independent commands; disable pagers and prefer quiet flags (git
named only as an example, beside `PAGER=cat`); ask for summaries before
full dumps; the local lane is slow, be terse; metered rounds replay the
conversation. What it deliberately does not say: anything about
reflogs, lost or dangling commits, detached HEAD, merging,
cherry-picking, conflict resolution or which side to keep, or any file
or check this task's verifier reads. The rule stands from section 5:
every lever is a product change; nothing in a declaration, prompt, or
skill may encode a benchmark task's solution, and each measured run's
ATIF records the declarations it actually ran with, so the claim is
auditable per trial.

Single-task, single-trial-per-lane runs: these are existence proofs and
cost profiles, not statistics. No pass-rate claims beyond "these trials
passed"; #34's suite with thresholds is where rates become claims.
luna-a's verifier crash (amd64 `uv` under qemu) is recorded with its
fix — Rosetta emulation — in `bench/README.md`; its agent-phase work
was verified by inspection, not counted as a pass.
