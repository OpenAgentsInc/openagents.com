# The registry is the network

Date: 2026-08-24

Status: strategy synthesis

This document records the strategic synthesis behind the current push: a
centralized cloud whose network effect comes from consensually collected
usage data feeding a central plugin registry that grows and evolves on that
data — with the coder as the wedge, the forge as the substrate, and WASM
plugins as the unit of accumulated capability. It extends
`docs/2026-08-24-triage-and-plugin-model-assessment.md` (the mechanism) with
the strategy that motivates it, and it resequences one conclusion of
`docs/episode-triage.md` (section 12). Sources: the full episode triage,
the 2024 plugin-economy arc (episodes 048–102, 165), the last-mover thesis
(episode 269), the Pylon history and its surviving code, the Omega-era
plugin tool specification
(`openagents/docs/omega-agent/2026-07-27-plugin-tool-spec.md`), and the
economics analysis in
`openagents/docs/fable/2026-07-19-some-simple-economics-of-agi-deepdive.md`.

## 1. Summary

- Every failed OpenAgents market broke one leg of the same three-legged
  stool: a named buyer, verifiable usage, and settlement. The centralized
  cloud supplies the two legs the 2024 Agent Store lacked — verifiable usage
  and a real buyer — and the coder is that buyer.
- The moat variable is verified network scale: usage counters that are
  receipts, not claims. Only a center of ground truth produces that.
- The Codifier's Curse gives the recruiting pitch: expertise is being
  codified into someone's training data regardless; the registry is the
  attribution ledger that makes codification pay its author instead.
- The registry needs no new service. A plugin is a forge repository with a
  typed manifest and a digest-pinned release. The forge already provides
  identity, versions, receipts, issues, and — later — bounty rails.
- One plugin contract serves three hosts (TypeScript CLI, BEAM server, Rust
  substrate), on an owned, reduced-surface WASM host rather than a
  dependency on any third-party plugin framework.
- One npm install carries the whole loop: spend (coder), contribute
  (plugins), and eventually earn (wallet plus provider mode, rebuilt from
  the surviving Pylon code under the pay-for-verified-work laws).
- Payments stay deferred, with one deliberate exception: a single
  end-to-end bounty settlement proof, run once before any royalty plumbing.

## 2. What the failed markets settled

Read across episodes 199–275, each dead market isolates one missing leg:

| Attempt | What it had | What killed it |
| --- | --- | --- |
| GPutopia (2023) | Sellers | No buyer |
| Pay-for-online mining | Payment | No verification; gamed within days, retired in episode 224 |
| 2024 Agent Store (episodes 048–102) | Supply, payouts, 20 paid developers | No demand: "we didn't really have the use case for which people were willing to actually pay" (episode 165) |
| tbDEX | Protocol | No runnable operator software |

The standing laws distilled from these (all already on the record in
`docs/episode-triage.md`): name the buyer first; rewards follow verified
work, never presence or volume; authority stays inspectable and exit stays
possible.

A registry that "grows and evolves on shared data" is a market, and it needs
all three legs. That is the argument for the center.

## 3. Verified thickness: why the cloud is the moat

The economics analysis identifies the durable platform variable as
**verified network scale** — the share of activity credibly authenticated as
real, times raw scale. "Apparent thickness can often be generated with
compute, but verified thickness cannot."

A decentralized registry of signed listings — the shape proposed in episode
066 — produces raw scale: anyone can list. It produces nothing on the
verified share, because no one can observe usage. A centralized cloud where
every plugin run lands as a `tool.ran` event on a durable thread transcript,
carrying the plugin's digest, makes every usage counter a receipt. The
registry's data advantage is not "the most plugins." It is "usage numbers
that are true," in an ecosystem where everyone else's are unverifiable.

This is also why the coder's thread persistence work is not just UX: the
thread transcript is the unit of consensual data collection. Nothing
accrues until the CLI writes its transcript to the server
(`docs/2026-08-24-coder-account-integration-audit.md` already decided the
server copy is the only copy).

## 4. The Codifier's Curse and the attribution ledger

The same economics paper names the dynamic that supplies the registry's
recruiting pitch. Every act of expert work with an AI system codifies that
expert's tacit knowledge into someone's training data, and withholding is
irrational — codification is a global prisoner's dilemma that proceeds with
or without the expert's consent.

Episode 269 found the answer before the paper named the problem: "solve a
painful problem once ($30 of compute and an hour), package it as a plugin
all future agents reuse, get paid when paid workflows route through it."

Stated as a pitch: your expertise is being codified either way — into a
frontier lab's weights as anonymous gradient dust, or into a digest-pinned
plugin with your name on it and a royalty hook. The registry is the
**attribution ledger** that turns the curse into the dividend economy
episodes 200 and 223 promised (skill royalties, data royalties, compute
dividends). Attribution accrues now, from the first recorded run;
settlement over that record resumes later without a schema change.

## 5. Consent is applied policy, not a new build

"Consensually collected" does not require new machinery. The pieces exist:

