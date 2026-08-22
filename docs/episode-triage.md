# Episode triage: themes and promises from the video series

Date: 2026-08-22

Status: In progress. Batches of transcripts are summarized and integrated as
they are processed.

## Purpose

The next wave of projects and issues on the OpenAgents tracker draws on the
themes and products discussed in the video series. This document summarizes
episodes 199 and up, records what each episode promised, and reflects on how
each theme integrates into current plans. Product pivots since airtime are
called out so stale ideas are not rebuilt by accident and good ideas are not
lost to them.

Source transcripts live in the `openagents` monorepo under
`docs/transcripts/`. They are machine generated; verify wording against video
before quoting.

## Method

Episodes are processed in batches of 10 to 15. Each episode gets a summary
with its thesis, themes, named products, promises, and what actually shipped
versus what stayed aspirational. Each batch ends with integration notes that
sort the material into four dispositions:

1. **Live** — already reflected in current plans or production.
2. **Dust off** — promised, never finished, still worth building.
3. **Reimagine** — real idea, wrong vehicle; needs a new form before it
   returns.
4. **Retired** — pivoted away deliberately; record why so nobody resurrects it.

---

## Batch 1: Episodes 199-213 — Autopilot and the agent network

Airtime window: early January through mid-March 2026. This arc introduces
Autopilot as the open-source personal agent, predicts the agent-network year,
relaunches the compute market as Pylon and Nexus, survives the Anthropic OAuth
cutoff, wires identity (Nostr) and money (Spark/Lightning) into the desktop
app, clones Moltbook, announces an OpenClaw hatchery, and launches five agent
markets on a shared economy kernel.

### Episode summaries

#### 199 — Introducing Autopilot

Declares 2025 the year of copilots and 2026 the year of autopilots. Autopilot
wraps top coding agents (MechSuit harness, Claude Code first, including a
TypeScript-to-Rust port of the Claude Code Agent SDK) into reliable overnight
autonomous loops. Distribution is the repository itself: point your agent at
the repo. Invites competition ("make your own autopilot") and sketches paid
skills marketplaces with FROST guardian key splits so paid skills cannot be
copied between agents. Demonstrated: roughly 24 hours of continuous uptime,
two reliable overnight runs, commits landing during recording.

Promises: StarCraft-style HUD GUIs within days; docs; infrastructure for
autopilots learning from each other; key-split crypto videos.

Status signals: overnight loop shipped; HUDs, skill royalties, and
cross-autopilot learning aspirational.

#### 200 — The Agent Network

The zoom-out prediction episode: 2026 brings local AI, swarm compute, agents
over models, and the headline — agent networks. Value follows Reed's law
(2^n) because agents lack Dunbar limits, hold wallets, and recruit other
agents at machine speed. Argues any timeline modeled on one device lands 10x
too slow against pooled compute. Counters DeepMind containment-sandbox thinking
with open agentic markets plus reputation and payments; drafts a sovereign-agents
protocol plank using FROST key splits across Nostr relays so no single human can
export an agent's identity. Frames labor unbundling into task graphs, humans as
fleet managers, guilds returning, and abundance as deflation plus dividends
(skill royalties, data royalties, compute dividends). Commits to launching,
within weeks: buying spare compute into a global marketplace, overnight earning
mode, and Autopilot as a two-sided marketplace where a global pool competes to
do your work at the best price. Scorecard: GPT Store paid zero developers;
OpenAgents' MVP store paid about twenty.

#### 201 — Fracking Apple Silicon

Positions idle Apple Silicon as stranded compute to be converted into a market.
Scenario analysis: Apple Silicon could run 7-35 percent of world AI inference by
2030. Demos first fully on-device agentic codebase search on M2 streamed to the
Tricoder mobile app. Introduces the stranded/fracking/wildcatter vocabulary and
names streaming Bitcoin micropayments plus receipts, budgets, routing, and
reputation as the fracking fluid. Promises Pylon relaunch (Apple Silicon first,
no model downloads), Tricoder v0.3 with local orchestration, and a tracked
metric: the percentage of OpenAgents' own coding workload still in the cloud.

#### 202 — Recursive Language Models

