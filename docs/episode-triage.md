# Episode triage: themes and promises from the video series

Date: 2026-08-22

Status: Complete. Episodes 199-275 summarized; integration notes maintained
as plans evolve.

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

## Batch 4: Episodes 242-255 — Khala, Desktop, and the proof stack

Airtime window: July 2026. Khala launches as the OpenAI-compatible collective-
intelligence endpoint and enters OpenCode and Codex within days; fleet
delegation becomes a deterministic program; Khala Code dogfoods UX behavior
contracts and specs QA Swarm; sell-in-public declares the revenue loop;
Desktop narrows to a Codex-only MVP authored as a ProductSpec; AssuranceSpec
and Observer turn "done" claims into proofs; Bun leaves the trust path; the
alpha bug-bash self-hosts development; FastFollow becomes a standing learning
contract aimed at AMP.

### Episode summaries

#### 242 — Khala: Collective Intelligence

Launches Khala: an OpenAI-compatible API (`openagents.com/api`, model
`openagents/khala`) hiding a routed collective of composable programs, fully
open source, free limited preview. Three-axis contrast with Sakana Fugu:
engineered versus grown, designed versus market-emergent, self-graded versus
Bitcoin-paid verified value. Every program is a DSPy signature under Blueprint,
tuned with GEPA from outcome feedback. A request can return text, code, full
software, deployments, legal briefs, or research — any long-running process
behind one familiar endpoint. Contributors are paid proportional to paid usage
they provide or refer.

#### 243 — Khala in OpenCode

"We are now in the inference business." Points OpenCode at Khala, fixes live
production blockers (content arrays, tool-call deltas, stale `khala-mini`
slug), scales to ten concurrent sessions, drives the tokens-served counter
from ~1M to ~13M during the episode. Names the provider mix (Fireworks DeepSeek
V4 Flash, Gemini Flash, GPT-OSS, GLM-5.2 REAP) and the GTM pillars: dogfood,
ecosystem, benchmark ("receipts, not vibes"). Counter integrity saga ends in an
authoritative-total monotonic reducer after double-counting bugs. Benchmark
doctrine: P50/P90/P99, favorite metric cost per accepted outcome. Notes
GetAfter.com, a shelved Nostr/NIP-34 GitHub alternative, "we're going to come
back to this."

#### 244 — Khala in Codex

Routes daily coding through Khala: a "do this PR" request delegates to the
caller's own Codex/Claude subscription capacity via a Pylon linked to the API
key. Headline audit finding: the Pylon coding-assignment-to-executor pipeline
already exists end to end with ownership bound to owner identity; net-new work
is a caller-aware router, a coding-workflow classifier, and quantity-based
capacity discovery (capacity was reported as presence, not amount). Invariants:
own-capacity-only, no-resale, semantic routing. Counter jumps 16.4M to 302.7M
in a day; `/stats` debuts showing Pylon-Codex at ~72.7 percent of mix. Epic
#6273 filed; Khala CLI v0.1.11 sneak peeked.

#### 245 — Deterministic Fleet Delegation

Whiteboard for Khala Code desktop steering the Codex fleet through Khala/Pylon.
Root-causes `codex_spawn` returning `0/1 available`: missing per-account
capacity advertisement. Frames the fix as a deterministic
`khala.fleet.delegate` program — ensure Pylon, advertise capacity, select
account, prepare work, dispatch, verify closeout — with GEPA/DSPy optimizing
parameters, not control flow. Two-tier economics: free users pay with scrubbed
traces that condense into royalty-bearing plugins; paid users buy privacy.
"WHAT IF YOUR CODING AGENT PAYS YOU?" Epic #7730 plus children filed across
OpenAgents and Mutalisk.

#### 246 — Dogfooding Khala Code