- **Transparency tiers** (episode 272): Dark, Pulse, Ledger, Glass —
  designed as a per-artifact visibility dial.
- **Opt-in trace licensing**: the triage's own simplification of episode
  245's trace economy ("simplify to opt-in trace licensing tied to
  visibility policy before any royalty plumbing exists").
- **Operator-blind export**: `GET /data/export/account?recipient=age1…`
  ships (#178), proving the exit half of the consent story.

The work is applying the existing tier model to two new artifact classes —
thread transcripts and plugin usage — and building the opt-in gate before
the collection volume, not after. Consent-first is what makes the
centralized cloud defensible rather than extractive; it is the difference
between the registry and the curse.

## 6. How the registry evolves: three loops

"Grows and evolves based on shared data" means three concrete feedback
loops, in order of arrival:

1. **Selection loop.** Usage receipts plus outcome signals tune which
   plugin the capability selector surfaces for which request. Optimization
   is bounded and offline in the DSE/GEPA style, under the standing law:
   an optimizer output is a candidate, never a deployment.
2. **Gap loop** — the network-effect engine. A capability search that finds
   nothing is a demand signal. File it as a scoped forge issue
   automatically; price it as a bounty when settlement resumes; a
   contributor — human or agent — builds the plugin; the registry grows
   exactly where demand proved out. This is episode 211's
   record-feature-request tool generalized from features to capabilities,
   and it is only possible when search, issues, bounties, and the registry
   share one database.
3. **Promotion loop.** The long ladder: plugin → model-directed plugin use →
   distilled specialization. Aggregate invocation traces are the training
   data for eventually moving popular plugin-orchestration patterns into
   model behavior. Only a centralized trace corpus makes that trainable.

## 7. Why the forge is load-bearing

1. **The forge supplies the buyer the 2024 store never had.** The coder
   works against forge issues; repository → issues → code → plugin is one
   graph in one authority domain. Coding is the proven
   willingness-to-pay category — episode 165's own retrospective says it is
   why OpenAgents went to coding agents.
2. **Plugins are forge repositories.** A plugin is a repo with a manifest
   and a digest-pinned release artifact. The forge already gives identity,
   versioning, history, WAL-anchored receipts, issues, and later bounty
   rails, per repository, for free. The registry is a typed index over
   forge releases plus semantic search in the CLI — not a new backend.
3. **GitHub parity is the consensual data on-ramp.** One-command import
   brings the code and the issue graph to the center with the user's
   intent, not by scraping. `gh` and octokit compatibility means existing
   agents already know how to operate the surface.
4. **Receipts land where the work happens.** The triage's clearing-house
   thesis states it: the forge wins "because it is where all five clauses
   can share one database, one audit trail, and one public API."
5. **Exit legitimizes the center.** AGPL, mirrors, encrypted exports, the
   exit rehearsals. The episode 230 ideal — no single front door — survives
   as a later federation option on the relay/provider-daemon/skeptical-client
   market shape, once there is verified thickness worth federating. The
   center wins by being better, not by locking.

## 8. One plugin contract, three hosts

The plugin contract adopted in
`docs/2026-08-24-triage-and-plugin-model-assessment.md` is the same
contract the Omega plugin tool specification distilled from the 2024
economy, and it holds across every host:

- The model owns decision logic: which plugin, which export, what
  arguments, when to retry, when to stop.
- The runtime owns the execution contract: loading, digest verification,
  capability mediation, time and memory ceilings, cancellation, receipts,
  typed refusals.
- The plugin owns the black-box capability implementation, behind typed
  input and output schemas.
- Identity is content-addressed: plugin id, version, artifact digest,
  export, ABI version. No invocation is attributable without them.
- Discovery may be semantic; invocation is an exact name from the
  installed catalog. A plugin result is evidence, never write authority.

The payoff of one contract: **one artifact, three hosts.** The TypeScript
CLI (the coder), the BEAM server (server-side execution for chat), and the
Rust substrate all speak the same packet ABI against the same digest-pinned
artifact. The registry serves all three.

### Own the host

Extism — the runtime the 2024 economy ran on — is no longer a dependency to
build on; the direction is an owned, reduced-surface host, adapting Extism
source where useful (BSD-3-Clause permits it with attribution). The reduced
surface:

- One ABI: `handle_packet(bytes) -> bytes | typed refusal`, schema ids
  layered above, versioned (`packet.v1`).
- One guest path: an owned Rust PDK. Other guest languages only if demand
  appears.
- Host imports, total: log, allowlisted HTTP, KV get/put, read-only path
  mounts. Nothing else.
- Three thin hosts: Node (plain `WebAssembly` API plus owned shims),
  Elixir (a small wasmtime NIF), Rust (wasmtime directly), behind a
  host-owned engine abstraction so no engine is load-bearing forever.
- Enforcement: digest verification before load, timeout/memory/fuel
  ceilings, typed refusals, a receipt per invocation.

The contract is the owned thing; engines stay swappable.

## 9. One install, the whole loop

The target: `npm i -g @openagentsinc/cli` delivers spend, contribute, and
earn through one identity.

- **Spend**: the coder — clone, traverse, turn intent into issues, code,
  use plugins — against forge threads and receipts.
- **Contribute**: build and publish plugins as forge repositories; the gap
  loop hands contributors pre-validated demand.
- **Earn**: a wallet and, later, provider mode — the machine serves
  verified work while its owner is away, and gets paid.

The earn half is proven code, not a dream. The Pylon arc (episodes
201–224, 236–238, 244–245) shipped and validated, at 1,300+ nodes and over
1M sats paid:

- A presence/capacity service that already encodes the
  capacity-as-quantity lesson (advertise amounts, not existence).
- A complete claim → lease → submit-trace → validate → settle loop, with
  the right doctrine attached: a lease is not an earning claim; only a
  settlement receipt is.
- One-seed identity: BIP-39 → Nostr keypair plus deterministic wallet,
  confirm-before-spend.
- A multi-earning ledger (modeled/observed/pending/paid/settled), inert by
  default.
- A local serving runtime (Apple Foundation Models bridge,
  OpenAI-compatible client, digest-verified model installer).
- The distribution pattern itself: paste-into-your-agent enrollment.

Constraints any revival inherits from the do-not-build register: never
presence-based rewards; no hosted custody; no NIP-90/DVM revival — an open
market transport, when it comes, uses the relay/provider-daemon/
skeptical-client shape; buyer first. The first buyer for idle machines is
OpenAgents' own operation: delegation children from other users' coders,
validator-replay jobs (verification is ideal away-from-keyboard work), and
the registry's own service jobs — embedding manifests for semantic search,
replaying plugin receipts, running conformance and eval suites. The
registry creates the compute demand that pays the machines that verify the
registry.

One open decision to make explicitly rather than inherit: the wallet rail.
Episode 235 retired hosted custody for the self-custodial stack, while the
shipped Pylon v1.0 made the deterministic Spark wallet primary and a later
owner decision preserved it as a live rail. The keeper either way is the
one-seed derivation; the rail needs a named decision.

## 10. What is newly possible now that was not in 2024

1. **Demand exists.** The coder is buyer number one; coding agents are the
   proven willingness-to-pay category.
2. **Ground truth exists.** Threads, receipts, the forge WAL — usage is
   observable server-side, so the verified share is real.
3. **Consent machinery exists.** Tiers, licensing framing, operator-blind
   exports.
4. **Settlement exists, dormant.** Self-custodial wallets, the treasury,
   tips proven end to end (episode 235). The plumbing survives; only the
   policy is paused.
5. **Distribution collapsed to one command.** 2024 needed a web platform;
   2026 rides npm plus paste-into-your-agent.
6. **The window is open.** Episode 269's reading strengthens monthly:
   models, harnesses, and chat surfaces commoditize; nobody has a network.
   A verified capability registry is a network, and the last-mover position
   only works if the ledger is accruing while everyone else fights over
   harness features.

## 11. Priorities

In order:

1. **Thread persistence and resume** (in flight). The transcript is the
   data substrate; nothing accrues until the CLI writes it. Monorepo #19
   (the failed-closed release gate) blocks everything here and goes first.
2. **Plugin contract v1, owned host, pilot.** The packet-ABI contract, the
   reduced Extism-derived host, and foreign session resume (#198) as the
   first real plugin.
3. **Consent and usage receipts before scale.** Plugin runs as
   digest-carrying thread events; transparency tiers applied to threads
   and usage; sharing opt-in.
4. **Registry on the forge.** Plugins as repositories, digest-pinned
   releases, a typed index, semantic capability search in the CLI, and the
   gap loop: failed searches file issues.
5. **One settlement proof.** One bounty-labeled issue, priced in sats,
   claimed, verified, paid end to end — once. This deliberately reopens a
   sliver of the economy lane closed in the 2026-08-24 triage, as a proof,
   not a program.
6. **Wallet and identity in the CLI.** One seed → identity plus wallet;
   rail decision made explicitly; receiving before spending.
7. **Provider mode.** Port the Pylon presence and claim/validate/settle
   loop into the CLI; OpenAgents fleet as first buyer; verification jobs
   first, inference second; pay-for-verified-work only.
8. **Selection-policy evolution.** Tune capability search from usage data
   once volume exists — candidates, never auto-promotions.

Deferred on purpose: open federation of the registry, third-party royalty
programs at scale, and anything shaped like five markets on a weekly
cadence.

## 12. Resequencing note against the episode triage

`docs/episode-triage.md` contains every piece of this synthesis — the six
stations, the episode 269 dust-off, the do-not-build register — but files
the skill/plugin registry as the furthest-out station ("recruitment"),
gated behind everything else. This document moves it to the center: the
registry is the thing the coder, the forge, the consent machinery, and
eventual settlement all feed, and its non-monetary half (attribution,
usage receipts, the gap loop) starts accruing value now. The stations
stand; the sequencing changes. The triage's settlement doctrine — royalties
only after settlement works once at bounty scale — is preserved as
priority 5 above.