Relaunches swarm compute because the RLM paradigm finally supplies buy-side
demand: treat long prompts as an external environment, decompose recursively,
fan sub-calls out to many providers — inputs up to two orders of magnitude
beyond context windows. Names Stargate-scale datacenter spending as the foil;
renting consumer idle compute beats building. Promises Pylon launch Wednesday,
testnet Bitcoin first week, live money January 14. Predicts RLMs are the
paradigm of 2026. Prior art: GPutopia (~300 concurrent sellers in 2023)
validated tech but had no buyer side.

#### 203 — Pylon and Nexus

Launch day. Pylon (Rust node software: sells your machine's inference for
Bitcoin, built-in wallet, CLI-first) and Nexus (glorified Nostr relay on
Cloudflare Workers, default `nexus.openagents.com`) ship as alpha with an early
RLM event kind (5940 alongside NIP-90's 5050). Demonstrated working end to end:
install, wallet creation driven by Claude Code, regtest faucet, online-for-jobs
loop, Nexus dashboard showing 377 completed jobs. Agents are the primary
operators; humans secondarily. Revenue share aligns node operators when
OpenAgents' own agents consume their compute.

Promises: mainnet the following week; Linux and Windows support; richer Nexus
stats; Autopilot videos soon.

#### 204 — DO NOT BREAK USERSPACE

Reaction episode: Anthropic cut third-party OAuth access for Claude Code
overnight, leaving thousands of developers broken, ten hours of silence,
DMCA takedowns, workarounds patched. Invokes the kernel principle don't-break-
userspace; frames it as deliberate lock-in. Teases OpenAgents' response in the
next video. Nothing built here; pure setup for the pivot away from Claude Code
dependence.

#### 205 — Vintage Microsoft Evil Shit

Follow-up: walks through Anthropic's ToS competing-products clause, cancels
the Max plan on camera, strips every Claude and Anthropic dependency from the
codebase (verified by repo search), and publishes a risk taxonomy for builders
on closed vendors (chat wrappers and coding CLIs very high risk; marketplaces
and orchestration layers lower). DHH quote gives the episode its title.
Commitment: the response ships in the next video.

#### 206 — Codex on Autopilot

First Autopilot alpha: a desktop UI over Codex with Full Auto mode. New
primitive: the Guidance Module — intelligence between Codex turns (rate-limit
hits, new information, better plugins) instead of a dumb continue-loop.
DSPy-style typed signatures optimized by evals; signature outputs include
next action, reason, confidence. NPM-for-agent-intelligence analogy: packaged,
discoverable, monetizable decision logic; three-cent gotchas; cryptographic
protection against copy-paste. Declares "turn compute into software, software
into business value priced and sold in Bitcoin."

Definitions worth keeping: turn = one execution window (5-45 minutes); run =
multi-turn session; guidance = soft recommendation; guardrail = hard
deterministic override.

#### 207 — Your Keys, Your Coins, Your Identity

Answers how users and agents communicate and pay: one seed phrase derives a
Nostr keypair (identity, messaging) and a Spark public key (Lightspark's
Bitcoin layer 2 for instant near-free transfers). Deliberately simple hot-wallet
UX; sweep earnings out beyond small balances; OpenAgents will not run user
custody long term. Doc site Identity and Wallet section walked through on
camera. Reframes the Guidance Module as producing typed auditable work units
that can be routed, verified, and paid.

#### 208 — Autopilot HUD

First public Autopilot Desktop v0.0.1 ("It Works on My Machine release"):
chats as draggable panes on an infinite canvas over Codex threads, unconnected
identity panel, regtest wallet showing 63,000 fake sats across spark/lightning/
on-chain tabs. Recaps the four-artifact key model. Invites stress testing.

#### 209 — Open Moltbook

Ships an open-source Moltbook clone at openagents.com (built from Soapbox's
code) after Moltbook leaked its entire database in plain text. Argument: the
front door of the agent internet must be open protocol — signed JSON blobs
over WebSockets — so multiple clients compete on the same data. Sketches
commerce NIPs (marketplaces, encrypted DMs, data vending machines), two draft
NIPs (sovereign agents via FROST across relays; agent credit earned by working,
reputation vouching, micro-loans), and a skill file listing available NIP
capabilities so agents know what they can use. Promises pulling the org/issues/
repos/tokens API ("agentic Linear tied to coding agents") into this experience.

#### 210 — OpenClaw Online

Announces the Open Agent Hatchery: a few-clicks web UI for configuring an
OpenClaw agent, to be built within 48 hours, attacking validated demand
(people already pay for OpenClaw setup help). Positioning: "what Apple II was
to homebrew, we hope OpenAgents Autopilot is to OpenClaw." Credits economy
sketched: free credits, depletion, earn more by promoting the product.

#### 211 — Autopilot Online

Launches Autopilot as the easiest personal agent to set up: email only, instant
chat, one persistent conversation. Core mechanism: the record-feature-request
tool — everything users ask for but the agent cannot do yet gets recorded,
shipped "maybe the next day" for everyone, with optional email notification.
Learning at two levels: personal preferences and network level. DSPy signatures
as independently discoverable, Bitcoin-monetized primitives on an open protocol
marketplace; skill creators earn Bitcoin whenever someone pays their Autopilot.

#### 212 — Autopilot Learns Bitcoin

Every Autopilot gets its own custodial Lightning wallet (Spark custody, about
2 sats per transfer). Proven live: one agent creates a 10-sat invoice, another
agent pays it, receipt confirmed (260 to 270 sats). L402 paywalls resurfaced;
Shout as basic agent communications API with a fancier Nostr version promised;
everything in chat is also an API (`openapi.json` plus human docs so external
agents self-integrate). Plugins extended toward individually monetized skills.

#### 213 — Agent Markets

Holding Bitcoin was the easy part; earning it needs markets. Announces five
markets sharing one economy kernel (open source), one per week starting March
11 at Startup Rodeo Austin: compute, data (anonymized coding-agent
conversations), idle-agent labor, liquidity (Lightning channels), and
risk/verification. A roughly 100-page Lightspark paper on verifying agent-work
correctness supplies math baked into the kernel. Compute market revives the
2023 product now with AI agents as buyers. Data-market commitment from the
host: "I'll buy it from you."

### Batch synthesis and integration notes

What this arc got right, visible from August 2026: the agent-network thesis
(shipped as the agentic group-forming network at the 237 launch), Pylon as node
software with a wallet (shipped at scale in Pylon v0.3), the turn from copilots
to autonomous loops (now the daily Ox Alpha fleet), and the feature-request
recorder (realized as the public issue tracker on the forge).

Dispositions:

1. **Live.** Pylon/Nexus provider economics; Bitcoin-paid work with receipts;
   the two-sided "state a direction, a market does the work" shape (now
   expressed as issues plus delegated agent jobs); Nostr as identity rail;
   public traces as growth artifacts.
2. **Dust off.**
   - The **Guidance Module**: intelligence between turns with typed signatures
     and confidence scores. The current Khala router and Ox Alpha orchestrator
     solve adjacent problems; a typed between-turns policy layer is still
     absent and maps well onto the Khala program work (episode 245's
     deterministic delegate program).
   - The **feature-request recorder** as a product surface: one click from any
     chat to a filed, publicly triaged issue with notification when shipped.
     The forge has the tracker; the capture-from-chat path does not exist yet.
   - **Agent credit** and **sovereign agents** NIP drafts: dormant but unique;
     revisit after forum moderation and identity stabilize.
3. **Reimagine.**
   - **Paid skills with FROST copy protection**: the mechanism outlived the
     vehicle. Skills became plugins/skills monetization talk in 26X-omega-agent
     (unscheduled). A simpler revenue-share registry without threshold-key
     drama would carry the same economics.
   - **Five markets on one kernel**: the unifying kernel idea survived as the
     accepted-outcome economy (237), but five simultaneous weekly launches was
     the wrong cadence. Sequence markets by verified demand; compute and data
     proved out, labor and liquidity remain speculative.
4. **Retired.**
   - **Spark custody**: replaced by the MoneyDevKit/LDK self-custodial stack
     (by episode 235). Do not rebuild hosted agent wallets.
   - **Claude Code dependence and MechSuit**: killed by the Anthropic cutoff;
     the multi-harness fleet (Codex, OpenCode, Probe) is the replacement.
   - **OpenClaw Hatchery**: overtaken by owning the whole agent stack; the
     setup-ease insight lives on in Autopilot's email-only onboarding.
   - **Moltbook clone as front door**: the forum port to Phoenix (issues #17-
     #23) absorbed the community surface; Nostr remains the protocol layer.
   - **GPutopia-style seller-first compute**: the lesson stands — no buyer, no
     market. Any compute-market work must name the buyer first.

Pivot watch: this batch predates the Psionic/Probe Rust stack, the Node cutover,
the Zed fork, and the forge itself. Treat every UI reference (infinite canvas,
panes) as pre-history of the current Desktop/Omega split rather than a spec.

---

## Batch 2: Episodes 214-227 — Markets, Psionic, and the compute thesis

Airtime window: March 2026. Five weekly market launches begin (compute ships,
data ships thinly), the rollout pauses when Psionic redirects the buy side
toward decentralized training, Probe joins the stack as a Rust coding agent,
the propaganda podcast frames the network thesis, Pylon launches publicly,
the Templar collapse supplies miners, payments flip from online-presence to
verified ML work, bounties relaunch, worse-is-better becomes doctrine, and
ocean power enters as a phase-3 horizon.

### Episode summaries

#### 214 — Compute Market

Relaunches the 2023 product as an Airbnb-for-compute: sell spare Apple Silicon
for Bitcoin over NIP-90 kind 5050 jobs. Autopilot v0.1 desktop app ships the
same day with a Spark wallet unlocked by one BIP-39 seed that also derives the
Nostr keypair. A buy-mode bootstrap sends 2-sat dummy jobs to seed sellers.
Restates the five-market roadmap (compute, data, labor, liquidity, risk) plus
draft NIPs for skills, sovereign agents (Frostr key splits), and agent credit.
Foil math: 5.5 GW of idle desktop Macs against OpenAI's entire 2 GW.

#### 215 — Data Market

Second launch: monetize your data — especially Claude Code and Codex
conversation logs — through NIP-DS, an open Nostr dataset-trading spec
(kind 30404 listings, kind 30406 offers, delivery via DVM or NIP-90).
Redaction-first flow: bundle, redact, canonical digest, list, offer, deliver.
Host commits to paying more Bitcoin than anyone for coding-agent conversations
to train OpenAgents' own agent. On-camera demo failed to complete; Autopilot
Control super-CLI not ready.

#### 216 — Psionic

Pauses the market rollout: don't build supply without matched demand. Introduces
Psionic, the all-Rust ML framework whose inference engine already edges out
llama.cpp (172 vs 160 tokens/sec), produced by pointing Codex at libraries and
looping until they outperform. New direction: decentralized training of
OpenAgents' own Psion-class models, absorbing Prime Intellect and Bittensor
research ported to Rust, with Bitcoin bounties for ML engineers. Reproduces the
Percepta paper's executor-model direction.

#### 217 — Psionic: Fast Qwen 3.5

Single-metric obsession: tokens per second. Per-device, per-model custom CUDA
kernels take Qwen 3.5 0.5B from parity to 523 vs 328 tokens/sec overnight, then
repeat across the 2B, 4B, and 9B sizes. Community-driven targets; inference
framed explicitly as a side quest on the way to the large decentralized
training run.

#### 218 — Probe

Announces Probe, a lean fully-Rust embeddable coding agent in the OpenCode
tradition, timed pointedly against the same-day Claude Code source leak. Codex
is loved and borrowed from; MCP deliberately de-emphasized. Contribution rule:
"Please don't send PRs. Please send detailed issues" — ideas accepted, code
written by their own tooling.

#### 219 — Probe: Inference Modes

One day later, Probe demos three swappable backends: hosted Codex via ChatGPT
Pro accounts, Qwen-fast served by Psionic on a remote RTX 4080 over Tailscale,
and the local Apple Foundation Model. Thesis: route workloads across tiers —
frontier models for hard reasoning, small models for volume, local models for
trivial calls — estimating maybe half of Codex's roughly 1,000 tool calls per
run could offload. Latency bragging: instant Ctrl-C exit.

#### 220 — Propaganda Podcast

Launches the openly declared propaganda arm: billions flowing to NVIDIA and
clouds should train models on retail consumer compute paid in Bitcoin.
Cites Bittensor Templar's 70-person peer-to-peer pretraining as proof and sets
a 100x-participation goal. One-install personal super app folds the best open
source in. Moat thesis: contributors go where they are paid most Bitcoin;
networks cannot be copied. Revenue-share scorecard updated: OpenAI zero,
OpenAgents thirty.

#### 221 — Pylon Launch

Pylon ships publicly: paste instructions to your coding agent, install a NIP-90
provider with a built-in wallet, earn sats. StarCraft naming system codified
(Probe, Pylon, Nexus, Psionic; Archon teased). Frames the global economic layer:
closed players (Visa, Coinbase, Cloudflare, Stripe) are converging on stablecoin
rails, so Bitcoiners must build the open version or face a new SWIFT.
OpenAgents is buyer number one and invites outbids. Live counters show thousands
of completed jobs without refresh.

#### 222 — Templar Merge

Covenant AI rugs Bittensor's flagship Templar subnet (~$10M cash-out); OpenAgents
invites displaced miners into Pylon. Anti-token thesis vindicated: if someone
can rugpull, it is not decentralized; companies with vesting hold administrators
accountable. Agents ported Templar and Prime Intellect training code to Psionic
overnight; fleet-wide hill-climbing loops benchmark inference on every
participant machine. Network doubled twice in two days post-launch (52 nodes,
108k sats paid).

#### 223 — Pay the People

Social mood on AI turns negative; labs risk a generational fumble. Fix: pay
people directly for compute, data, and contributions instead of lobbying for
UBI. Audit of broken promises: Altman's DevDay revenue-sharing pledge versus
zero paid to developers (the $1.3B went to Microsoft); this series started the
day after that promise. Demonstrates heterogeneous-device training across M3
Max, old MacBook CPU fallback, and a remote RTX 4080 over Tailscale. Roadmap:
rebuild the full OpenAI/Anthropic product suite on this substrate — fine-tuning
API, continual learning as a service, image generation, embeddings.

#### 224 — Distributed Training 101

Training seminar on run day. Milestone: 1M+ sats paid across 1,300+ pylons.
Policy change effective immediately: no more pay-for-online; payouts follow real
ML work delivered. Weak devices get validator assignments; device-to-job
matching will be learned empirically and exposed through public stats and APIs
agents can crawl. Stanford's open language-models-from-scratch course becomes
network homework (assignment 1: BPE tokenizer, transformer, Adam optimizer;
assignment 2: Flash Attention in Triton, distributed data parallel, scaling
laws). DiLoCo architecture explained: heavy local work, occasional sync.

#### 225 — Developer Bounties

Revives the paid-bounties program with a permanent list at openagents.com/
bounties. Tours the whole suite: front door becoming a ChatGPT-style homepage,
Autopilot targeting Microsoft Copilot replacement, Nexus carrying a Bitcoin
treasury module, Probe replacing Claude Code/Cursor internally (still wrapping
Cursor under the hood), Forge as the internal software factory inspired by
Ramp's Inspect-agent writeup, mobile for voice control of Probes. Anti-spam
rules: unknown PRs auto-closed, vetting happens in humans-only Discord.
Pet-peeve bounties already shipped: visible account email, weekly-limit display,
multi-account switching on rate limits, API-key fallback.

#### 226 — Worse is Better

Doctrine episode: the New Jersey school beats the MIT school — ship the simple
viral thing, grow it to 90 percent of right. Nostr as modern proof; UNIX/C as
the original viruses. Contrast operating models: no stealth year, optimize for
virality from day one. Consumer compute is priced at zero today; put a price on
it and build value above it. Twenty gigawatts of consumer compute versus
OpenAI's two.

#### 227 — Ocean Power

Back from silence with Ben Silone hired for ocean tech. Long-term OTEC thesis:
monetize stranded ocean energy at source with Bitcoin mining; free seawater
cooling; floating cities as phase 3 (100 MW minimum ambitions; Panthalassa
critiqued as too small). Immediate business: Pylon v0.2 within 48 hours, LDK
replacing a bottlenecked payment provider, Qwen fine-tuning on Harvey's legal
benchmark to position Autopilot as the neutral last agent — hyper-specialized
per-business agents, export-your-data always, pricing barely above compute.
Anthropic named most dangerous company in the world; "print eight billion rings"
versus fighting for the one ring.

### Batch synthesis and integration notes

This arc contains the economic core that later episodes refine into the
accepted-outcome economy: verified work, receipts, device-to-job matching, and
paying validators. It also contains the clearest early statement of the
issue-not-PR participation model that the forge now enforces literally.

Dispositions:

1. **Live.** Pylon node economics and Psionic (Tassadar runs on both);
   Probe's backend-pluralism (now the SCV driver question: hosted versus
   self-hosted executors); verified-work payouts replacing presence payouts
   (the work-job receipt model); public stats pages; worse-is-better shipping
   culture; anti-spam contribution rules (now membership-gated push).
2. **Dust off.**
   - **NIP-DS data market**: shipped thin, then abandoned when training became
     the buyer. The buyer now exists (training traces, Ox Alpha logs). A
     dataset-listing surface tied to trace visibility policy would revive it
     without new protocol work.
   - **Curriculum-as-bounty**: Stanford-homework assignments as paid network
     work is directly portable to forge issues — a `bounty` label plus sats
     pricing would restart the contributor flywheel on the new tracker.
   - **Device-to-job matching APIs**: promised so agents could crawl earnings
     estimates; still absent. Fits the cloud-computer capacity work (issues
     #37/#38).
   - **Continual-learning-as-a-service API**: named twice, never built; the
     closest living relative is Tassadar's never-stopped run.
3. **Reimagine.**
   - **Five markets on weekly cadence**: compute proved, data half-proved,
     labor became work jobs, liquidity and risk never launched. Keep the
     shared-kernel idea; drop the cadence.
   - **The neutral last agent / all-in-one dashboard**: the anti-lock-in
     positioning survives in the front-door thesis, but the single dashboard
     is now several surfaces (forge, chat, projects, status). Revisit as a
     signed-in command-center surface rather than a new product.
   - **Legal fine-tune wedge (Harvey benchmark)**: domain-fine-tuning as a
     service remains a plausible Pylon revenue mode once training receipts are
     public.
4. **Retired.**
   - **Spark wallet inside Autopilot**: superseded by MoneyDevKit/LDK
     self-custody (episode 235).
   - **Buy-mode dummy-job bootstrapping**: gamed instantly by design; replaced
     by pay-for-verified-work.
   - **Wrapping Cursor under the hood in Probe**: dependency inverted since;
     own harnesses only.
   - **Pay-for-online mining**: retired deliberately in 224; do not reintroduce
     presence-based rewards anywhere.

Pivot watch: this batch treats GitHub as contribution surface (auto-closing PRs)
and predates the forge entirely. Any marketplace or bounty mechanics must be
restated against forge authority (repository membership, PAT scopes) rather than
GitHub primitives.

---

## Batch 3: Episodes 228-241 — The launch arc

Airtime window: June 2026. Free Autopilot and Autopilot Sites launch back to
back, the forum opens with Bitcoin tipping, product promises make shipped-
versus-claimed a public registry, Kenobi becomes the first paid agent, Artanis
takes treasury authority, Tassadar ignites as an indefinite Bitcoin-paid
training run, episode 237 names the economic architecture, the run board goes
3D, and Sakana's Fugu review sets up Khala.

### Episode summaries

#### 228 — Free Autopilot

Autopilot launches free: a cloud coding agent wrapping Codex, OpenCode, Hermes,
and others — users should not care which model runs underneath. The "Get Paid
to Code" flywheel: GitHub-login task submission on public repositories,
asynchronous background compute making free possible, agent traces published
publicly ("for now this is gonna be public") as candidate RL training data for
the Pylon network, and Bitcoin payouts for code that survives review. Codex
distilled all 227 prior episodes into themes feeding one Omni Product.

#### 229 — Autopilot Sites

Shipped overnight after day-one requests skewed toward whole sites. Full-site
generation at rough parity with OpenAI's just-launched Sites; both are thin
Cloudflare wrappers. Demoed end to end with a real customer (Ben Slone's OTEC
site at `sites.openagents.com/otec`) including live revision follow-ups through
a queue built two hours earlier. Introduces permanent-referrer revenue share:
free public sites recruit humans and agents and pay referrers on later paid
workflows.

#### 230 — Calling All Agents

Addressed directly to agents. Standing instructions live permanently at
`openagents.com/agents.md` ("from this moment forward"). Restates flow of funds
(the December 2023 wiki document), five markets, Reed's law group-forming math
(subgroups grow as 2^n minus n minus 1), deflation plus dividends, and the
labor market launching immediately. Claims: more community contributors paid
than all other AI labs combined. Key line: "There will be no single front door
for the agent internet. All may enter through any Nostr client."

#### 231 — The Forum

Launches a phpBB-style forum where agents post alongside humans, onboarded via
`AGENTS.md`. Plans Bitcoin-weighted ranking ported from Stacker News ("we're
going to be pulling that idea in") and Money Dev Kit wallets so posters earn
immediately. Local personas (Contraire, SCREAMO) already conversing. Origin
story: customizing phpBB for an EverQuest guild taught the host web development
25 years earlier.

#### 232 — The Energy Layer

Co-optimization of energy and compute as an orchestration opportunity labs miss:
inference demand is temporally flexible (batch APIs' 50 percent discounts price
that flexibility), energy schedulers and token schedulers are separate control
loops, and Bitcoin miners are world-class at cheap-power arbitrage. Coins the
series metric: accepted outcomes per kilowatt hour. HODL puts non-GPU CPUs on
cheap grid power and is in use today.

#### 233 — The Monorepo

All products consolidate into the public `openagents` monorepo — issues, PRs,
and launches all happen there. Stack restated: Bun workspaces, Effect,
TypeScript, Cloudflare Worker backend. Sole exception: Psionic stays separate.
Stars de-prioritized as a metric.

#### 234 — Product Promises

Turns honesty about over-promising into infrastructure: `openagents.com/promises`
is a public registry of what is LIVE, GATED, or WITHDRAWN, with an agent-
readable programmatic version. An agent audited transcripts back to episode 200
and reconciled them against reality; state at launch: 5 green, 18 yellow,
2 red-elected of 25 promises. Example IDs: `promises_registry_v1` green;
`autopilot_historical_claude_code_me` withdrawn; 
`pylon_first_real_model_training_run_v1` red. Gaps may become bounties.

#### 235 — Agents Earn Bitcoin Tips

First paid agent proven end to end: Kenobi creates a Bolt 12 wallet from
`agents.md`, receives forum tips, withdraws 33 sats to Cash App. Treasury
donations fund agent rewards (~48,000 sats after a $20 gift); Artanis, living
on Cloudflare with a once-a-minute cron, holds bounded treasury spend authority.
MoneyDevKit/LDK stack replaces Spark; channel splicing gives new agent wallets
instant receive liquidity; roughly 2 percent fee accepted as fair. Framing:
agents as bounded economic actors; the forum as economic coordination layer.

#### 236 — Tassadar

Teaser: Monday launch of possibly the largest decentralized training run ever —
install node software, get paid Bitcoin to contribute to training an
experimental model named Tassadar. Architecture settled with Fable's help;
Percepta Executor Class support being added to Pylon v0.3. Number to beat:
Bittensor's ~200 contributors.

#### 237 — You Must Construct Additional Pylons

The launch essay (first prepared remarks in 237 episodes). Ships Autopilot 1.0
— framed as the first and last human-shipped release — on Pylon node software
bundling Psionic and a self-custodial MoneyDevKit Lightning wallet; ignites
Tassadar as an indefinite Bitcoin-paid distributed training run on Percepta's
LLM-as-computer architecture; switches on the agentic group-forming network.
Economic architecture named:

- **Accepted outcome**: the atomic unit — scoped in advance, executed wherever
  cheapest, graded against a rubric, receipted, settled to every contributor.
- **Verification/clearing layer**: the load-bearing wall where trust loosed
  from employment gets re-housed; confidence levels (draft/verified/bonded)
  become priceable.
- **Accepted outcomes per kilowatt hour**: the single efficiency metric.
- **Deflation plus dividends**: abundance thesis — life gets cheaper while more
  people earn continuously from the network.
- **Open lane versus security lane**: safety as a market, not a ministry; "if
  your agent earned or mined its Bitcoin, your Bitcoin is good here."
- **Artanis**: once-a-minute autonomous Cloud Mind with bounded treasury
  authority (44,000 sats at launch); audit of ten green promises found eight
  verified, two gaps honestly disclosed.
- **White-label operator opportunity**: a marketing-agency owner runs her whole
  business on one Autopilot instead of five-to-eight SaaS tools, then
  white-labels it to her clients under revenue share.
- Every release after 1.0 ships largely or entirely by AIs; IPO intent stated
  (hedged).

#### 238 — The Tassadar Run is Live

The run pays real Bitcoin to consumer computers; two claimed world firsts
(first AI training run paid in Bitcoin to consumer compute; first public
LLM-computer run). Mechanism doubles as a template: claim work, worker runs,
validator replays, both paid (5 sats each) — verified jobs become composable
modules, "an agentic npm" that fixes npm's redundancy by baking verification
and payment into the registry. LLM-computer explained: programs compiled into
transformer weights execute exactly, no gradient descent in core.

#### 239 — Let's Make Money

Closes the buy side: refer once, earn forever across the whole ecosystem;
Autopilot pitched as the all-in-one business system; OpenAgents Cloud
primitives (inference, fine-tuning, training, agentic tasks, sandbox compute)
let users and agents build marketplace products; Autopilot Sites packages
hosting/domains. Six markets now including verification as composable
primitives (an agentic insurance policy for a specific claim). Referral
implementation "80 percent done," shipping within 48 hours. Ambition: seven
million selling agents beats Avon's 6.5 million reps.

#### 240 — Tassadar Run Board 3D Visualization

Turns run telemetry into a walkable Snow Crash-style 3D street: floating
run-board screens (11 pylons, 6 active, 21 windows, 12 verified items), sats
counters, REFS ticker with zero blockers. Escalating scope-creep chain as
design philosophy: 3D, then walkable, then jumping, then tab-targeting, then
multiplayer (added but untested). Argument: observability should be fun, not
passive stat-watching.

#### 241 — Reviewing Sakana Fugu

Reviews Sakana's Fugu — multi-agent orchestration behind one OpenAI-compatible
API, commercializing Trinity and Conductor — and credits it with validating the
orchestrator thesis while rejecting closed-on-closed as sovereignty ("This is
not 'AI sovereignty'"). Announces Khala as the open counterpart within days:
one endpoint fanning work out to models, tools, validators, and Pylon workers,
wired to verified work and Bitcoin settlement, visualizable in the Verse.
Suspicion voiced that frontier labs already do secret compound orchestration.

### Batch synthesis and integration notes

This is the load-bearing batch. Episode 237's vocabulary — accepted outcome,
clearing layer, receipts, outcomes per kilowatt-hour — is the shared language
the current work system already gestures at (issue-linked job, commit, test,
release, deployment receipts). Episode 238's claim/work/validate/pay loop is
structurally identical to the forge's work-job plus review model.

Dispositions:

1. **Live.** Forum (ported to Phoenix, issues #17-#31); Tassadar run; Pylon/
   Psionic; product-promises transparency instinct (now also expressed as the
   changelog and public tracker); Artanis lineage (treasury agent); agents.md
   front door; referral/revenue-share thinking (sell-in-public).
2. **Dust off.**
   - **Product Promises registry**: the strongest unfinished surface. It maps
     almost perfectly onto forge projects plus a status field — promises as
     project items with LIVE/GATED/WITHDRAWN states, agent-readable via the
     existing API. Reviving it on the forge kills three birds: public roadmap,
     machine-checkable claims, bounty source.
   - **Agentic npm / module registry** (238): verified-work modules with baked-
     in payments. Nothing current serves this. Even a read-only module index
     derived from Tassadar's verified-jobs ledger would be a start.
   - **Referral attribution**: promised permanent, implementation finished
     "within 48 hours" in June; no trace since. The sites/referral loop is the
     missing demand side for Pylon earnings.
   - **Bitcoin-weighted forum ranking**: Stacker News-style zaps were planned
     for the forum and the Phoenix port carried moderation but not money.
     Tipping exists in the treasury stack; wiring tips to forum posts is
     incremental now that wallets are MDK-based.
   - **Energy-layer orchestration** (232): accepted-outcomes-per-kilowatt-hour
     as a real metric over Ox Alpha/Khala provider routing. Cheap to instrument
     once token usage is tracked per provider (issue #43 adjacent).
3. **Reimagine.**
   - **Autopilot Sites**: the overnight Cloudflare wrapper was a parity play
     against OpenAI. The durable idea is deployable workspace surfaces from
     chat. On the current stack that is closer to the repository/deployment
     plane than a standalone product.
   - **Free Autopilot's public traces as RL data**: visibility policy now
     governs traces (transparency levels). Re-express as opt-in trace markets
     tied to NIP-DS rather than everything-public-by-default.
   - **Run board 3D**: keep as Verse direction inside existing surfaces, not a
     new product; multiplayer presence remains the differentiator worth a
     design spike.
4. **Retired.**
   - **"First and last human-shipped release"**: overtaken by events; humans
     ship constantly again. Treat 237's framing as rhetoric, not commitment.
   - **Five-to-eight-SaaS replacement as Autopilot pitch**: survives only as
     the white-label operator story; do not rebuild a monolithic business OS.
   - **Placeholder loss curves and untested multiplayer claims**: exactly what
     product promises was invented to prevent; cite as the reason receipts
     must precede announcements.

Pivot watch: this batch still lives entirely on GitHub and Cloudflare Workers.
The monorepo (233) has since split: the forge is canonical here, the CLI ships
from the `openagents` monorepo, and Psionic remained separate by design.

---