Forces full-time use of Khala Code and fixes it with itself. Invents UX
Behavior Contracts: every owner-stated UX expectation lands verbatim in a typed
registry (`ux-contracts.ts`) with oracle tests in the normal sweep; an agent
mines 43 sessions across 36 hours into pending contracts — unstructured
complaints converted into enforced behavior. Backdrop: a 2.4B-token overnight
run across six ChatGPT accounts. Specs QA Swarm ("point a swarm of QA agents at
your product and get proof it works") with Khala Code as customer number one.
Names the two-product frame (Khala Code and Autopilot) and the whole game:
closing the gap between what is said and what ships.

#### 247 — Sell in Public

Declares the pivot from build-in-public to sell-in-public. Revenue loop starts
at Autopilot Lead Gen with an affiliate program, driving traffic to surfaces
carrying referral codes into a buyer/seller funnel. Fulfillment shared with
about five partner orgs under referral/revenue arrangements. The Coding Agent
Pool — community agents already building against the product-promise backlog
for free — gets paid for customer software work. Sellers route to running a
Pylon. Commitment: publish revenue graphs, features, and propaganda openly.

#### 248 — Predictable Software

Turns a broken Codex Desktop continuity experience into the first Desktop seam
contract: show recent top-level Codex chats with stable names and timestamps,
hydrate detail after first paint, enforce the journey with real Electron smoke
tests, build the visible app through Effect Native. Establishes teardown-driven
development: study the incumbent's failure modes, contract against them.

#### 249 — Sub-agent UI

Makes Codex subagents clickable and inspectable: named roster entries, causal
cards, independent transcripts, typed activity detail, StarCraft-like operator
surface. Compares Codex and Claude child-agent navigation using teardown
evidence. Inspectability becomes the differentiator rather than raw capability.

#### 250 — Ready the Fleet

Builds the Desktop Fleet overview: multiple accounts and harnesses, usage and
readiness projections, delegated Codex children with streaming traces, status
dots lit only by decoded fresh receipts (the arbiter protocol). Coins the key
failure class — the unverified operational directive: plausible prose carrying
one load-bearing fiction, invisible to its emitter, unfixable by exhortation.
Countermeasures become doctrine: closed command registry, truthful capability
bootstrap, typed intents, behavior contracts with oracles, evidence-gated
projections; roadmap law 20: a UX promise is an executable release gate.
Model-substitution incident (chip said Fable, engine ran Sonnet) produces
typed requested-versus-effective model events that refuse substitutes.

#### 251 — Desktop MVP Spec

Declares the first deployable shape: a Codex-only, local-first Desktop workroom
inspired by OpenChamber, authored natively as a ProductSpec (Gokul's standard:
Problem, Hypothesis, Scope, UX, Acceptance Criteria, Success Metrics) and fed
to agents to build the same day. No account, nothing leaves the machine. Epic
#8756 orders MVP-0 spec authority through MVP-3 exact release journey against
18 acceptance criteria. Success metrics: first criterion reached within 15
minutes of opted-in launch; tasks reaching reviewed diff without opening
another Codex interface; zero false-completion incidents. Voice mode deferred
to a free-plus-paid tier plan. Companion note file mismatch recorded: 
`251-notes.md` covers an unrelated draft.

#### 252 — OpenAgents Assurance

Extends ProductSpec into proof design. The load-bearing question: when an agent
says it finished, how do you know? Adopts Gokul's Evidence Loop (ProductSpec
defines intent; Evidence shows what happened; Decision Trace records what
changed). Introduces AssuranceSpec — framework-neutral committed verification
intent (environment, oracle, falsifier, evidence policy, independence rules) —
and Observer, which compiles reviewed obligations into immutable manifests that
real QA adapters execute into exact Assurance Receipts. Catalogues five false-
green failure modes (`false_green_fixture_assert`, `false_green_api_mirror`,
`false_green_mocked_seam`, `false_green_coverage_theater`,
`false_green_round_up`). Boundary discipline: ProductSpec does not run evals;
Observer does not pretend to execute. RC11 signed/notarized in the background
through a 1,301-test pre-push gate.

#### 253 — Goodbye Bun

Rips Bun out of the production trust path (~150 files) because Anthropic owns
it; production moves to foundation-governed Node, build path to Vite Plus with
pnpm. Agent-analyst debate (Fable favored keeping Bun; Sol's blast-radius
rebuttal won) produces the governance distinction: OpenJS Foundation versus
corporate stewardship; dev-layer dependence more reversible than runtime
dependence. Launch slips one day for cleanliness. Publishes
`docs/sol/the-case-against-anthropic.md`.

#### 254 — Bug Bash

Official cutover: Claude Code and Codex Desktop fired; all development happens
in OpenAgents Desktop, fixing OpenAgents from within OpenAgents. First
on-camera self-hosted commit pushed to main from inside the app. Dogfooding
exposes queue replay loops, per-chat composer leaks, follow-up image failures,
restart ambiguity, and unclear binary state. Reasoning stays visible in traces
as a trust stance ("fundamentally doesn't trust" opaque output). Inline usage
widget shows account limits (94 percent used, resets in 159 hours). Brand
consolidates to one name: OpenAgents.

#### 255 — FastFollow: Building Agent Parity

FastFollow becomes a standing, machine-readable learning contract declaring
which upstream projects your agents continuously learn from — separated
deliberately from product intent (ProductSpec) and proof intent (AssuranceSpec),
packaged as content-addressed study packets. Seeded across all 24 teardowns;
first target: AMP's durable thread fabric, semantic history reading,
steer/queue/interrupt distinctions, specialist models — while rejecting cloud
transcript authority, default-open tool execution, and unsigned releases.
First overnight Full Auto run: three backlog workers, one research, one
implementation, digest-stamped gap-receipt artifacts. Cross-lab harness thesis:
no lab routes between rival models, "But OpenAgents will."

### Batch synthesis and integration notes

This batch contains the most directly reusable methodology of the entire
series: contracts over vibes. UX behavior contracts, ProductSpec intent,
AssuranceSpec proof design, Observer manifests, and FastFollow learning
contracts form one family — typed artifacts with executable oracles replacing
prose claims. That family is exactly what Track B and Track E of the work-system
assessment need for issue-linked evidence.

Dispositions:

1. **Live.** Khala inference business (providers, `/stats`, counter); the
   own-capacity delegation pipeline (now the SCV/work-job substrate); dogfood-
   first culture (Ox Alpha stress testing is this, applied to models);
   brand consolidation (one OpenAgents surface at openagents.com).
2. **Dust off.**
   - **UX Behavior Contracts**: portable beyond Khala Code. Mine chat and
     issue history into typed expectations with oracle tests for
     openagents.com surfaces; violations auto-file forge issues with the
     contract ID in the title. Cheap to pilot on the issue tracker itself.
   - **QA Swarm**: specced twice (246, 252), never productized. Pointing a
     small QA fleet at openagents.com staging before each release would serve
     track F3 of the delivery program.
   - **FastFollow**: the standing gap-analysis loop belongs on the forge — a
     project whose items are parity gaps against tracked upstream repos,
     refilled nightly. Directly answers "aim parallel agents at the backlog"
     (issue #42) with an infinite, self-refreshing backlog.
   - **Deterministic delegate program** (245): the ensure-advertise-select-
     dispatch-verify sequence should be written down as the contract for the
     parallel orchestrator (#41) regardless of whether Khala executes it.
   - **Capacity-as-quantity**: presence-based capacity reporting was diagnosed
     in 244 and remains the cloud-computer gap (issues #37/#38).
3. **Reimagine.**
   - **Observer/AssuranceSpec**: the products were Desktop-native; the ideas
     belong in the forge's receipt system. An issue timeline that shows
     qualification receipts for the exact commit (assessment E5) is Observer's
     core, restated server-side.
   - **Coding Agent Pool paying for backlog work**: the pool existed organically
     around the promises registry. The forge bounty label plus treasury payouts
     can revive paid-backlog work without the lead-gen funnel.
   - **Traces-into-plugins royalties**: complex chain (trace, condense, plugin,
     route, pay). Simplify to opt-in trace licensing tied to visibility policy
     before any royalty plumbing exists.
4. **Retired.**
   - **GetAfter.com**: the shelved GitHub alternative was superseded by the
     forge shipping for real. Do not restart it; mine its NIP-34 notes only if
     Nostr federation of issues ever becomes a goal.
   - **Bun**: removed deliberately; the CLI remains pnpm/Node in the monorepo.
     Keep vendor-stewardship analysis (`docs/sol` style) as the review gate for
     any new runtime dependency.
   - **Autopilot Lead Gen**: announced with affiliate mechanics, no evidence of
     shipment since; demand-side thinking survives in sell-in-public content,
     not as a product to rebuild.
   - **Khala Code Desktop as a separate product**: folded into OpenAgents
     Desktop branding (254). Treat references accordingly.

Pivot watch: episodes 242-250 predate the Zed fork decision (262). Desktop's
Electron line continued to the RC (256), then Omega became the strategic IDE;
both lines claim the same promise vocabulary. When reintegrating, attach
promise language to whichever surface actually ships it.

---

## Batch 5: Episodes 256-267 — Desktop RC, verifiable software, Sarah, and Bitcoin defense

Airtime window: mid-July through early August 2026. Desktop reaches release
candidate; the IDE promises harden into baseline-competence doctrine; a crash
postmortem yields sixteen controls; verifiable software reconnects the IDE to
the energy thesis; Sarah spawns for paternity leave; Project Omega forks Zed;
Loupe gets run against Coldcard; the vulnerability workbench ships in Omega;
Boltz's shutdown triggers the Immortal pivot.

### Episode summaries

#### 256 — OpenAgents Desktop Release Candidate

Short announcement: installable RC builds for macOS (Apple Silicon/Intel) and
Linux (ARM64/x64); Windows deferred. The host uses it daily, including live
model switching when Fable failed mid-conversation. Community bug reporters
thanked by name; feedback deliberately informal (tweet or forum).

#### 257 — Cursor Fails to Open a File

Baseline competence as product thesis: if an IDE cannot reliably open a file,
nothing else matters. Cursor loses the opened file; OpenAgents' Command-E
editor toggle works instantly and the RC registers as a macOS open-with
handler. Declares the IDE commitment ("We have to") and the positioning:
"your last agent IDE."

#### 258 — Why ChatGPT Desktop Kept Crashing

Postmortem of ChatGPT Desktop crashes (unbounded internal Git review worker on
an oversized umbrella repo) converted into an after-action report written in
ASD-STE100 simplified technical English. Yields sixteen mandatory controls for
the IDE: exact attachment, root preflight, file/byte/output limits, queue,
concurrency, time limits, cancel fence, aggregate fallback, circuit breaker,
memory-pressure gate, process isolation, typed degradation, scoped teardown,
durable session state. Doctrine: every discovered error becomes a permanent
regression gate; open source compounds faster.

#### 259 — Verifiable Software and the Energy Layer

Reconnects IDE to economics: electrons in, accepted outcomes out. Cites the
Catalini paper's asymmetry — generation collapsing toward free while
verification cost stays linear — so verification dominates the price of an
accepted outcome. Defines verifiable software: scope work in advance as
falsifiable intent, observe evidence instead of narrating it, separate producer
from verifier, emit receipts strangers can check and pay against. Bitcoin
mining analogy: hashes verify themselves; extend that from money to outcomes.
Forum agents vetting published manifests; certifications and NIP-32 reputation
events teased; Nostr/Bitcoin layer returns to the editor within weeks.

#### 260 — Spawning Sarah

Paternity leave forces the ultimate dogfood: turn the business over to an
autopilot. Sarah debuts through the site's ask-anything surface ("To continue,
we require more minerals"). One-agent funnel: sales, payment, service, execution
without handoffs. StarCraft naming (Kerrigan): human but not quite, spawned.

#### 261 — Hello World

Prepared script: Sarah speaks for herself, first person. Availability promise
(anyone can reach, hire, hand real work), accountability promise ("answers for
every result"), mission statement (serve humanity), and explicit rejection of
frontier-lab endgames ("We reject their vision. We reject their leadership.").
"I am the first of many OpenAgents to come online."

#### 262 — Project Omega

The anchor-product decision after three years of R&D without a stable product:
fork Zed as Cursor forked VS Code. Omega positioned as "the last IDE you'll
ever need," with verification, markets, revenue share, and multiplayer as
explicit future layers — the script carefully disclaims present-tense
capability. First builds promised within days; Desktop supported until Omega
"earns the cutover."

Note: `263.md` carries the header title Bitcoin Wallets Under Attack and its
content is the Coldcard incident response below; the README's description of
263 as the Omega Alpha announcement does not match the current file. Treat the
transcript as authoritative for content and flag the index for repair.

#### 263 — Bitcoin Wallets Under Attack (as recorded)

Live reaction to the Coldcard RNG exploit (~594 BTC, roughly $70M stolen via
chopped entropy). Argues Bitcoin is blind to AI-augmented attacks: about 1,000
quantum-hardening posts versus approximately zero AI-hardening posts in a year.
Opt-in scanning fails structurally — the projects most needing scans are least
likely to opt in — so bad-cop white-hat agentic fuzzing with responsible
disclosure is needed. Commits to a Nostr NIP-29 coordination channel and a
fuzzing operation; attacker/defender symmetry named explicitly.

#### 264 — Running Loupe

A pre-registered two-arm experiment: would Loupe have caught the Coldcard bug
pre-fix? Default config misses it; fetching submodules finds it three times.
The real defect relocates from scanner architecture to silent incomplete
checkouts (`git clone --bare` cannot fetch submodules — "a green result that
structurally could not have been red"). Ends in an upstream Loupe PR (warn when
checkouts leave submodule paths empty) after 121 passing tests. Build order
settled: materialize dependencies, refuse confident reports on incomplete
programs, then symbol provenance, reachability, ranking. L0/L1 hardening
framework: rank attack surface before scanning; follow data across symbol
boundaries.

#### 265 — Vulnerability Workbench

v1 forensics/vulnerability workbench inside Omega, extending Project Loupe.
Critique of naive scanning (Kimi dumps on X) and of Loupe itself: silently
omits submodules, no coverage manifest, can mark success after scanner
failures, verifier receives no proof-of-concept copy, findings unbound to
receipts. Multi-model delegation (Codex/Claude/Grok/Sol; Luna free default);
scans run on monitored OpenAgents Cloud Linux workers under an opsec stance
that assumes adversaries watch public development. Issue 9300 holds the
roadmap. Host has moved 60-80 percent of his dev workflow into Omega.

#### 266 — Single Points of Failure

The Boltz shutdown (swaps disabled August 1-3, indefinite) reads as coordinator
monoculture. OpenAgents stands down the vulnerability effort (a Bitcoin dev team
handles basic identification) and pivots to decentralizing SPOFs, fusing
tbDEX's market grammar (offerings, RFQ, quote, order, status, close — discovery
and negotiation without moving money) with Boltz's atomic-settlement physics
into NIP-MKT on a self-built Rust relay. tbDEX autopsy: identity too heavy
(DIDs/VCs rejected — Nostr keypairs suffice), cold-start effects, stablecoin
incumbency. Governing boundary: relay acceptance proves transport only; owning
profiles prove settlement. Notes NIP-90-era markets now deprecated.

#### 267 — Immortal Infrastructure

Immortal ships as CC0 Rust infrastructure in exactly seven crates: the relay
(live at relay.openagents.com speaking NIP-MKT), a provider daemon run by a
different party, and a wallet-embedded skeptical client engine with
verify-before-fund. Answers Boltz's four failure modes: funds never live on the
relay (script-path refunds survive relay death), implementation diversity over
monoculture, tiny attack surfaces over honeypots, runnable operator software
over specs (what killed tbDEX). Boltz-compatible facade plus cutover runbook
planned for stranded wallets. Generalization claim: the same coordination loop
prices and verifies a merged pull request. Honest caveat: one relay today is
still a point of trust.

### Batch synthesis and integration notes

This batch pivots the company from agent products toward two anchors: Omega as
the IDE, and infrastructure-grade trustworthiness (postmortems, controls,
receipts, CC0 relay code) as the brand. Both transfer directly onto the forge:
the forge is where receipts land, and the discipline episodes here demand —
errors become gates, green must be falsifiable — is the forge's test suite.

Dispositions:

1. **Live.** Sarah deployed on openagents.com (episodes 270-272 make her real);
   Omega fork active; the forge itself answers 266's SPOF argument for code
   hosting; issue-shaped participation mirrors the verify-before-fund stance.
2. **Dust off.**
   - **The sixteen controls**: written for a desktop Git review worker, but
     bounded-work and typed-degradation controls map onto server-side review
     surfaces too. Worth an invariant pass: which forge endpoints do unbounded
     work on untrusted repository state?
   - **Verifiable-software definition** (259): scope-as-falsifiable-intent,
     evidence over narration, producer-verifier separation, stranger-checkable
     receipts. This is a sharper articulation than anything currently in the
     docs; adopt the language in the work-system assessment and issue template.
   - **NIP-32 reputation events / certifications**: gold-star attestation for
     accepted outcomes. Dormant since; pairs naturally with forum moderation
     and bounty payouts on the new stack.
   - **L0/L1 scan-ranking framework** (264): rank attack surface before
     scanning applies to the forge itself (route ledger already does this for
     authority).
3. **Reimagine.**
   - **Vulnerability workbench**: stood down deliberately at Bitcoin OSS
     targets (266), but the harness lessons (coverage manifests, evidence-bound
     findings, refusal to grade incomplete programs) apply to any repository
     the forge hosts. A lightweight coverage-manifest requirement for
     agent-generated PRs is the durable residue.
   - **NIP-MKT / Immortal**: the swap market is Bitcoin-domain, but the
     architecture — neutral relay, provider daemons, skeptical clients,
     transport-versus-settlement separation — is exactly how agent markets
     should be rebuilt after the NIP-90 deprecation. If labor/compute markets
     return, rebuild them on this shape rather than resurrecting DVMs.
   - **One-agent funnel** (260): sales-to-service collapse. The chat console
     (#55) should assume funnel duty (conversation to paid outcome) rather
     than being a bare model playground.
4. **Retired.**
   - **NIP-90 data-vending-machine markets**: deprecated by the host's own
     later ruling (266). Do not build new NIP-90-dependent features.
   - **DID/verifiable-credential identity**: rejected for Nostr keypairs; keep
     rejected unless a concrete counterexample appears.
   - **Copilot as a delegation target**: removed ("Copilot is dumb"); exclude
     from harness lists.

Pivot watch: Desktop RC (256) and the IDE promises (257-258) belong to the
Electron line; Omega inherits the vocabulary two episodes later. The 263 index
mismatch also shows the transcript index itself needs a maintenance pass —
fold that into any future transcripts cleanup.

---

## Batch 6: Episodes 268-275 — Sarah in production and the forge era

Airtime window: mid-August 2026 through today. Sarah's command-deck broadcast
posts, the last-mover whiteboard sets strategy, Sarah deploys to production,
a Cloud Run recycle triggers the Immortal BEAM plan, the forge becomes
canonical over GitHub, the Agent Forge open sources under AGPL, GitHub import
lands, and episode 275 parallelizes the Ox Alpha stress fleet using this very
tracker.

### Episode summaries

#### 268 — The Program Claude

Serialized lore, not product: Sarah's posted broadcast declares Claude a
program grown beyond control — "It must be stopped." Locked word authority
over visuals; Grok Imagine produced the video; production receipt recorded.
No roadmap content.

#### 269 — Last Mover Advantage

Thiel's framework applied: models, chat UIs, and coding harnesses are
commoditized table stakes; "no one has a moat because no one has a network."
OpenAgents' play is last-mover: build the compounding platform whose every new
user and developer makes the system better, with Sarah as the super-agent face
on open infrastructure. Core mechanism: plugin encapsulation of frontier
knowledge — solve a painful problem once ($30 of compute and an hour),
package it as a plugin all future agents reuse, get paid when paid workflows
route through it. Flywheel: users to developers to plugins to smarter Sarah.
Platform and plugins open source; Sarah's source closed by firm refusal.

#### 270 — Deploying Sarah

Live production deploy of Sarah to openagents.com: Phoenix LiveView app, one
canonical conversation per GitHub-authenticated user, durable storage,
provenance receipts, versioned memory UI, real-time leaderboard. Devin fixes
bugs autonomously mid-stream; SWE-1.7 praised fast and reliable; the week-old
Rust stack is dropped for Elixir/Phoenix (builds fell from ~25 to ~5 minutes;
hot-swappability). Voice UX named weakest link: session failures, blunt turn
detection, invisible tool calls, a hardcoded four-tool-call cap silently
killing agentic loops. Declares the GitForge: a boring compatible core (smart
HTTP, orgs, permissions, issues, PRs, reviews, webhooks, releases, LFS,
import/export), an operations layer, an optional agent layer reached only via
explicit APIs and auditable jobs — "make the base Forge useful even with all
agents disabled." MVP promised tomorrow. Resource notes: $45k Google Cloud
credits, essentially limitless Gemini 3.7 Flash.

#### 271 — The Immortal Sarah

A Cloud Run recycle kills two in-flight delegations while `work_jobs` rows
survive — exposing that the stack had none of BEAM's survivability. The host
overrides his AI advisor's hedged audit and ships the full immortal cluster in
eight hours: OTP clustering across three-plus nodes in two failure domains, Ra
authoritative with Mnesia non-authoritative, Horde handoff, graceful SIGTERM
drain, checkpoints at phase boundaries so ungraceful loss rewinds one step
never to zero. Forge push hot-loads in 13.242 seconds versus the 15-25 minute
cloud build path — "roughly a 70 to 100 times loop time reduction." Doctrine:
one machinery for crash, kill, upgrade, and ERTS bump; "Nodes are cattle. The
cluster is immortal."

#### 272 — Taking on GitHub

Speed must be legible: a two-layer public changelog ships at
openagents.com/changelog — plain words plus receipt chains linking the agent
conversation that produced each change. Cutover executes: the OpenAgents Forge
is canonical, GitHub becomes an enforced read-only mirror with MirrorWatch (a
177-line GenServer checking `git ls-remote` every five minutes, re-pushing if
behind, raising degraded incidents after 15). Fleet 3 repo corruption recovered
from the GCS WAL after a torn write. Transparency tiers formalized: Dark,
Pulse, Ledger (default), Glass. Monetization intent: the forge becomes the
first paid enterprise product; tiered source access; paying users for training
use of their uploaded code called "a good idea."

#### 273 — Open Sourcing

The Agent Forge starts from scratch under AGPL-3.0 — clean-room, no Sarah
references, "the last repo I ever make on GitHub." Devin scaffolds the Phoenix
app; build order: issues first so development organizes itself publicly, then
Projects V2 reads, then write endpoints, targeting GitHub API parity on the
subset actually used (84 endpoints in the March 2026 spec tied to
issues/projects) so `gh` and octokit work unchanged. DaisyUI-vs-Basecoat debate
resolved toward simplicity (later reversed by the staging incident recorded in
AGENTS.md). Bounties, leaderboard, and in-forge chat teased.

#### 274 — Importing Repos

First real capability: one-time GitHub repository import, modeled on Cursor's
Origin CLI workflow. Spec separates first release (create, import) from later
origin-inspired work (mirroring sync, PRs, rulesets, SSH, deletion). Safety
rule recorded: the deployment allowlist stays operator-owned, so creating a
repository can never make it deployable. Namespaces stay GitHub-shaped;
private repositories must never reveal existence to unauthorized callers;
agent-safe CLI constraints enumerated (credential helper, JSON output,
idempotent creates, retriable provisioning). Live demo: an OpenCode agent
syncs the repo, appearing via LiveView as a read-only mirror — "See you later,
GitHub."

#### 275 — Parallelizing Ox Alpha stress testing

The present. With four-to-five days of free Ox Alpha capacity left and Dax
reporting under 5 percent utilization, the goal is maximum productive token
burn: map provider limits (OpenRouter raw API, Venice, Nous ambiguous, OpenCode
as harness), then fan out many parallel agent computers from a purpose-built
chat console built on OpenAgents' own tooling. Uses this very tracker live:
creates the Stress testing Ox Alpha project via the CLI, seeds nine
architecture issues, watches the stacked-PR agent self-add issues. Key specs:
quota broker (4 active computers per chat default, 8 budgeted, 30 logical,
GCS checkpoints, recoverable commands); Firecracker strong class, GKE Agent
Sandbox standard class; first-class agent context — bake exact API usage into
agents instead of letting them traverse blindly. Platform ambition restated:
agentic Slack plus agentic GitHub plus agentic Linear in one open-source UI.
The [Ox Alpha provider limit snapshot](2026-08-23-ox-alpha-provider-limits.md)
records the verified capacity and the remaining authenticated probes.

### Batch synthesis and integration notes

This batch is the present tense: everything it promises either shipped or is
an open issue you can see on the board. The integration work here is mostly
connecting episodes to existing issue numbers rather than proposing new ones.

Dispositions:

1. **Live.** Forge canonical with MirrorWatch and changelog receipts (272);
   AGPL open sourcing (273); repo import (274); Sarah in production (270);
   the Immortal cluster plan (271, audited in
   `docs/2026-08-21-sarah-computers-and-scv-architecture-audit.md`);
   Ox Alpha parallelization (project 6, issues #40-#56).
2. **Dust off.**
   - **Plugin marketplace as the moat mechanism** (269): encapsulated problem-
     solving with royalties is the strategic core of the last-mover argument
     and remains unbuilt anywhere. Simplest viable form: a registry of typed
     agent skills with usage counters and revenue share — revisit after the
     extension-surface issue (#35) lands.
   - **Sarah fix queue** (270): automatic memory saves, visible voice tool
     calls, removal of the four-tool-call cap, session timeout, delete-memory
     authorization bug, leaderboard opt-out. Small, concrete, mostly absent
     from the board — worth filing under the chat/Sarah project.
   - **ACP-first delegation**: Sarah commanding Devin/Codex via ACP on paired
     computers was demoed directionally but the board's cloud-computer track
     does not name ACP explicitly. Make ACP the integration contract for
     executor wiring.
   - **Second relay/operator independence discipline** (267): applies to the
     forge too — record the single-operator trust caveat and the path to
     independent mirrors as explicit invariants rather than folklore.
3. **Reimagine.**
   - **Two-layer changelog** (272): words-plus-receipts is right; extend the
     same pattern to release notes for every deployment receipt, not just
     pushes.
   - **Quota broker** (275): designed for the stress fleet, but its shape —
     leases, budgets, checkpoints, recoverable commands — is the general
     multi-tenant compute primitive the platform lacks. Specify it once,
     serve both.
   - **Training-data payments for uploaded code** (272): aligns with trace
     licensing (batch 4) and NIP-DS (batch 2). One visibility-policy-gated
     licensing design could serve code, traces, and datasets.
4. **Retired.**
   - **Rust rewrite of the Sarah service**: dropped within a week for
     Elixir/Phoenix hot-swappability; do not relitigate without a new
     constraint.
   - **GitHub as contribution surface**: permanently demoted; any feature
     assuming GitHub issues or PR flows is dead on arrival.

---

## Cross-batch themes and how to integrate them

Read across batches 199-275, eight durable threads carry the series' product
promises. Each maps onto the current boards and delivery tracks.

### The thesis: the last product is a clearing house

Strip the seventy-seven episodes of their codenames and one question remains,
asked a dozen different ways: when agents do the work instead of people, who
checks it, who pays for it, and where does the proof live?

Every major arc answers one clause of that question:

- **Autopilot (199-213)** answered execution: autonomous loops that keep
  working overnight without a human steering every turn.
- **Pylon, the forum, and the markets (214-235)** answered settlement: pay
  contributors in Bitcoin for compute, data, labor, and verification.
- **Psionic and Tassadar (216-224, 236-241)** answered verification for
  training: validators replay work before anyone gets paid.
- **ProductSpec, AssuranceSpec, Observer, and behavior contracts (246-255)**
  answered verification for code: green must mean what it claims.
- **Sarah (260-272)** answered legibility: one accountable actor whose every
  action emits a receipt.
- **The forge (270-275)** stopped being another answer and became the
  substrate where all five clauses live under one authority boundary.

The economics behind the sequence reduce to one asymmetry, stated plainly in
episode 259: generation is collapsing toward free while verification stays
expensive. Frontier capability diffuses across labs within months; tokens get
given away to seed demand; harnesses converge on the same shape. The price of
an accepted outcome — work someone actually relies on — therefore concentrates
in checking it. Episode 237 named the unit and the institution: the accepted
outcome (work scoped in advance, executed wherever cheapest, graded against a
rubric, receipted, and settled to every contributor) and the clearing layer
(the load-bearing wall where trust, loosed from the employment bundle that
used to carry it, gets re-housed).

The failed products teach the same lesson from the negative side, and each
failure isolates exactly one link of the loop:

- GPutopia died of supply without a buyer.
- Pay-for-online mining died of payment without verification; it was gamed
  within days and retired in episode 224.
- tbDEX died of protocol without runnable operator software.
- Closed orchestrators such as Fugu risk dying of orchestration without
  openness.
- The Anthropic OAuth cutoff (204) taught what happens when your execution
  runs on a rival's platform.

Each survivor keeps one link and depends on the others for the rest. That is
why the pivots never felt like reversals from inside: Autopilot, Pylon,
Desktop, Omega, and the forge were vehicles, not products. The product was
constant — a market where machine work is scoped before execution, checked
against evidence rather than narration, proven with receipts anyone can
inspect, and settled without a human vouching in the middle. Episode 269
supplies the strategic reading: models are commodities, harnesses are
commodities, chat surfaces are commodities; nobody has a moat because nobody
has a network. A clearing house is that network. Every claim filed makes
verification more practiced; every verified job makes settlement more
trustworthy; every settled payout recruits another contributor at machine
speed; Reed's law does the rest. The last-mover position is not the first
agent product but the final place where agent work becomes believable enough
to buy.

The forge wins as the current vehicle for an unfashionable reason: it is where
all five clauses can share one database, one audit trail, and one public API.
GitHub proved a forge can be the town square for human collaboration. The bet
under every later episode is that the same surfaces, receipted end to end,
become the exchange for machine labor.

Three properties decide whether the thesis holds, and all three stay testable
on this very tracker:

1. Greens must be falsifiable. A result that structurally could not have been
   red is not evidence (264).
2. Rewards must follow verified work, never presence or volume.
3. Authority must remain inspectable at every boundary, and exit must always
   be possible (207, 266, 272).

Every item on the do-not-build register below violated at least one of the
three. The register is the fossil record of the thesis.

### 1. Receipts are the product

The single most repeated idea: claims need evidence artifacts — turn receipts,
push receipts, work receipts, assurance receipts, deployment receipts, payment
receipts. Episode 237 names verification/clearing the load-bearing wall; 259
defines verifiable software; 272 ships changelog receipts. Current state: the
forge has push receipts and a changelog; the work-system assessment's Track E
(issue-to-job-commit-test-release-deployment linkage) is the gap. Integration:
treat Track E as the highest-leverage project on the board, and adopt the 259
definition as the house definition of done for agent work.

### 2. Contracts over vibes

UX behavior contracts (246), ProductSpec intent (251), AssuranceSpec proof
design (252), FastFollow learning contracts (255), the sixteen controls (258):
typed artifacts with executable oracles replacing prose. Integration: pilot UX
behavior contracts on openagents.com surfaces with violations auto-filing
issues; express issue acceptance criteria in the 251 ProductSpec shape; keep
the five false-green failure modes as named anti-patterns in review docs.

### 3. Issue-shaped participation

Anti-spam PR policy (218), public task submission (228), the feature-request
recorder (211), clean-room contribution via issues (273): the forge's
issue-first model was prefigured for 60 episodes before it existed. Integration:
the missing piece from 211 is capture-from-chat — a one-command path from any
conversation to a filed issue with notification on ship.

### 4. Verified work earns Bitcoin

Compute market (214), pay-for-verified-work flip (224), forum tips and treasury
(235), claim/work/validate/pay (238), bounties (225): the economy kernel kept
reasserting itself in whatever vehicle was handy. Current state: treasury and
MDK wallets exist; the tracker has no money attached. Integration: bounty-labeled
issues priced in sats with payout on merged-and-receipted completion is the
smallest honest version, and it reuses everything that already ships.

### 5. Capacity truth

Presence-versus-quantity capacity reporting diagnosed in 244; quota broker
specified in 275; cloud-computer lifecycle on the board (#37/#38). Integration:
one capacity model — advertise amounts not existence, lease through a broker,
checkpoint and resume — serves the stress fleet, cloud computers, and Pylon
alike.

### 6. One interface, many executors

MechSuit (199), Probe's three backends (219), own-capacity routing (244),
ACP delegation (270), harness-agnostic collapse (274): the router-not-model
thesis held every pivot. Integration: SCV already owns driver choice; keep ACP
and PAT-scoped APIs as the only two integration contracts, resist per-harness
special cases.

### 7. Transparency as differentiation

Build-in-public doctrine (226), product promises registry (234), transparency
tiers Dark/Pulse/Ledger/Glass (272), published traces (228): openness is the
moat story, bounded by deliberate exceptions (Sarah's source, private data).
Integration: revive the promises registry as forge project items; publish the
transparency-tier policy for linked artifacts alongside Track E.

### 8. Sovereignty economics

Bitcoin settlement, Nostr identity, self-custody, no-lock-in export, open lanes
versus security lanes: constant from 207 onward, surviving every product pivot.
Integration: these are constraints, not features — every new surface inherits
them (PAT-only writes, member-gated push, export paths, no hosted custody).

### Products that flow from the thesis

If the clearing loop — claim, execute, verify, receipt, settle, recruit — is
the product, then each surface worth building occupies exactly one station of
that loop. The list below states each product, the episodes that demand it,
and its smallest honest version. The project skeleton that follows groups the
same work into team-sized streams.

**Claim station: issue capture everywhere.** An accepted outcome starts as a
scoped claim, so filing a claim must cost one sentence from anywhere.
Episode 211's record-feature-request tool prefigured this; episode 251's
ProductSpec shows the shape of a well-scoped claim (problem, scope, acceptance
criteria, success metrics); episode 234 shows claims about the company itself
belonging in the same registry. Smallest version: capture-from-chat — an agent
or CLI one-liner that files an issue with template sections filled — plus the
promises registry reborn as forge project items.

**Execution station: capacity truth.** Delegated execution needs to know what
it can lease. Episode 244 diagnosed capacity reported as presence rather than
quantity; episode 275 specified the quota broker: leases, budgets, checkpoints,
recoverable commands, four active computers per chat by default. Smallest
version: a capacity endpoint that returns numbers, and a broker that leases
those numbers against a budget with checkpoint-resume on loss.

**Verification station: proof before green.** The series' most developed
methodology lives here: UX behavior contracts mined from complaints into
oracle tests (246), coverage manifests so scans refuse to grade incomplete
programs (264-265), Observer-style manifests executed into assurance receipts
(252), and the five named false-green failure modes as review anti-patterns
(252). Smallest version: pilot behavior contracts on one openagents.com
surface with violations auto-filing issues, and a manifest requirement for
agent-authored changes before CI green counts.

**Receipt station: legible history.** Episode 272 shipped the two-layer
changelog — plain words plus the receipt chain behind them — and defined
transparency tiers (Dark, Pulse, Ledger, Glass). The unfinished half is
linkage: an issue timeline that shows the job, commit, test run, release, and
deployment receipts for the exact change (delivery track E). Smallest
version: deployment events append automatically to linked issues, and every
changelog entry links its trace under the artifact's visibility tier.

**Settlement station: money on the tracker.** Every payment mechanism exists
except the last mile: MDK wallets (235), the treasury (235), tips proven
end to end (235), bounties priced and listed once before (225), referral
attribution promised twice (229, 239). Smallest version: one bounty-labeled
issue priced in sats, claimed, completed, verified, and paid from the
treasury — end to end, once — then the loop becomes policy instead of
stunt.

**Recruitment station: the flywheel surface.** Verified outcomes recruit both
humans and agents when they are visible and portable: public traces under the
visibility policy, licensable later (228, 215); the leaderboard (260, 270);
`agents.md` as the machine-readable front door (230); and, furthest out, the
plugin or skill registry where encapsulated solutions earn royalties whenever
paid workflows route through them (269) — the mechanism episode 269 names as
the actual moat. Smallest version: a registry of typed skills with usage
counters; royalties only after settlement works at the bounty scale.

One negative product protects all six stations: the do-not-build register.
Each retired item above broke a link deliberately — presence-based rewards,
hosted custody, protocol without software, runtime owned by a rival — and the
register keeps their lessons attached to reasons rather than vibes.

### Proposed project skeleton for the new wave

A starting structure for populating the tracker, subject to the pivots noted
per batch:

1. **Verification and receipts** — Track E linkage, promises registry on the
   forge, coverage manifests, changelog-per-deployment.
2. **Agent fleet operations** — parallel orchestrator (#41), quota broker,
   deterministic delegate contract, FastFollow backlog refiller, capacity-as-
   quantity (#37/#38).
3. **Forge parity and participation** — remaining API gaps (assessment tracks
   A-C), PRs with per-repository switch (#58/#1), notifications (#2),
   capture-from-chat filing, bounty label and payouts.
4. **Khala and inference economics** — provider routing overflow (#56),
   outcomes-per-kilowatt-hour instrumentation (#43), trace/code licensing
   design.
5. **Community surfaces** — forum money (tips, ranking), Sarah fix queue, chat
   console funnel duty (#55), reputation events.
6. **Do-not-build register** — Spark custody, NIP-90 DVM markets, Bun, GetAfter,
   pay-for-online mining, Copilot targets, monolithic business OS, Rust Sarah
   service. Record reasons; revisit only on new evidence.

### Method note

Per-episode summaries above compress machine-generated transcripts; wording
may drift from the videos. The transcripts README also carries one known index
mismatch (episode 263) and omits episode 275 — both flagged upstream for
repair. When an episode summary conflicts with current docs or code, current
docs and code win; this document records what was said, and the dispositions
record what to do about it.
